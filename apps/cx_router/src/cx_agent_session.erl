-module(cx_agent_session).

%% One gen_statem per signed-in agent ("agent session" = the signed-in
%% work session; the customer session is the interaction). The statem has
%% a single state — everything else (readiness, capacity, per-interaction
%% phase) is orthogonal data.
%%
%% Each owned interaction carries its own phase: active <-> held ->
%% wrapup (after-call work). ALL phases occupy capacity in the mix, so
%% ACW blocks new offers of that media purely through the routing
%% profile — an agent without capacity limits is never blocked, by
%% design (the superhuman/bot case).
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

%% One owned interaction (accepted offer) and its lifecycle phase.
%% q_required snapshots the queue's qualification_required at ACW entry
%% (mid-flight config changes don't retroactively trap an agent);
%% qualified tracks whether the interaction currently carries codes —
%% authoritative here because every qualification write flows through
%% this process.
-record(work, {
    media :: binary(),
    queue_key :: {binary(), binary()},
    phase = active :: active | held | wrapup,
    wrapup_started_at :: integer() | undefined,
    wrapup_until :: integer() | undefined,
    q_required = false :: boolean(),
    qualified = false :: boolean()
}).

%% One pending (ringing) offer as this session sees it. expires_at is
%% the queue-computed ring deadline (undefined = ring forever); the
%% queue's timer is authoritative — this copy only feeds read surfaces.
-record(offer, {
    interaction_id :: binary(),
    media :: binary(),
    queue_key :: {binary(), binary()},
    queue_pid :: pid(),
    mon_ref :: reference(),
    expires_at :: integer() | undefined
}).

-record(sess, {
    tenant :: binary(),
    agent_id :: binary(),
    profile :: #cx_routing_profile{},
    skills :: #{binary() => pos_integer()},
    ready = #{} :: #{binary() => ready | {not_ready, binary() | undefined}},
    %% InteractionId => #work{}
    work = #{} :: #{binary() => #work{}},
    %% OfferId => #offer{}
    pending = #{} :: #{binary() => #offer{}},
    %% [{OfferId, InteractionId}] most-recent-first, capped — serves
    %% retried accepts after the offer left `pending` (idempotency)
    recent_accepts = [] :: [{binary(), binary()}],
    idle_since :: integer()
}).

-define(RECENT_ACCEPTS_MAX, 50).

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
    write_snapshot(Data),
    publish(Data, undefined, undefined, session_started, #{
        <<"agent_id">> => AgentId
    }),
    {ok, online, Data}.

%% ---- readiness ----

