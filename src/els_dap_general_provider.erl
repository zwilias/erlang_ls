-module(els_dap_general_provider).

-behaviour(els_provider).
-export([ handle_request/2
        , handle_info/2
        , is_enabled/0
        , init/0
        ]).

-export([ capabilities/0
        ]).

-include("erlang_ls.hrl").

%%==============================================================================
%% Types
%%==============================================================================

-type capabilities() :: #{}.
-type initialize_request() :: {initialize, initialize_params()}.
-type initialize_params() :: #{ processId             := number() | null
                              , rootPath              => binary() | null
                              , rootUri               := uri() | null
                              , initializationOptions => any()
                              , capabilities          := client_capabilities()
                              , trace                 => off
                                                       | messages
                                                       | verbose
                              , workspaceFolders      => [workspace_folder()]
                                                       | null
                              }.
-type initialize_result() :: capabilities().
-type initialized_request() :: {initialized, initialized_params()}.
-type initialized_params() :: #{}.
-type initialized_result() :: null.
-type shutdown_request() :: {shutdown, shutdown_params()}.
-type shutdown_params() :: #{}.
-type shutdown_result() :: null.
-type exit_request() :: {exit, exit_params()}.
-type exit_params() :: #{status => atom()}.
-type exit_result() :: null.


%% Based on Elixir LS' PausedProcess
-type frame_id() :: pos_integer().
-type frame() :: #{}.
-type thread() :: #{ pid := pid()
                   , frames := #{frame_id() => frame()}
                   }.
-type thread_id() :: integer().
-type state() :: #{threads => #{thread_id() => thread()}}.

%%==============================================================================
%% els_provider functions
%%==============================================================================

-spec is_enabled() -> boolean().
is_enabled() -> true.

-spec init() -> #{}.
init() ->
  #{threads => #{}}.

-spec handle_request( initialize_request()
                    | initialized_request()
                    | shutdown_request()
                    | exit_request()
                    , state()) ->
        { initialize_result()
        | initialized_result()
        | shutdown_result()
        | exit_result()
        , state()
        }.
handle_request({<<"initialize">>, _Params}, State) ->
  {capabilities(), State};
