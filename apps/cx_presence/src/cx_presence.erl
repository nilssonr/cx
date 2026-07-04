-module(cx_presence).

%% Domain facade for collaboration presence. Two surfaces:
%%   - #auth_ctx{} functions for transports (set_own/get_own/directory)
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

-define(CALL_TIMEOUT, 5000).
-define(CONNECT_RETRIES, 3).

%% ---- domain surface ----

set_own(Ctx = #auth_ctx{tenant_id = T, user_id = UserId}, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"presence:set:self">>),
        ok ?= known_user(UserId),
        {ok, Manual} ?= parse_state(Params),
        {ok, Message} ?= cx_params:opt_bin(Params, <<"message">>, undefined),
        {ok, Until} ?= parse_until(Params, Manual, Message),
        Now = cx_time:now_ms(),
        OldRow = read_decl(T, UserId),
        ok = cx_store:tx(fun() ->
            case {Manual, Message, Until} of
                {undefined, undefined, undefined} ->
                    mnesia:delete({cx_presence_decl, {T, UserId}});
                _ ->
                    mnesia:write(#cx_presence_decl{
                        key = {T, UserId},
                        manual_state = Manual,
                        message = Message,
                        until = Until,
                        updated_at = Now
                    })
            end
        end),
        ok = propagate(T, UserId, OldRow, Now),
        get_own(Ctx)
    end.