handle_event({call, From}, {set_ready, Media, NewState}, _State, Data) ->
    Data1 = Data#sess{ready = maps:put(Media, NewState, Data#sess.ready)},
    write_snapshot(Data1),
    publish(
        Data1,
        undefined,
        Media,
        agent_ready_changed,
        #{
            <<"agent_id">> => Data1#sess.agent_id,
            <<"media_type">> => Media,
            <<"ready">> => ready_to_json(NewState)
        }
    ),
    NewState =:= ready andalso cx_router_signal:agent_available(Data1#sess.tenant),
    {keep_state, Data1, [{reply, From, ok}]};
%% ---- offers ----

handle_event({call, From}, {offer, Offer}, _State, Data) ->
    #{
        offer_id := OfferId,
        interaction_id := IId,
        media := Media,
        queue_key := QueueKey,
        queue_pid := QueuePid,
        expires_at := ExpiresAt
    } = Offer,
    Routable =
        maps:get(Media, Data#sess.ready, undefined) =:= ready andalso
            cx_routing:can_route(Data#sess.profile, mix_of(Data), Media),
    case Routable of
        true ->
            MonRef = erlang:monitor(process, QueuePid),
            Pending = maps:put(
                OfferId,
                #offer{
                    interaction_id = IId,
                    media = Media,
                    queue_key = QueueKey,
                    queue_pid = QueuePid,
                    mon_ref = MonRef,
                    expires_at = null_to_undef(ExpiresAt)
                },
                Data#sess.pending
            ),
            Data1 = Data#sess{pending = Pending},
            write_snapshot(Data1),
            {keep_state, Data1, [{reply, From, ok}]};
        false ->
            {keep_state_and_data, [{reply, From, {error, not_routable}}]}
    end;
handle_event({call, From}, {pending_queue, OfferId}, _State, Data) ->
    case Data#sess.pending of
        #{OfferId := #offer{queue_pid = QueuePid}} ->
            {keep_state_and_data, [{reply, From, {ok, QueuePid}}]};
        _ ->
            case lists:keyfind(OfferId, 1, Data#sess.recent_accepts) of
                {OfferId, IId} ->
                    {keep_state_and_data, [{reply, From, {recently_accepted, IId}}]};
                false ->
                    {keep_state_and_data, [{reply, From, {error, not_found}}]}
            end
    end;
handle_event({call, From}, list_offers, _State, Data) ->
    Offers = [
        offer_to_map(OfferId, O)
     || OfferId := O <- Data#sess.pending
    ],
    {keep_state_and_data, [{reply, From, {ok, Offers}}]};
handle_event({call, From}, {get_offer, OfferId}, _State, Data) ->
    case Data#sess.pending of
        #{OfferId := O} ->
            {keep_state_and_data, [{reply, From, {ok, offer_to_map(OfferId, O)}}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
handle_event(cast, {offer_accepted, OfferId}, _State, Data) ->
    case maps:take(OfferId, Data#sess.pending) of
        {
            #offer{interaction_id = IId, media = Media, queue_key = QueueKey, mon_ref = MonRef},
            Pending
        } ->
            erlang:demonitor(MonRef, [flush]),
            Data1 = Data#sess{
                pending = Pending,
                work = maps:put(
                    IId,
                    #work{media = Media, queue_key = QueueKey},
                    Data#sess.work
                ),
                recent_accepts = lists:sublist(
                    [{OfferId, IId} | Data#sess.recent_accepts],
                    ?RECENT_ACCEPTS_MAX
                )
            },
            write_snapshot(Data1),
            {keep_state, Data1};
        error ->
            keep_state_and_data
    end;
handle_event(cast, {offer_withdrawn, OfferId}, _State, Data) ->
    case maps:take(OfferId, Data#sess.pending) of
        {#offer{mon_ref = MonRef}, Pending} ->
            erlang:demonitor(MonRef, [flush]),
            Data1 = touch_idle(Data#sess{pending = Pending}),
            write_snapshot(Data1),
            %% a reservation was released — capacity may have opened up
            cx_router_signal:agent_available(Data1#sess.tenant),
            {keep_state, Data1};
        error ->
            keep_state_and_data
    end;
%% ---- hold / resume ----

handle_event({call, From}, {hold, IId}, _State, Data) ->
    case Data#sess.work of
        #{IId := W = #work{phase = active}} ->
            case set_state(Data, IId, active, held, #{}) of
                ok ->
                    Data1 = put_work(IId, W#work{phase = held}, Data),
                    publish_i(Data1, W, IId, interaction_held, #{}),
                    {keep_state, Data1, [{reply, From, ok}]};
                {error, conflict} ->
                    {keep_state_and_data, [{reply, From, {error, conflict}}]}
            end;
        #{IId := _} ->
            {keep_state_and_data, [{reply, From, {error, not_active}}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
handle_event({call, From}, {resume, IId}, _State, Data) ->
    case Data#sess.work of
        #{IId := W = #work{phase = held}} ->
            case set_state(Data, IId, held, active, #{}) of
                ok ->
                    Data1 = put_work(IId, W#work{phase = active}, Data),
                    publish_i(Data1, W, IId, interaction_resumed, #{}),
                    {keep_state, Data1, [{reply, From, ok}]};
                {error, conflict} ->
                    {keep_state_and_data, [{reply, From, {error, conflict}}]}
            end;
        #{IId := _} ->
            {keep_state_and_data, [{reply, From, {error, not_held}}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
%% ---- completion and after-call work ----

handle_event({call, From}, {complete, IId}, _State, Data) ->
    case Data#sess.work of
        #{IId := W = #work{phase = Phase}} when Phase =:= active; Phase =:= held ->
            Now = cx_time:now_ms(),
            {WrapupMs, QRequired} = wrapup_policy(W#work.queue_key),
            case WrapupMs > 0 of
                true ->
                    Until = Now + WrapupMs,
                    case
                        set_state(Data, IId, Phase, wrapup, #{
                            wrapup_started_at => Now,
                            wrapup_until => Until
                        })
                    of
                        ok ->
                            W1 = W#work{
                                phase = wrapup,
                                wrapup_started_at = Now,
                                wrapup_until = Until,
                                q_required = QRequired
                            },
                            Data1 = put_work(IId, W1, Data),
                            publish_i(Data1, W1, IId, wrapup_started, #{
                                <<"until">> => Until
                            }),
                            {keep_state, Data1, [
                                {reply, From,
                                    {ok, #{
                                        <<"state">> => <<"wrapup">>,
                                        <<"wrapup_until">> => Until
                                    }}},
                                {{timeout, {wrapup, IId}}, Until - Now, expire}
                            ]};
                        {error, conflict} ->
                            {keep_state_and_data, [{reply, From, {error, conflict}}]}
                    end;
                false ->
                    case finalize(Data, IId, W, undefined) of
                        {ok, Data1} ->
                            {keep_state, Data1, [{reply, From, ok}]};
                        {error, conflict} ->
                            {keep_state_and_data, [{reply, From, {error, conflict}}]}
                    end
            end;
        #{IId := _} ->
            {keep_state_and_data, [{reply, From, {error, not_active}}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
handle_event({call, From}, {extend_wrapup, IId, Ms}, _State, Data) ->
    case Data#sess.work of
        #{IId := W = #work{phase = wrapup, wrapup_until = Until0}} when
            is_integer(Until0)
        ->
            Now = cx_time:now_ms(),
            StartedAt = W#work.wrapup_started_at,
            Until = Until0 + Ms,
            case within_wrapup_cap(W#work.queue_key, StartedAt, Until) of
                true ->
                    case set_state(Data, IId, wrapup, wrapup, #{wrapup_until => Until}) of
                        ok ->
                            W1 = W#work{wrapup_until = Until},
                            Data1 = put_work(IId, W1, Data),
                            publish_i(Data1, W1, IId, wrapup_extended, #{
                                <<"until">> => Until
                            }),
                            {keep_state, Data1, [
                                {reply, From, ok},
                                {{timeout, {wrapup, IId}}, Until - Now, expire}
                            ]};
                        {error, conflict} ->
                            {keep_state_and_data, [{reply, From, {error, conflict}}]}
                    end;
                false ->
                    {keep_state_and_data, [{reply, From, {error, wrapup_cap_exceeded}}]}
            end;
        #{IId := _} ->
            {keep_state_and_data, [{reply, From, {error, not_in_wrapup}}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
handle_event({call, From}, {finalize_wrapup, IId}, _State, Data) ->
    case Data#sess.work of
        #{IId := #work{phase = wrapup, q_required = true, qualified = false}} ->
            {keep_state_and_data, [{reply, From, {error, qualification_required}}]};
        #{IId := W = #work{phase = wrapup}} ->
            case finalize(Data, IId, W, wrapup_cancelled) of
                {ok, Data1} ->
                    {keep_state, Data1, [
                        {reply, From, ok},
                        {{timeout, {wrapup, IId}}, cancel}
                    ]};
                {error, conflict} ->
                    {keep_state_and_data, [{reply, From, {error, conflict}}]}
            end;
        #{IId := _} ->
            {keep_state_and_data, [{reply, From, {error, not_in_wrapup}}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
handle_event({timeout, {wrapup, IId}}, expire, _State, Data) ->
    case Data#sess.work of
        #{IId := #work{phase = wrapup, q_required = true, qualified = false}} ->
            %% the hard block: an unqualified interaction on a
            %% qualification-required queue stays in ACW past its timer,
            %% holding the capacity slot — entering codes releases it
            %% (see the qualify handler)
            keep_state_and_data;
        #{IId := W = #work{phase = wrapup}} ->
            case finalize(Data, IId, W, wrapup_ended) of
                {ok, Data1} -> {keep_state, Data1};
                {error, conflict} -> keep_state_and_data
            end;
        _ ->
            keep_state_and_data
    end;
%% ---- qualification ----

handle_event({call, From}, {qualify, IId, Ids}, _State, Data) ->
    case Data#sess.work of
        #{IId := W = #work{phase = Phase}} ->
            case set_state(Data, IId, Phase, Phase, #{qualification_ids => Ids}) of
                ok ->
                    W1 = W#work{qualified = Ids =/= []},
                    Data1 = put_work(IId, W1, Data),
                    publish_i(Data1, W1, IId, interaction_qualified, #{
                        <<"qualification_ids">> => Ids
                    }),
                    maybe_release_overdue(Data1, IId, W1, From);
                {error, conflict} ->
                    {keep_state_and_data, [{reply, From, {error, conflict}}]}
            end;
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
%% ---- introspection and shutdown ----

handle_event({call, From}, get_state, _State, Data) ->
    ByPhase = fun(Phase) ->
        [IId || IId := #work{phase = P} <- Data#sess.work, P =:= Phase]
    end,
    Offers = [
        offer_to_map(OfferId, O)
     || OfferId := O <- Data#sess.pending
    ],
    Info = #{
        <<"agent_id">> => Data#sess.agent_id,
        <<"ready">> => maps:map(
            fun(_, V) -> ready_to_json(V) end,
            Data#sess.ready
        ),
        <<"active">> => ByPhase(active),
        <<"held">> => ByPhase(held),
        <<"wrapup">> => ByPhase(wrapup),
        <<"pending_offers">> => Offers
    },
    {keep_state_and_data, [{reply, From, {ok, Info}}]};
handle_event({call, From}, list_work, _State, Data) ->
    {keep_state_and_data, [{reply, From, {ok, maps:keys(Data#sess.work)}}]};
handle_event({call, From}, stop_session, _State, Data) ->
    Engaged = [
        IId
     || IId := #work{phase = P} <- Data#sess.work,
        P =:= active orelse P =:= held
    ],
    Unqualified = [
        IId
     || IId := #work{phase = wrapup, q_required = true, qualified = false} <-
            Data#sess.work
    ],
    case {Engaged, Unqualified} of
        {[_ | _], _} ->
            {keep_state_and_data, [{reply, From, {error, has_active_interactions}}]};
        {[], [_ | _]} ->
            %% sign-out must not be a loophole around mandatory codes
            {keep_state_and_data, [{reply, From, {error, qualification_required}}]};
        {[], []} ->
            %% ACW does not block sign-out: finalize any wrap-ups, hand
            %% pending offers back (the queue requeues at original
            %% position and we're gone before its cast comes back)
            Data1 = maps:fold(
                fun(IId, W, Acc) ->
                    case finalize(Acc, IId, W, wrapup_cancelled) of
                        {ok, Acc1} -> Acc1;
                        {error, conflict} -> remove_work(IId, Acc)
                    end
                end,
                Data,
                Data#sess.work
            ),
            maps:foreach(
                fun(OfferId, #offer{queue_pid = QueuePid}) ->
                    gen_statem:cast(QueuePid, {reject_cast, OfferId})
                end,
                Data1#sess.pending
            ),
            publish(Data1, undefined, undefined, session_ended, #{
                <<"agent_id">> => Data1#sess.agent_id
            }),
            {stop_and_reply, normal, [{reply, From, ok}]}
    end;
handle_event({call, From}, force_stop_session, _State, Data) ->
    %% The escape hatch (self ?force=true or supervisor kick): engaged
    %% work goes back to its queue at original position, ACW finalizes
    %% regardless of qualification, pending offers are handed back.
    Data1 = maps:fold(
        fun(IId, W = #work{phase = Phase}, Acc) ->
            case Phase of
                wrapup ->
                    case finalize(Acc, IId, W, wrapup_cancelled) of
                        {ok, Acc1} -> Acc1;
                        {error, conflict} -> remove_work(IId, Acc)
                    end;
                _ ->
                    {_, QueueId} = W#work.queue_key,
                    case cx_queue_proc:ensure_started(Acc#sess.tenant, QueueId) of
                        {ok, QPid} ->
                            gen_statem:cast(QPid, {requeue_active, IId});
                        {error, _} ->
                            ok
                    end,
                    remove_work(IId, Acc)
            end
        end,
        Data,
        Data#sess.work
    ),
    maps:foreach(
        fun(OfferId, #offer{queue_pid = QueuePid}) ->
            gen_statem:cast(QueuePid, {reject_cast, OfferId})
        end,
        Data1#sess.pending
    ),
    publish(Data1, undefined, undefined, session_ended, #{
        <<"agent_id">> => Data1#sess.agent_id
    }),
    {stop_and_reply, normal, [{reply, From, ok}]};
handle_event(info, {'DOWN', MonRef, process, _Pid, _Reason}, _State, Data) ->
    %% a queue died while we held offers from it — drop those reservations
    Pending = maps:filter(
        fun(_, #offer{mon_ref = Ref}) -> Ref =/= MonRef end,
        Data#sess.pending
    ),
    case maps:size(Pending) =:= maps:size(Data#sess.pending) of
        true ->
            keep_state_and_data;
        false ->
            Data1 = touch_idle(Data#sess{pending = Pending}),
            write_snapshot(Data1),
            {keep_state, Data1}
    end;
handle_event(_Type, _Event, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, Data) ->
    try
        mnesia:dirty_delete(
            cx_agent_snapshot,
            {Data#sess.tenant, Data#sess.agent_id}
        )
    catch
        _:_ -> ok
    end,
    ok.

%% ---- helpers ----

mix_of(#sess{work = Work, pending = Pending}) ->
    Add = fun(Media, Acc) -> maps:update_with(Media, fun(N) -> N + 1 end, 1, Acc) end,
    Mix0 = maps:fold(fun(_, #work{media = Media}, Acc) -> Add(Media, Acc) end, #{}, Work),
    maps:fold(fun(_, #offer{media = Media}, Acc) -> Add(Media, Acc) end, Mix0, Pending).

touch_idle(Data = #sess{work = Work, pending = Pending}) ->
    case maps:size(Work) + maps:size(Pending) of
        0 -> Data#sess{idle_since = cx_time:now_ms()};
        _ -> Data
    end.

put_work(IId, W, Data) ->
    Data1 = Data#sess{work = maps:put(IId, W, Data#sess.work)},
    write_snapshot(Data1),
    Data1.

remove_work(IId, Data) ->
    Data1 = touch_idle(Data#sess{work = maps:remove(IId, Data#sess.work)}),
    write_snapshot(Data1),
    Data1.

write_snapshot(Data = #sess{tenant = Tenant, agent_id = AgentId}) ->
    Rec = #cx_agent_snapshot{
        key = {Tenant, AgentId},
        pid = self(),
        ready = Data#sess.ready,
        mix = mix_of(Data),
        skills = Data#sess.skills,
        profile = Data#sess.profile,
        idle_since = Data#sess.idle_since
    },
    ok = mnesia:dirty_write(Rec).

%% Finalize an interaction: it leaves the mix and the agent's slot opens.
%% AcwEvent narrates how the ACW envelope ended (wrapup_ended on timer
%% expiry, wrapup_cancelled on early finalize, undefined when the queue
%% has no wrap-up at all); interaction_completed marks the terminal
%% transition in every case.
finalize(Data, IId, W = #work{phase = Phase}, AcwEvent) ->
    case
        set_state(Data, IId, Phase, completed, #{
            completed_at => cx_time:now_ms()
        })
    of
        ok ->
            Data1 = remove_work(IId, Data),
            AcwEvent =/= undefined andalso
                publish_i(Data1, W, IId, AcwEvent, #{}),
            publish_i(Data1, W, IId, interaction_completed, #{}),
            cx_router_signal:agent_available(Data1#sess.tenant),
            {ok, Data1};
        {error, conflict} ->
            {error, conflict}
    end.

%% The single guarded Mnesia transition for owned interactions: the row
%% must be in the state matching our phase or nothing is written — a
%% racing cancel/delete must not be overwritten, and no event may narrate
%% a transition that never happened.
set_state(#sess{tenant = Tenant, agent_id = AgentId}, IId, FromState, ToState, Extra) ->
    cx_store:tx(fun() ->
        case mnesia:read(cx_interaction, {Tenant, IId}) of
            [Rec = #cx_interaction{state = FromState}] ->
                mnesia:write(Rec#cx_interaction{
                    state = ToState,
                    agent_id = AgentId,
                    wrapup_started_at = maps:get(
                        wrapup_started_at, Extra, Rec#cx_interaction.wrapup_started_at
                    ),
                    wrapup_until = maps:get(
                        wrapup_until, Extra, Rec#cx_interaction.wrapup_until
                    ),
                    qualification_ids = maps:get(
                        qualification_ids, Extra, Rec#cx_interaction.qualification_ids
                    ),
                    completed_at = maps:get(
                        completed_at, Extra, Rec#cx_interaction.completed_at
                    )
                });
            _ ->
                {error, conflict}
        end
    end).

wrapup_policy({Tenant, QueueId}) ->
    case cx_queue:fetch(Tenant, QueueId) of
        {ok, #cx_queue{wrapup_duration_ms = Ms, qualification_required = QR}} ->
            {Ms, QR};
        {error, not_found} ->
            {0, false}
    end.

%% An overdue ACW (timer already fired against the qualification block)
%% releases the moment codes arrive — entering them IS the release.
maybe_release_overdue(
    Data,
    IId,
    W = #work{phase = wrapup, qualified = true, wrapup_until = Until},
    From
) when is_integer(Until) ->
    case Until =< cx_time:now_ms() of
        true ->
            case finalize(Data, IId, W, wrapup_ended) of
                {ok, Data1} -> {keep_state, Data1, [{reply, From, ok}]};
                {error, conflict} -> {keep_state, Data, [{reply, From, ok}]}
            end;
        false ->
            {keep_state, Data, [{reply, From, ok}]}
    end;
maybe_release_overdue(Data, _IId, _W, From) ->
    {keep_state, Data, [{reply, From, ok}]}.

within_wrapup_cap({Tenant, QueueId}, StartedAt, Until) ->
    case cx_queue:fetch(Tenant, QueueId) of
        {ok, #cx_queue{wrapup_max_ms = infinity}} ->
            true;
        {ok, #cx_queue{wrapup_max_ms = Max}} ->
            is_integer(StartedAt) andalso Until - StartedAt =< Max;
        {error, not_found} ->
            true
    end.

offer_to_map(OfferId, #offer{
    interaction_id = IId,
    media = Media,
    queue_key = {_, QueueId},
    expires_at = ExpiresAt
}) ->
    #{
        <<"offer_id">> => OfferId,
        <<"interaction_id">> => IId,
        <<"media_type">> => Media,
        <<"queue_id">> => QueueId,
        <<"expires_at">> => cx_json:undef_to_null(ExpiresAt)
    }.

null_to_undef(null) -> undefined;
null_to_undef(V) -> V.

%% Structured on the way out, symmetric with the PUT body — clients
%% never parse composite strings.
ready_to_json(ready) ->
    #{<<"state">> => <<"ready">>, <<"reason_id">> => null};
ready_to_json({not_ready, Reason}) ->
    #{
        <<"state">> => <<"not_ready">>,
        <<"reason_id">> => cx_json:undef_to_null(Reason)
    }.

publish_i(Data, #work{media = Media, queue_key = {_, QueueId}}, IId, Type, Extra) ->
    publish(
        Data,
        QueueId,
        Media,
        Type,
        Extra#{
            <<"interaction_id">> => IId,
            <<"agent_id">> => Data#sess.agent_id
        }
    ).

publish(#sess{tenant = Tenant}, QueueId, Media, Type, ExtraData) ->
    cx_event:publish(Tenant, QueueId, Media, Type, ExtraData).
