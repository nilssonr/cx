-module(cx_presence).

%% Domain facade for collaboration presence. Two surfaces:
%%   - #auth_context{} functions for transports (set_own/get_own/directory)
%%   - transport-internal connectivity signals (connected/disconnected/
%%     activity), called by socket processes AFTER they authenticated;
%%     callers must throttle activity reports (>= 30s client-side).
%%
%% Single-publisher rule for presence_changed: the session publishes
%% while it exists (user has connections); the facade publishes only for
%% connectionless users on set_own. Never both.

-include_lib("cx_core/include/cx_core.hrl").

-export([set_own/2, get_own/1, directory/1]).
-export([connected/3, disconnected/2, activity/1]).
-export([away_threshold_ms/0]).

-define(CALL_TIMEOUT, 5000).
-define(CONNECT_RETRIES, 3).
-define(AWAY_THRESHOLD_DEFAULT_MS, 300000).

%% ---- domain surface ----

set_own(Context = #auth_context{tenant_id = TenantId, user_id = UserId}, Params) ->
    maybe
        ok ?= cx_authz:require(Context, <<"presence:set:self">>),
        ok ?= cx_authz:require_user(Context),
        {ok, Manual} ?= parse_state(Params),
        {ok, Message} ?= cx_params:optional_binary(Params, <<"message">>, undefined),
        {ok, Until} ?= parse_until(Params, Manual, Message),
        Now = cx_time:now_ms(),
        OldRow = read_declaration(TenantId, UserId),
        ok = cx_store:tx(fun() ->
            case {Manual, Message, Until} of
                {undefined, undefined, undefined} ->
                    mnesia:delete({cx_presence_declaration, {TenantId, UserId}});
                _ ->
                    mnesia:write(#cx_presence_declaration{
                        key = {TenantId, UserId},
                        manual_state = Manual,
                        message = Message,
                        until = Until,
                        updated_at = Now
                    })
            end
        end),
        ok = propagate(TenantId, UserId, OldRow, Now),
        get_own(Context)
    end.

