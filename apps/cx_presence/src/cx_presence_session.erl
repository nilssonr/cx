-module(cx_presence_session).

%% One gen_statem per user with at least one live connection. Owns the
%% connectivity observations (device pids, last activity) and the
%% presence timers; everything durable lives in cx_presence_declaration.
%%
%% Invariants:
%%   - this process exists  <=>  the user has >= 1 live connection
%%   - a cx_presence_effective row exists  <=>  this process owns it
%% The last disconnect publishes offline and stops immediately (no
%% linger) — flap dampening is the transport's reconnect concern, and
%% consumers must tolerate offline/online pairs anyway (crash recovery
%% produces the same sequence).
%%
%% recompute/1 is the single choke point every effective transition
%% passes through — a future tenant policy coupling presence to router
%% readiness (e.g. auto not-ready on dnd) hooks there.

-behaviour(gen_statem).

-include_lib("cx_core/include/cx_core.hrl").

-export([start_link/2]).
-export([callback_mode/0, init/1, handle_event/4, terminate/3]).

%% erlang timers cap at 2^32-1 ms (~49.7 days); longer `until`s re-arm.
-define(MAX_TIMER_MS, 4294967295).

-record(presence_session, {
    tenant :: binary(),
    user_id :: binary(),
    %% ConnectionPid => {MonitorRef, DeviceInfo}
    connections = #{} :: #{pid() => {reference(), map()}},
    declared :: cx_presence_calculation:declared(),
    last_activity :: integer(),
    %% last published {State, Message}; undefined forces first publish
    last_effective :: {binary(), binary() | undefined} | undefined
}).

start_link(TenantId, UserId) ->
    gen_statem:start_link(
        {via, cx_registry, {presence, TenantId, UserId}},
        ?MODULE,
        [TenantId, UserId],
        []
    ).

callback_mode() -> handle_event_function.

init([TenantId, UserId]) ->
    Data = #presence_session{
        tenant = TenantId,
        user_id = UserId,
        declared = read_declared(TenantId, UserId),
        last_activity = cx_time:now_ms()
    },
    {ok, active, Data}.

handle_event({call, From}, {connected, ConnectionPid, DeviceInfo}, _S, Data) ->
    Connections0 = Data#presence_session.connections,
    Connections1 =
        case maps:take(ConnectionPid, Connections0) of
            {{OldRef, _}, Rest} ->
                erlang:demonitor(OldRef, [flush]),
                Rest;
            error ->
                Connections0
        end,
    MonitorRef = erlang:monitor(process, ConnectionPid),
    Data1 = Data#presence_session{
        connections = Connections1#{ConnectionPid => {MonitorRef, DeviceInfo}},
        last_activity = cx_time:now_ms()
    },
    {Data2, Actions} = recompute(Data1),
    {keep_state, Data2, [{reply, From, ok} | Actions]};
handle_event(cast, {disconnected, ConnectionPid}, _S, Data) ->
    drop_connection(ConnectionPid, Data);
handle_event(info, {'DOWN', _Ref, process, ConnectionPid, _Reason}, _S, Data) ->
    drop_connection(ConnectionPid, Data);
handle_event(cast, {activity, NowMs}, _S, Data) ->
    Data1 = Data#presence_session{last_activity = max(Data#presence_session.last_activity, NowMs)},
    {Data2, Actions} = recompute(Data1),
    {keep_state, Data2, Actions};
handle_event({call, From}, refresh_declared, _S, Data) ->
    Data1 = Data#presence_session{
        declared = read_declared(Data#presence_session.tenant, Data#presence_session.user_id)
    },
    {Data2, Actions} = recompute(Data1),
    {keep_state, Data2, [{reply, From, ok} | Actions]};
handle_event({timeout, away}, check, _S, Data) ->
    {Data1, Actions} = recompute(Data),
    {keep_state, Data1, Actions};
