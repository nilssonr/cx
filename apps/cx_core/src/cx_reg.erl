-module(cx_reg).

%% Minimal via-compatible local process registry for composite names like
%% {agent, TenantId, UserId} and {queue, TenantId, QueueId}.
%% Deliberately not gproc (dep), global (cluster locking semantics) or pg
%% (no uniqueness). Swap for syn when clustering arrives.

-behaviour(gen_server).

-export([start_link/0]).
-export([register_name/2, unregister_name/1, whereis_name/1, send/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, cx_reg_tab).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register_name(term(), pid()) -> yes | no.
register_name(Name, Pid) ->
    case gen_server:call(?MODULE, {register, Name, Pid}) of
        yes -> yes;
        no -> no
    end.

-spec unregister_name(term()) -> ok.
unregister_name(Name) ->
    ok = gen_server:call(?MODULE, {unregister, Name}).

-spec whereis_name(term()) -> pid() | undefined.
whereis_name(Name) ->
    case ets:lookup(?TAB, Name) of
        [{_, Pid, _}] ->
            case is_process_alive(Pid) of
                true -> Pid;
                false -> undefined
            end;
        [] ->
            undefined
    end.

-spec send(term(), term()) -> pid().
send(Name, Msg) ->
    case whereis_name(Name) of
        undefined ->
            exit({badarg, {Name, Msg}});
        Pid ->
            Pid ! Msg,
            Pid
    end.

%% gen_server. State is #{MonitorRef => Name}.

init([]) ->
    ?TAB = ets:new(?TAB, [named_table, set, protected, {read_concurrency, true}]),
    {ok, #{}}.

handle_call({register, Name, Pid}, _From, Refs) ->
    case ets:lookup(?TAB, Name) of
        [{_, OldPid, _}] when OldPid =/= Pid ->
            case is_process_alive(OldPid) of
                true -> {reply, no, Refs};
                false -> {reply, yes, do_register(Name, Pid, Refs)}
            end;
        [{_, Pid, _}] ->
            {reply, yes, Refs};
        [] ->
            {reply, yes, do_register(Name, Pid, Refs)}
    end;
handle_call({unregister, Name}, _From, Refs) ->
    case ets:lookup(?TAB, Name) of
        [{_, _Pid, Ref}] ->
            erlang:demonitor(Ref, [flush]),
            ets:delete(?TAB, Name),
            {reply, ok, maps:remove(Ref, Refs)};
        [] ->
            {reply, ok, Refs}
    end.

handle_cast(_Msg, Refs) ->
    {noreply, Refs}.

handle_info({'DOWN', Ref, process, _Pid, _Reason}, Refs) ->
    case maps:take(Ref, Refs) of
        {Name, Rest} ->
            ets:delete(?TAB, Name),
            {noreply, Rest};
        error ->
            {noreply, Refs}
    end;
handle_info(_Msg, Refs) ->
    {noreply, Refs}.

do_register(Name, Pid, Refs) ->
    Ref = erlang:monitor(process, Pid),
    ets:insert(?TAB, {Name, Pid, Ref}),
    Refs#{Ref => Name}.