get_own(Context = #auth_context{tenant_id = TenantId, user_id = UserId}) ->
    maybe
        ok ?= cx_authz:require_user(Context),
        {ok, own_map(TenantId, UserId)}
    end.

%% Any authenticated tenant member may read the directory (agents need
%% their coworkers) — the not-ready-reason-read precedent.
directory(#auth_context{tenant_id = TenantId}) ->
    Now = cx_time:now_ms(),
    EffectiveRows = live_effective(TenantId),
    DeclarationRows = lists:foldl(
        fun(R = #cx_presence_declaration{key = {_, UserId}}, Acc) ->
            Acc#{UserId => R}
        end,
        #{},
        cx_store:dirty_list(cx_presence_declaration, cx_patterns:presence_declarations(TenantId))
    ),
    {ok, [
        directory_entry(User, EffectiveRows, DeclarationRows, Now)
     || User = #cx_user{status = active} <- cx_store:dirty_list(
            cx_user, cx_patterns:users(TenantId)
        )
    ]}.

%% ---- transport-internal connectivity signals ----

-spec connected(#auth_context{}, pid(), map()) -> {ok, pid()} | {error, term()}.
connected(
    Context = #auth_context{tenant_id = TenantId, user_id = UserId}, ConnectionPid, DeviceInfo
) ->
    maybe
        ok ?= cx_authz:require_user(Context),
        {ok, #cx_user{status = active}} ?= fetch_active(TenantId, UserId),
        register_connection(TenantId, UserId, ConnectionPid, DeviceInfo, ?CONNECT_RETRIES)
    else
        {error, Reason} -> {error, Reason}
    end.

-spec disconnected(#auth_context{}, pid()) -> ok.
disconnected(#auth_context{tenant_id = TenantId, user_id = UserId}, ConnectionPid) ->
    case session_pid(TenantId, UserId) of
        undefined -> ok;
        Pid -> gen_statem:cast(Pid, {disconnected, ConnectionPid})
    end.

-spec activity(#auth_context{}) -> ok.
activity(#auth_context{tenant_id = TenantId, user_id = UserId}) ->
    case session_pid(TenantId, UserId) of
        undefined -> ok;
        Pid -> gen_statem:cast(Pid, {activity, cx_time:now_ms()})
    end.

%% Single home for the away threshold (config key + default); the
%% session's recompute reads it through here too.
-spec away_threshold_ms() -> pos_integer().
away_threshold_ms() ->
    cx_config:get(cx_presence, away_threshold_ms, ?AWAY_THRESHOLD_DEFAULT_MS).

%% ---- internals ----

fetch_active(TenantId, UserId) ->
    case cx_user:fetch(TenantId, UserId) of
        {ok, User = #cx_user{status = active}} -> {ok, User};
        {ok, #cx_user{}} -> {error, forbidden};
        {error, not_found} -> {error, forbidden}
    end.

session_pid(TenantId, UserId) ->
    case cx_registry:whereis_name({presence, TenantId, UserId}) of
        Pid when is_pid(Pid) -> Pid;
        _ -> undefined
    end.

%% Bounded retry closes the race between a session stopping on its last
%% disconnect and a new connection arriving for the same user.
register_connection(_T, _U, _ConnPid, _DeviceInfo, 0) ->
    {error, no_session};
register_connection(TenantId, UserId, ConnectionPid, DeviceInfo, Retries) ->
    Pid =
        case session_pid(TenantId, UserId) of
            undefined ->
                case cx_presence_session_sup:start_session(TenantId, UserId) of
                    {ok, P} -> P;
                    {error, {already_started, P}} -> P
                end;
            P ->
                P
        end,
    try gen_statem:call(Pid, {connected, ConnectionPid, DeviceInfo}, ?CALL_TIMEOUT) of
        ok -> {ok, Pid}
    catch
        exit:{noproc, _} ->
            register_connection(TenantId, UserId, ConnectionPid, DeviceInfo, Retries - 1);
        exit:{normal, _} ->
            register_connection(TenantId, UserId, ConnectionPid, DeviceInfo, Retries - 1);
        exit:{shutdown, _} ->
            register_connection(TenantId, UserId, ConnectionPid, DeviceInfo, Retries - 1)
    end.

read_declaration(TenantId, UserId) ->
    case mnesia:dirty_read(cx_presence_declaration, {TenantId, UserId}) of
        [Row] -> Row;
        [] -> undefined
    end.

parse_state(Params) ->
    case cx_params:optional_binary(Params, <<"state">>, undefined) of
        {ok, undefined} ->
            {ok, undefined};
        {ok, <<"automatic">>} ->
            {ok, undefined};
        {ok, State} ->
            case cx_presence_state:is_valid(State) of
                true -> {ok, State};
                false -> {error, {invalid, <<"state">>}}
            end;
        Error ->
            Error
    end.

%% until without anything to expire is meaningless; until in the past is
%% a client bug.
parse_until(Params, Manual, Message) ->
    case Params of
        #{<<"until">> := Until} when is_integer(Until) ->
            case
                Until > cx_time:now_ms() andalso (Manual =/= undefined orelse Message =/= undefined)
            of
                true -> {ok, Until};
                false -> {error, {invalid, <<"until">>}}
            end;
        #{<<"until">> := _} ->
            {error, {invalid, <<"until">>}};
        _ ->
            {ok, undefined}
    end.

%% After a declared write: the live session recomputes and publishes; a
%% connectionless user gets the lazy old/new comparison published by us.
propagate(TenantId, UserId, OldRow, Now) ->
    case session_pid(TenantId, UserId) of
        undefined ->
            Threshold = away_threshold_ms(),
            OldEffective = cx_presence_calculation:connectionless(OldRow, Now, Threshold),
            NewRow = read_declaration(TenantId, UserId),
            NewEffective = cx_presence_calculation:connectionless(NewRow, Now, Threshold),
            %% publish iff state/message changed — a pure `until` change
            %% is not a transition
            case maps:remove(until, NewEffective) =:= maps:remove(until, OldEffective) of
                true ->
                    ok;
                false ->
                    #{state := State, message := Message, until := NormUntil} = NewEffective,
                    cx_event:publish(TenantId, undefined, undefined, presence_changed, #{
                        <<"user_id">> => UserId,
                        <<"state">> => State,
                        <<"message">> => cx_json:undef_to_null(Message),
                        <<"until">> => cx_json:undef_to_null(NormUntil)
                    })
            end;
        Pid ->
            try
                gen_statem:call(Pid, refresh_declared, ?CALL_TIMEOUT)
            catch
                %% session stopped between check and call: the user just
                %% went offline; the offline publish already happened
                exit:_ -> ok
            end,
            ok
    end.

own_map(TenantId, UserId) ->
    Now = cx_time:now_ms(),
    Row = read_declaration(TenantId, UserId),
    Norm = cx_presence_calculation:normalize(cx_presence_calculation:from_row(Row), Now),
    {State, Message, DeviceCount} = effective_now(TenantId, UserId, Row, Now),
    #{
        <<"state">> => State,
        <<"manual_state">> => cx_json:undef_to_null(maps:get(manual_state, Norm)),
        <<"message">> => cx_json:undef_to_null(Message),
        <<"until">> => cx_json:undef_to_null(maps:get(until, Norm)),
        <<"device_count">> => DeviceCount,
        <<"updated_at">> => declaration_updated_at(Row)
    }.

effective_now(TenantId, UserId, Row, Now) ->
    case mnesia:dirty_read(cx_presence_effective, {TenantId, UserId}) of
        [#cx_presence_effective{pid = Pid, state = S, message = M, device_count = D}] ->
            case is_process_alive(Pid) of
                true ->
                    {S, M, D};
                false ->
                    drop_stale_effective(TenantId, UserId),
                    lazy_effective(Row, Now)
            end;
        [] ->
            lazy_effective(Row, Now)
    end.

lazy_effective(Row, Now) ->
    #{state := S, message := M} =
        cx_presence_calculation:connectionless(Row, Now, away_threshold_ms()),
    {S, M, 0}.

%% Live effective rows only; dead-pid rows are dropped (stale-snapshot pattern).
live_effective(TenantId) ->
    lists:foldl(
        fun(Row = #cx_presence_effective{key = {_, UserId}, pid = Pid}, Acc) ->
            case is_process_alive(Pid) of
                true ->
                    Acc#{UserId => Row};
                false ->
                    drop_stale_effective(TenantId, UserId),
                    Acc
            end
        end,
        #{},
        cx_store:dirty_list(cx_presence_effective, cx_patterns:presence_effective(TenantId))
    ).

directory_entry(#cx_user{key = {_, UserId}, name = Name}, EffectiveRows, DeclarationRows, Now) ->
    {State, Message, Until} =
        case EffectiveRows of
            #{UserId := #cx_presence_effective{state = S, message = M, until = U}} ->
                {S, M, U};
            _ ->
                Row = maps:get(UserId, DeclarationRows, undefined),
                #{state := S, message := M, until := U} =
                    cx_presence_calculation:connectionless(Row, Now, away_threshold_ms()),
                {S, M, U}
        end,
    #{
        <<"user_id">> => UserId,
        <<"name">> => Name,
        <<"state">> => State,
        <<"message">> => cx_json:undef_to_null(Message),
        <<"until">> => cx_json:undef_to_null(Until)
    }.

%% best-effort cleanup of an effective row whose owner died brutally
drop_stale_effective(TenantId, UserId) ->
    try
        mnesia:dirty_delete(cx_presence_effective, {TenantId, UserId})
    catch
        _:_ -> ok
    end,
    ok.

declaration_updated_at(undefined) -> null;
declaration_updated_at(#cx_presence_declaration{updated_at = At}) -> At.
