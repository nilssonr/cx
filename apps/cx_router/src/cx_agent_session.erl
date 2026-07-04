-module(cx_agent_session).

%% One gen_statem per signed-in agent. States: online | wrap_up — wrap_up
%% differs in exactly one way: offers are refused. Readiness, capacity and
%% current mix are orthogonal per-media data, not states.
%%
%% Call discipline (deadlock safety): queues CALL sessions (offers) and
%% CAST them outcomes; sessions never call queues. Accept/reject flow
%% through the facade to the queue, which is the single serialization
%% point for offer races.
%%
%% Every mutation ends with a presence write; the presence row is a cache
%% the queues read dirty — the offer call to this process revalidates.

-behaviour(gen_statem).

-include_lib("cx_core/include/cx_core.hrl").

-export([start_link/4]).
-export([callback_mode/0, init/1, handle_event/4, terminate/3]).

-record(sess, {
    tenant :: binary(),
    agent_id :: binary(),
    profile :: #cx_routing_profile{},
    skills :: #{binary() => pos_integer()},
    ready = #{} :: #{binary() => ready | {not_ready, binary() | undefined}},
    %% InteractionId => {MediaTypeId, QueueKey}
    active = #{} :: map(),
    %% OfferId => {InteractionId, MediaTypeId, QueueKey, QueuePid, MonRef}
    pending = #{} :: map(),
    wrapup_until = 0 :: integer(),
    idle_since :: integer()
}).

start_link(TenantId, AgentId, Skills, Profile) ->
    gen_statem:start_link(
        {via, cx_reg, {agent, TenantId, AgentId}},
        ?MODULE,
        [TenantId, AgentId, Skills, Profile],
        []
    ).

callback_mode() -> handle_event_function.