get_own(Ctx = #auth_ctx{tenant_id = T, user_id = UserId}) ->
    maybe
        ok ?= known_user(UserId),
        _ = Ctx,
        {ok, own_map(T, UserId)}
    end.

%% Any authenticated tenant member may read the directory (agents need
%% their coworkers) — the not-ready-reason-read precedent.
directory(#auth_ctx{tenant_id = T}) ->
    Now = cx_time:now_ms(),
    Effs = live_effs(T),
    Decls = lists:foldl(
        fun(R = #cx_presence_decl{key = {_, UserId}}, Acc) ->
            Acc#{UserId => R}
        end,
        #{},
        cx_store:dirty_list(cx_presence_decl, cx_patterns:presence_decls(T))
    ),
    {ok, [
        directory_entry(U, Effs, Decls, Now)
     || U = #cx_user{status = active} <- cx_store:dirty_list(cx_user, cx_patterns:users(T))
    ]}.

%% ---- transport-internal connectivity signals ----

-spec connected(#auth_ctx{}, pid(), map()) -> {ok, pid()} | {error, term()}.
connected(#auth_ctx{tenant_id = T, user_id = UserId}, ConnPid, DeviceInfo) ->
    maybe
        ok ?= known_user(UserId),
        {ok, #cx_user{status = active}} ?= fetch_active(T, UserId),
        register_conn(T, UserId, ConnPid, DeviceInfo, ?CONNECT_RETRIES)
    end.

-spec disconnected(#auth_ctx{}, pid()) -> ok.
disconnected(#auth_ctx{tenant_id = T, user_id = UserId}, ConnPid) ->
    case session_pid(T, UserId) of
        undefined -> ok;
        Pid -> gen_statem:cast(Pid, {disconnected, ConnPid})
    end.

-spec activity(#auth_ctx{}) -> ok.
activity(#auth_ctx{tenant_id = T, user_id = UserId}) ->
    case session_pid(T, UserId) of
        undefined -> ok;
        Pid -> gen_statem:cast(Pid, {activity, cx_time:now_ms()})
    end.

%% ---- internals ----

known_user(undefined) -> {error, no_user};
known_user(_) -> ok.

fetch_active(T, UserId) ->
    case cx_user:fetch(T, UserId) of
        {ok, User = #cx_user{status = active}} -> {ok, User};
        {ok, #cx_user{}} -> {error, forbidden};
        {error, not_found} -> {error, forbidden}
    end.

session_pid(T, UserId) ->
    case cx_reg:whereis_name({presence, T, UserId}) of
        Pid when is_pid(Pid) -> Pid;
        _ -> undefined
    end.

%% Bounded retry closes the race between a session stopping on its last
%% disconnect and a new connection arriving for the same user.
register_conn(_T, _U, _ConnPid, _DeviceInfo, 0) ->
    {error, no_session};
register_conn(T, U, ConnPid, DeviceInfo, Retries) ->
    Pid =
        case session_pid(T, U) of
            undefined ->
                case cx_presence_session_sup:start_session(T, U) of
                    {ok, P} -> P;
                    {error, {already_started, P}} -> P
                end;
            P ->
                P
        end,
    try gen_statem:call(Pid, {connected, ConnPid, DeviceInfo}, ?CALL_TIMEOUT) of
        ok -> {ok, Pid}
    catch
        exit:{noproc, _} -> register_conn(T, U, ConnPid, DeviceInfo, Retries - 1);
        exit:{normal, _} -> register_conn(T, U, ConnPid, DeviceInfo, Retries - 1);
        exit:{shutdown, _} -> register_conn(T, U, ConnPid, DeviceInfo, Retries - 1)
    end.

read_decl(T, UserId) ->
    case mnesia:dirty_read(cx_presence_decl, {T, UserId}) of
        [Row] -> Row;
        [] -> undefined
    end.

parse_state(Params) ->
    case cx_params:opt_bin(Params, <<"state">>, undefined) of
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
        #{<<"until">> := U} when is_integer(U) ->
            case U > cx_time:now_ms() andalso (Manual =/= undefined orelse Message =/= undefined) of
                true -> {ok, U};
                false -> {error, {invalid, <<"until">>}}
            end;
        #{<<"until">> := _} ->
            {error, {invalid, <<"until">>}};
        _ ->
            {ok, undefined}
    end.

%% After a declared write: the live session recomputes and publishes; a
%% connectionless user gets the lazy old/new comparison published by us.
propagate(T, UserId, OldRow, Now) ->
    case session_pid(T, UserId) of
        undefined ->
            Threshold = cx_cfg:get(cx_presence, away_threshold_ms, 300000),
            OldEff = cx_presence_calc:effective(
                cx_presence_calc:from_row(OldRow), 0, 0, Now, Threshold
            ),
            NewRow = read_decl(T, UserId),
            NewEff = cx_presence_calc:effective(
                cx_presence_calc:from_row(NewRow), 0, 0, Now, Threshold
            ),
            #{until := NormUntil} =
                cx_presence_calc:normalize(cx_presence_calc:from_row(NewRow), Now),
            case NewEff =:= OldEff of
                true ->
                    ok;
                false ->
                    #{state := State, message := Message} = NewEff,
                    cx_event:publish(T, undefined, undefined, #{
                        type => presence_changed,
                        at => Now,
                        data => #{
                            <<"user_id">> => UserId,
                            <<"state">> => State,
                            <<"message">> => undef_to_null(Message),
                            <<"until">> => undef_to_null(NormUntil)
                        }
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

own_map(T, UserId) ->
    Now = cx_time:now_ms(),
    Row = read_decl(T, UserId),
    Norm = cx_presence_calc:normalize(cx_presence_calc:from_row(Row), Now),
    {State, Message, DeviceCount} = effective_now(T, UserId, Row, Now),
    #{
        <<"state">> => State,
        <<"manual_state">> => undef_to_null(maps:get(manual_state, Norm)),
        <<"message">> => undef_to_null(Message),
        <<"until">> => undef_to_null(maps:get(until, Norm)),
        <<"device_count">> => DeviceCount,
        <<"updated_at">> => decl_updated_at(Row)
    }.

effective_now(T, UserId, Row, Now) ->
    case mnesia:dirty_read(cx_presence_eff, {T, UserId}) of
        [#cx_presence_eff{pid = Pid, state = S, message = M, device_count = D}] ->
            case is_process_alive(Pid) of
                true ->
                    {S, M, D};
                false ->
                    drop_stale_eff(T, UserId),
                    lazy_effective(Row, Now)
            end;
        [] ->
            lazy_effective(Row, Now)
    end.

lazy_effective(Row, Now) ->
    Threshold = cx_cfg:get(cx_presence, away_threshold_ms, 300000),
    #{state := S, message := M} =
        cx_presence_calc:effective(cx_presence_calc:from_row(Row), 0, 0, Now, Threshold),
    {S, M, 0}.

%% Live eff rows only; dead-pid rows are dropped (stale-snapshot pattern).
live_effs(T) ->
    lists:foldl(
        fun(Row = #cx_presence_eff{key = {_, UserId}, pid = Pid}, Acc) ->
            case is_process_alive(Pid) of
                true ->
                    Acc#{UserId => Row};
                false ->
                    drop_stale_eff(T, UserId),
                    Acc
            end
        end,
        #{},
        cx_store:dirty_list(cx_presence_eff, cx_patterns:presence_effs(T))
    ).

directory_entry(#cx_user{key = {_, UserId}, name = Name}, Effs, Decls, Now) ->
    {State, Message, Until} =
        case Effs of
            #{UserId := #cx_presence_eff{state = S, message = M, until = U}} ->
                {S, M, U};
            _ ->
                Row = maps:get(UserId, Decls, undefined),
                Threshold = cx_cfg:get(cx_presence, away_threshold_ms, 300000),
                #{state := S, message := M} =
                    cx_presence_calc:effective(
                        cx_presence_calc:from_row(Row), 0, 0, Now, Threshold
                    ),
                #{until := U} =
                    cx_presence_calc:normalize(cx_presence_calc:from_row(Row), Now),
                {S, M, U}
        end,
    #{
        <<"user_id">> => UserId,
        <<"name">> => Name,
        <<"state">> => State,
        <<"message">> => undef_to_null(Message),
        <<"until">> => undef_to_null(Until)
    }.

%% best-effort cleanup of an eff row whose owner died brutally
drop_stale_eff(T, UserId) ->
    try
        mnesia:dirty_delete(cx_presence_eff, {T, UserId})
    catch
        _:_ -> ok
    end,
    ok.

decl_updated_at(undefined) -> null;
decl_updated_at(#cx_presence_decl{updated_at = At}) -> At.

undef_to_null(undefined) -> null;
undef_to_null(V) -> V.