handle_event({timeout, until_expiry}, expire, _S, Data) ->
    %% pure wake-up: normalization makes the expired layer vanish; a
    %% premature fire (clamped long timer) just re-arms
    {Data1, Actions} = recompute(Data),
    {keep_state, Data1, Actions};
handle_event(_Type, _Event, _S, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, Data) ->
    try
        mnesia:dirty_delete(cx_presence_effective, {
            Data#presence_session.tenant, Data#presence_session.user_id
        })
    catch
        _:_ -> ok
    end,
    ok.

%% ---- internals ----

drop_connection(ConnectionPid, Data) ->
    case maps:take(ConnectionPid, Data#presence_session.connections) of
        error ->
            keep_state_and_data;
        {{MonitorRef, _}, Rest} ->
            erlang:demonitor(MonitorRef, [flush]),
            Data1 = Data#presence_session{connections = Rest},
            case map_size(Rest) of
                0 ->
                    %% last device gone: publish offline, drop the eff
                    %% row (terminate repeats the delete harmlessly), go
                    {Data2, _Actions} = recompute(Data1),
                    {stop, normal, Data2};
                _ ->
                    {Data2, Actions} = recompute(Data1),
                    {keep_state, Data2, Actions}
            end
    end.

read_declared(TenantId, UserId) ->
    Row =
        case mnesia:dirty_read(cx_presence_declaration, {TenantId, UserId}) of
            [R] -> R;
            [] -> undefined
        end,
    cx_presence_calculation:from_row(Row).

%% The single choke point: pure calc -> eff-row write -> publish iff
%% changed -> re-arm timers. (Future presence->readiness tenant policy
%% hooks here.)
recompute(Data = #presence_session{tenant = T, user_id = U}) ->
    Now = cx_time:now_ms(),
    Threshold = cx_presence:away_threshold_ms(),
    DeviceCount = map_size(Data#presence_session.connections),
    #{state := State, message := Message} =
        cx_presence_calculation:effective(
            Data#presence_session.declared,
            DeviceCount,
            Data#presence_session.last_activity,
            Now,
            Threshold
        ),
    #{manual_state := NormManual, until := NormUntil} =
        cx_presence_calculation:normalize(Data#presence_session.declared, Now),
    write_effective(Data, State, Message, NormUntil, DeviceCount, Now),
    Changed = {State, Message} =/= Data#presence_session.last_effective,
    Changed andalso publish(T, U, State, Message, NormUntil),
    Actions =
        away_action(State, NormManual, Data#presence_session.last_activity, Threshold, Now) ++
            until_action(NormUntil, Now),
    {Data#presence_session{last_effective = {State, Message}}, Actions}.

write_effective(
    #presence_session{tenant = T, user_id = U}, State, Message, Until, DeviceCount, Now
) ->
    ok = mnesia:dirty_write(#cx_presence_effective{
        key = {T, U},
        pid = self(),
        state = State,
        message = Message,
        until = Until,
        device_count = DeviceCount,
        updated_at = Now
    }).

publish(TenantId, UserId, State, Message, Until) ->
    cx_event:publish(TenantId, undefined, undefined, presence_changed, #{
        <<"user_id">> => UserId,
        <<"state">> => State,
        <<"message">> => cx_json:undef_to_null(Message),
        <<"until">> => cx_json:undef_to_null(Until)
    }).

%% away timer only runs while automatically online — it wakes us at the
%% moment idleness crosses the threshold
away_action(<<"online">>, undefined, LastActivity, Threshold, Now) ->
    [{{timeout, away}, max(1, LastActivity + Threshold - Now), check}];
away_action(_State, _Manual, _LA, _Thr, _Now) ->
    [{{timeout, away}, cancel}].

until_action(undefined, _Now) ->
    [{{timeout, until_expiry}, cancel}];
until_action(Until, Now) ->
    [{{timeout, until_expiry}, min(max(1, Until - Now), ?MAX_TIMER_MS), expire}].