init([TenantId, AgentId, Skills, Profile]) ->
    Data = #sess{
        tenant = TenantId,
        agent_id = AgentId,
        skills = Skills,
        profile = Profile,
        idle_since = cx_time:now_ms()
    },
    write_presence(Data),
    publish(Data, undefined, undefined, session_started, #{}),
    {ok, online, Data}.

%% ---- readiness ----

handle_event({call, From}, {set_ready, Media, NewState}, _State, Data) ->
    Data1 = Data#sess{ready = maps:put(Media, NewState, Data#sess.ready)},
    write_presence(Data1),
    publish(
        Data1,
        undefined,
        Media,
        agent_ready_changed,
        #{
            <<"media_type_id">> => Media,
            <<"state">> => ready_to_bin(NewState)
        }
    ),
    NewState =:= ready andalso cx_router_signal:agent_available(Data1#sess.tenant),
    {keep_state, Data1, [{reply, From, ok}]};
%% ---- offers ----

handle_event({call, From}, {offer, _Offer}, wrap_up, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_routable}}]};
handle_event({call, From}, {offer, Offer}, online, Data) ->
    #{
        offer_id := OfferId,
        interaction_id := IId,
        media := Media,
        queue_key := QueueKey,
        queue_pid := QueuePid
    } = Offer,
    Routable =
        maps:get(Media, Data#sess.ready, undefined) =:= ready andalso
            cx_routing:can_route(Data#sess.profile, mix_of(Data), Media),
    case Routable of
        true ->
            MonRef = erlang:monitor(process, QueuePid),
            Pending = maps:put(
                OfferId,
                {IId, Media, QueueKey, QueuePid, MonRef},
                Data#sess.pending
            ),
            Data1 = Data#sess{pending = Pending},
            write_presence(Data1),
            {keep_state, Data1, [{reply, From, ok}]};
        false ->
            {keep_state_and_data, [{reply, From, {error, not_routable}}]}
    end;
handle_event({call, From}, {pending_queue, OfferId}, _State, Data) ->
    case Data#sess.pending of
        #{OfferId := {_, _, _, QueuePid, _}} ->
            {keep_state_and_data, [{reply, From, {ok, QueuePid}}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
handle_event(cast, {offer_accepted, OfferId}, _State, Data) ->
    case maps:take(OfferId, Data#sess.pending) of
        {{IId, Media, QueueKey, _QueuePid, MonRef}, Pending} ->
            erlang:demonitor(MonRef, [flush]),
            Data1 = Data#sess{
                pending = Pending,
                active = maps:put(
                    IId,
                    {Media, QueueKey},
                    Data#sess.active
                )
            },
            write_presence(Data1),
            {keep_state, Data1};
        error ->
            keep_state_and_data
    end;
handle_event(cast, {offer_withdrawn, OfferId}, _State, Data) ->
    case maps:take(OfferId, Data#sess.pending) of
        {{_, _, _, _, MonRef}, Pending} ->
            erlang:demonitor(MonRef, [flush]),
            Data1 = touch_idle(Data#sess{pending = Pending}),
            write_presence(Data1),
            %% a reservation was released — capacity may have opened up
            cx_router_signal:agent_available(Data1#sess.tenant),
            {keep_state, Data1};
        error ->
            keep_state_and_data
    end;
%% ---- completion and wrap-up ----

handle_event({call, From}, {complete, IId}, State, Data) ->
    case maps:take(IId, Data#sess.active) of
        {{Media, QueueKey = {_Tenant, QueueId}}, Active} ->
            ok = complete_interaction(Data, IId),
            publish(
                Data,
                QueueId,
                Media,
                interaction_completed,
                #{
                    <<"interaction_id">> => IId,
                    <<"agent_id">> => Data#sess.agent_id
                }
            ),
            WrapupMs = wrapup_duration(QueueKey),
            Now = cx_time:now_ms(),
            Data1 = touch_idle(Data#sess{active = Active}),
            case WrapupMs > 0 of
                true ->
                    Until = max(Data1#sess.wrapup_until, Now + WrapupMs),
                    Data2 = Data1#sess{wrapup_until = Until},
                    write_presence(Data2),
                    publish(
                        Data2,
                        QueueId,
                        Media,
                        wrapup_started,
                        #{
                            <<"agent_id">> => Data2#sess.agent_id,
                            <<"until">> => Until
                        }
                    ),
                    {next_state, wrap_up, Data2, [
                        {reply, From, ok},
                        {{timeout, wrapup}, Until - Now, expire}
                    ]};
                false ->
                    write_presence(Data1),
                    cx_router_signal:agent_available(Data1#sess.tenant),
                    {next_state, State, Data1, [{reply, From, ok}]}
            end;
        error ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
handle_event({call, From}, {extend_wrapup, Ms}, wrap_up, Data) ->
    Now = cx_time:now_ms(),
    Until = Data#sess.wrapup_until + Ms,
    Data1 = Data#sess{wrapup_until = Until},
    write_presence(Data1),
    publish(
        Data1,
        undefined,
        undefined,
        wrapup_extended,
        #{<<"agent_id">> => Data1#sess.agent_id, <<"until">> => Until}
    ),
    {keep_state, Data1, [
        {reply, From, ok},
        {{timeout, wrapup}, Until - Now, expire}
    ]};
handle_event({call, From}, {extend_wrapup, _Ms}, online, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_in_wrapup}}]};
handle_event({call, From}, cancel_wrapup, wrap_up, Data) ->
    Data1 = Data#sess{wrapup_until = 0},
    write_presence(Data1),
    publish(
        Data1,
        undefined,
        undefined,
        wrapup_cancelled,
        #{<<"agent_id">> => Data1#sess.agent_id}
    ),
    cx_router_signal:agent_available(Data1#sess.tenant),
    {next_state, online, Data1, [{reply, From, ok}, {{timeout, wrapup}, cancel}]};
handle_event({call, From}, cancel_wrapup, online, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_in_wrapup}}]};
handle_event({timeout, wrapup}, expire, wrap_up, Data) ->
    Data1 = Data#sess{wrapup_until = 0},
    write_presence(Data1),
    publish(
        Data1,
        undefined,
        undefined,
        wrapup_ended,
        #{<<"agent_id">> => Data1#sess.agent_id}
    ),
    cx_router_signal:agent_available(Data1#sess.tenant),
    {next_state, online, Data1};
%% ---- introspection and shutdown ----

handle_event({call, From}, get_state, State, Data) ->
    Info = #{
        <<"agent_id">> => Data#sess.agent_id,
        <<"ready">> => maps:map(
            fun(_, V) -> ready_to_bin(V) end,
            Data#sess.ready
        ),
        <<"active">> => maps:keys(Data#sess.active),
        <<"pending_offers">> => maps:keys(Data#sess.pending),
        <<"in_wrapup">> => State =:= wrap_up,
        <<"wrapup_until">> => Data#sess.wrapup_until
    },
    {keep_state_and_data, [{reply, From, {ok, Info}}]};
handle_event({call, From}, stop_session, _State, Data) ->
    case maps:size(Data#sess.active) of
        0 ->
            %% hand pending offers back; the queue requeues at original
            %% position and we're gone before its cast comes back
            maps:foreach(
                fun(OfferId, {_, _, _, QueuePid, _}) ->
                    gen_statem:cast(QueuePid, {reject_cast, OfferId})
                end,
                Data#sess.pending
            ),
            publish(Data, undefined, undefined, session_ended, #{}),
            {stop_and_reply, normal, [{reply, From, ok}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, has_active_interactions}}]}
    end;
handle_event(info, {'DOWN', MonRef, process, _Pid, _Reason}, _State, Data) ->
    %% a queue died while we held offers from it — drop those reservations
    Pending = maps:filter(
        fun(_, {_, _, _, _, Ref}) -> Ref =/= MonRef end,
        Data#sess.pending
    ),
    case maps:size(Pending) =:= maps:size(Data#sess.pending) of
        true ->
            keep_state_and_data;
        false ->
            Data1 = touch_idle(Data#sess{pending = Pending}),
            write_presence(Data1),
            {keep_state, Data1}
    end;
handle_event(_Type, _Event, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, Data) ->
    try
        mnesia:dirty_delete(
            cx_agent_presence,
            {Data#sess.tenant, Data#sess.agent_id}
        )
    catch
        _:_ -> ok
    end,
    ok.

%% ---- helpers ----

mix_of(#sess{active = Active, pending = Pending}) ->
    Add = fun(Media, Acc) -> maps:update_with(Media, fun(N) -> N + 1 end, 1, Acc) end,
    Mix0 = maps:fold(fun(_, {Media, _}, Acc) -> Add(Media, Acc) end, #{}, Active),
    maps:fold(fun(_, {_, Media, _, _, _}, Acc) -> Add(Media, Acc) end, Mix0, Pending).

touch_idle(Data = #sess{active = Active, pending = Pending}) ->
    case maps:size(Active) + maps:size(Pending) of
        0 -> Data#sess{idle_since = cx_time:now_ms()};
        _ -> Data
    end.

write_presence(Data = #sess{tenant = Tenant, agent_id = AgentId}) ->
    Rec = #cx_agent_presence{
        key = {Tenant, AgentId},
        pid = self(),
        ready = Data#sess.ready,
        mix = mix_of(Data),
        wrapup_until = Data#sess.wrapup_until,
        skills = Data#sess.skills,
        profile = Data#sess.profile,
        idle_since = Data#sess.idle_since
    },
    ok = mnesia:dirty_write(Rec).

complete_interaction(#sess{tenant = Tenant, agent_id = AgentId}, IId) ->
    cx_store:tx(fun() ->
        case mnesia:read(cx_interaction, {Tenant, IId}) of
            [Rec = #cx_interaction{state = active}] ->
                mnesia:write(Rec#cx_interaction{
                    state = completed,
                    agent_id = AgentId,
                    completed_at = cx_time:now_ms()
                });
            _ ->
                ok
        end
    end).

wrapup_duration({Tenant, QueueId}) ->
    case cx_queue:fetch(Tenant, QueueId) of
        {ok, #cx_queue{wrapup_duration_ms = Ms}} -> Ms;
        {error, not_found} -> 0
    end.

ready_to_bin(ready) -> <<"ready">>;
ready_to_bin({not_ready, undefined}) -> <<"not_ready">>;
ready_to_bin({not_ready, Reason}) -> <<"not_ready:", Reason/binary>>.

publish(#sess{tenant = Tenant}, QueueId, Media, Type, ExtraData) ->
    cx_event:publish(
        Tenant,
        QueueId,
        Media,
        #{type => Type, at => cx_time:now_ms(), data => ExtraData}
    ).