handle_request({<<"launch">>, Params}, State) ->
  #{<<"cwd">> := Cwd} = Params,
  ok = file:set_cwd(Cwd),
  %% TODO: Do not hard-code sname
  spawn(fun() -> els_utils:cmd("rebar3", ["shell", "--sname", "daptoy"]) end),
  %% TODO: Wait until rebar3 node is started
  timer:sleep(3000),
  els_distribution_server:start_distribution(local_node()),
  net_kernel:connect_node(project_node()),
  %% TODO: Spawn could be un-necessary
  spawn(fun() -> els_dap_server:send_event(<<"initialized">>, #{}) end),
  {#{}, State};
handle_request({<<"configurationDone">>, _Params}, State) ->
  inject_dap_agent(project_node()),
  %% TODO: Fetch stack_trace mode from Launch Config
  rpc:call(project_node(), int, stack_trace, [all]),
  Args = [[break], {els_dap_agent, int_cb, [self()]}],
  rpc:call(project_node(), int, auto_attach, Args),
  %% TODO: Potentially fetch this from the Launch config
  rpc:cast(project_node(), daptoy_fact, fact, [5]),
  {#{}, State};
handle_request({<<"setBreakpoints">>, Params}, State) ->
  #{<<"source">> := #{<<"path">> := Path}} = Params,
  SourceBreakpoints = maps:get(<<"breakpoints">>, Params, []),
  _SourceModified = maps:get(<<"sourceModified">>, Params, false),
  Module = els_uri:module(els_uri:uri(Path)),
  %% TODO: Keep a list of interpreted modules, not to re-interpret them
  rpc:call(project_node(), int, i, [Module]),
  [rpc:call(project_node(), int, break, [Module, Line]) ||
    #{<<"line">> := Line} <- SourceBreakpoints],
  Breakpoints = [#{<<"verified">> => true, <<"line">> => Line} ||
                  #{<<"line">> := Line} <- SourceBreakpoints],
  {#{<<"breakpoints">> => Breakpoints}, State};
handle_request({<<"setExceptionBreakpoints">>, _Params}, State) ->
  {#{}, State};
handle_request({<<"threads">>, _Params}, #{threads := Threads0} = State) ->
  Threads =
    [ #{ <<"id">> => Id
       , <<"name">> => els_utils:to_binary(io_lib:format("~p", [maps:get(pid, Thread)]))
       } || {Id, Thread} <- maps:to_list(Threads0)
    ],
  {#{<<"threads">> => Threads}, State};
handle_request({<<"stackTrace">>, Params}, #{threads := Threads} = State) ->
  #{<<"threadId">> := ThreadId} = Params,
  Thread = maps:get(ThreadId, Threads),
  Frames = maps:get(frames, Thread),
  StackFrames =
    [ #{ <<"id">> => Id
       , <<"name">> => els_utils:to_binary(io_lib:format("~p:~p/~p", [M, F, length(A)]))
       , <<"source">> => #{<<"path">> => Source}
       , <<"line">> => Line
       , <<"column">> => 0
       }
      || { Id
         , #{ module := M
            , function := F
            , arguments := A
            , line := Line
            , source := Source
            }
         } <- maps:to_list(Frames)
    ],
  {#{<<"stackFrames">> => StackFrames}, State};
handle_request({<<"scopes">>, Params}, State) ->
  #{<<"frameId">> := _FrameId} = Params,
  {#{<<"scopes">> => []}, State};
handle_request({<<"next">>, Params}, #{threads := Threads} = State) ->
  #{<<"threadId">> := ThreadId} = Params,
  Pid = to_pid(ThreadId, Threads),
  ok = rpc:call(project_node(), int, next, [Pid]),
  {#{}, State};
handle_request({<<"continue">>, Params}, #{threads := Threads} = State) ->
  #{<<"threadId">> := ThreadId} = Params,
  Pid = to_pid(ThreadId, Threads),
  ok = rpc:call(project_node(), int, continue, [Pid]),
  {#{}, State};
handle_request({<<"stepIn">>, Params}, #{threads := Threads} = State) ->
  #{<<"threadId">> := ThreadId} = Params,
  Pid = to_pid(ThreadId, Threads),
  ok = rpc:call(project_node(), int, step, [Pid]),
  {#{}, State};
handle_request({<<"evaluate">>, #{ <<"context">> := <<"hover">>
                                 , <<"frameId">> := FrameId
                                 , <<"expression">> := Expr
                                 } = _Params}, #{threads := Threads} = State) ->
  Frame = frame_by_id(FrameId, maps:values(Threads)),
  Bindings = maps:get(bindings, Frame),
  {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(Expr) ++ "."),
  {ok, Exprs} = erl_parse:parse_exprs(Tokens),
  %% TODO: Evaluate the expressions on the project node
  {value, Value, _NewBindings} = erl_eval:exprs(Exprs, Bindings),
  Result = unicode:characters_to_binary(io_lib:format("~p", [Value])),
  {#{<<"result">> => Result}, State};
handle_request({<<"variables">>, _Params}, State) ->
  %% TODO: Return variables
  {#{<<"variables">> => []}, State}.

-spec handle_info(any(), state()) -> state().
handle_info({int_cb, ThreadPid}, #{threads := Threads} = State) ->
  lager:debug("Int CB called. thread=~p", [ThreadPid]),
  ThreadId = id(ThreadPid),
  Thread = #{ pid    => ThreadPid
            , frames => stack_frames(ThreadPid)
            },
  els_dap_server:send_event(<<"stopped">>, #{ <<"reason">> => <<"breakpoint">>
                                            , <<"threadId">> => ThreadId
                                            }),
  State#{threads => maps:put(ThreadId, Thread, Threads)}.

%%==============================================================================
%% API
%%==============================================================================

-spec capabilities() -> capabilities().
capabilities() ->
  #{}.

%%==============================================================================
%% Internal Functions
%%==============================================================================
-spec inject_dap_agent(atom()) -> ok.
inject_dap_agent(Node) ->
  Module = els_dap_agent,
  {Module, Bin, File} = code:get_object_code(Module),
  {_Replies, _} = rpc:call(Node, code, load_binary, [Module, File, Bin]),
  ok.

-spec project_node() -> atom().
project_node() ->
  %% TODO: Do not hard-code node name
  {ok, Hostname} = inet:gethostname(),
  list_to_atom("daptoy@" ++ Hostname).

-spec local_node() -> atom().
local_node() ->
  %% TODO: Do not hard-code node name
  {ok, Hostname} = inet:gethostname(),
  list_to_atom("dap@" ++ Hostname).

-spec id(pid()) -> integer().
id(Pid) ->
  erlang:phash2(Pid).

-spec stack_frames(pid()) -> #{frame_id() => frame()}.
stack_frames(Pid) ->
  %% TODO: Abstract RPC into a function
  {ok, Meta} =
    rpc:call(project_node(), dbg_iserver, safe_call, [{get_meta, Pid}]),
  %% TODO: Also examine rest of list
  [{_Level, {M, F, A}}|_] =
    rpc:call(project_node(), int, meta, [Meta, backtrace, all]),
  Bindings = rpc:call(project_node(), int, meta, [Meta, bindings, nostack]),
  StackFrameId = erlang:unique_integer([positive]),
  StackFrame = #{ module    => M
                , function  => F
                , arguments => A
                , source    => source(M)
                , line      => break_line(Pid)
                , bindings  => Bindings
                },
  #{StackFrameId => StackFrame}.

-spec break_line(pid()) -> integer().
break_line(Pid) ->
  Snapshots = rpc:call(project_node(), int, snapshot, []),
  {Pid, _Function, break, {_Module, Line}} = lists:keyfind(Pid, 1, Snapshots),
  Line.

-spec source(atom()) -> binary().
source(M) ->
  CompileOpts = rpc:call(project_node(), M, module_info, [compile]),
  Source = proplists:get_value(source, CompileOpts),
  unicode:characters_to_binary(Source).

-spec to_pid(pos_integer(), #{thread_id() => thread()}) -> pid().
to_pid(ThreadId, Threads) ->
  Thread = maps:get(ThreadId, Threads),
  maps:get(pid, Thread).

-spec frame_by_id(frame_id(), [thread()]) -> frame().
frame_by_id(FrameId, Threads) ->
  [Frame] = [ maps:get(FrameId, Frames)
              ||  #{frames := Frames} <- Threads, maps:is_key(FrameId, Frames)
            ],
  Frame.
