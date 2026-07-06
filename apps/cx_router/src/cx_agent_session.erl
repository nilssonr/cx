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
%% qualification_required snapshots the queue's qualification_required at ACW entry
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
    qualification_required = false :: boolean(),
    qualified = false :: boolean()
}).

%% One pending (ringing) offer as this session sees it. expires_at is
%% the queue-computed ring deadline (undefined = ring forever); the
%% queue's timer is authoritative — this copy only feeds read surfaces.
-record(pending_offer, {
    interaction_id :: binary(),
    media :: binary(),
    queue_key :: {binary(), binary()},
    queue_pid :: pid(),
    monitor_ref :: reference(),
    expires_at :: integer() | undefined
}).

-record(agent_session, {
    tenant :: binary(),
    agent_id :: binary(),
    profile :: #cx_routing_profile{},
    skills :: #{binary() => pos_integer()},
    ready = #{} :: #{binary() => ready | {not_ready, binary() | undefined}},
    %% InteractionId => #work{}
    work = #{} :: #{binary() => #work{}},
    %% OfferId => #pending_offer{}
    pending = #{} :: #{binary() => #pending_offer{}},
    %% [{OfferId, InteractionId}] most-recent-first, capped — serves
    %% retried accepts after the offer left `pending` (idempotency)
    recent_accepts = [] :: [{binary(), binary()}],
    idle_since :: integer()
}).

-define(RECENT_ACCEPTS_MAX, 50).

start_link(TenantId, AgentId, Skills, Profile) ->
    gen_statem:start_link(
        {via, cx_registry, {agent, TenantId, AgentId}},
        ?MODULE,
        [TenantId, AgentId, Skills, Profile],
        []
    ).

callback_mode() -> handle_event_function.

init([TenantId, AgentId, Skills, Profile]) ->
    Data = #agent_session{
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
    Data1 = Data#agent_session{ready = maps:put(Media, NewState, Data#agent_session.ready)},
    write_snapshot(Data1),
    publish(
        Data1,
        undefined,
        Media,
        agent_ready_changed,
        #{
            <<"agent_id">> => Data1#agent_session.agent_id,
            <<"media_type">> => Media,
            <<"ready">> => ready_to_json(NewState)
        }
    ),
    NewState =:= ready andalso cx_router_signal:agent_available(Data1#agent_session.tenant),
    {keep_state, Data1, [{reply, From, ok}]};
%% ---- offers ----

handle_event({call, From}, {offer, Offer}, _State, Data) ->
    #{
        offer_id := OfferId,
        interaction_id := InteractionId,
        media := Media,
        queue_key := QueueKey,
        queue_pid := QueuePid,
        expires_at := ExpiresAt
    } = Offer,
    Routable =
        maps:get(Media, Data#agent_session.ready, undefined) =:= ready andalso
            cx_routing:can_route(Data#agent_session.profile, mix_of(Data), Media),
    case Routable of
        true ->
            MonitorRef = erlang:monitor(process, QueuePid),
            Pending = maps:put(
                OfferId,
                #pending_offer{
                    interaction_id = InteractionId,
                    media = Media,
                    queue_key = QueueKey,
                    queue_pid = QueuePid,
                    monitor_ref = MonitorRef,
                    expires_at = null_to_undef(ExpiresAt)
                },
                Data#agent_session.pending
            ),
            Data1 = Data#agent_session{pending = Pending},
            write_snapshot(Data1),
            {keep_state, Data1, [{reply, From, ok}]};
        false ->
            {keep_state_and_data, [{reply, From, {error, not_routable}}]}
    end;
handle_event({call, From}, {pending_queue, OfferId}, _State, Data) ->
    case Data#agent_session.pending of
        #{OfferId := #pending_offer{queue_pid = QueuePid}} ->
            {keep_state_and_data, [{reply, From, {ok, QueuePid}}]};
        _ ->
            case lists:keyfind(OfferId, 1, Data#agent_session.recent_accepts) of
                {OfferId, InteractionId} ->
                    {keep_state_and_data, [{reply, From, {recently_accepted, InteractionId}}]};
                false ->
                    {keep_state_and_data, [{reply, From, {error, not_found}}]}
            end
    end;
handle_event({call, From}, list_offers, _State, Data) ->
    Offers = [
        offer_to_map(OfferId, O)
     || OfferId := O <- Data#agent_session.pending
    ],
    {keep_state_and_data, [{reply, From, {ok, Offers}}]};
handle_event({call, From}, {get_offer, OfferId}, _State, Data) ->
    case Data#agent_session.pending of
        #{OfferId := O} ->
            {keep_state_and_data, [{reply, From, {ok, offer_to_map(OfferId, O)}}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
handle_event(cast, {offer_accepted, OfferId}, _State, Data) ->
    case maps:take(OfferId, Data#agent_session.pending) of
        {
            #pending_offer{
                interaction_id = InteractionId,
                media = Media,
                queue_key = QueueKey,
                monitor_ref = MonitorRef
            },
            Pending
        } ->
            erlang:demonitor(MonitorRef, [flush]),
            Data1 = Data#agent_session{
                pending = Pending,
                work = maps:put(
                    InteractionId,
                    #work{media = Media, queue_key = QueueKey},
                    Data#agent_session.work
                ),
                recent_accepts = lists:sublist(
                    [{OfferId, InteractionId} | Data#agent_session.recent_accepts],
                    ?RECENT_ACCEPTS_MAX
                )
            },
            write_snapshot(Data1),
            {keep_state, Data1};
        error ->
            keep_state_and_data
    end;
handle_event(cast, {offer_withdrawn, OfferId}, _State, Data) ->
    case maps:take(OfferId, Data#agent_session.pending) of
        {#pending_offer{monitor_ref = MonitorRef}, Pending} ->
            erlang:demonitor(MonitorRef, [flush]),
            Data1 = touch_idle(Data#agent_session{pending = Pending}),
            write_snapshot(Data1),
            %% a reservation was released — capacity may have opened up
            cx_router_signal:agent_available(Data1#agent_session.tenant),
            {keep_state, Data1};
        error ->
            keep_state_and_data
    end;
%% ---- hold / resume ----

handle_event({call, From}, {hold, InteractionId}, _State, Data) ->
    case Data#agent_session.work of
        #{InteractionId := W = #work{phase = active}} ->
            case set_state(Data, InteractionId, active, held, #{}) of
                ok ->
                    Data1 = put_work(InteractionId, W#work{phase = held}, Data),
                    publish_i(Data1, W, InteractionId, interaction_held, #{}),
                    {keep_state, Data1, [{reply, From, ok}]};
                {error, conflict} ->
                    {keep_state_and_data, [{reply, From, {error, conflict}}]}
            end;
        #{InteractionId := _} ->
            {keep_state_and_data, [{reply, From, {error, not_active}}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
handle_event({call, From}, {resume, InteractionId}, _State, Data) ->
    case Data#agent_session.work of
        #{InteractionId := W = #work{phase = held}} ->
            case set_state(Data, InteractionId, held, active, #{}) of
                ok ->
                    Data1 = put_work(InteractionId, W#work{phase = active}, Data),
                    publish_i(Data1, W, InteractionId, interaction_resumed, #{}),
                    {keep_state, Data1, [{reply, From, ok}]};
                {error, conflict} ->
                    {keep_state_and_data, [{reply, From, {error, conflict}}]}
            end;
        #{InteractionId := _} ->
            {keep_state_and_data, [{reply, From, {error, not_held}}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
%% ---- completion and after-call work ----

handle_event({call, From}, {complete, InteractionId}, _State, Data) ->
    case Data#agent_session.work of
        #{InteractionId := W = #work{phase = Phase}} when Phase =:= active; Phase =:= held ->
            Now = cx_time:now_ms(),
            {WrapupMs, QRequired} = wrapup_policy(W#work.queue_key),
            %% qualification-required work enters ACW even with a zero
            %% window (Until = Now: the 0 timer fires straight into the
            %% hard block) — a shrunk wrap-up window must not disable
            %% the tenant's mandatory-codes policy
            case WrapupMs > 0 orelse QRequired of
                true ->
                    Until = Now + WrapupMs,
                    case
                        set_state(Data, InteractionId, Phase, wrapup, #{
                            wrapup_started_at => Now,
                            wrapup_until => Until
                        })
                    of
                        ok ->
                            W1 = W#work{
                                phase = wrapup,
                                wrapup_started_at = Now,
                                wrapup_until = Until,
                                qualification_required = QRequired
                            },
                            Data1 = put_work(InteractionId, W1, Data),
                            publish_i(Data1, W1, InteractionId, wrapup_started, #{
                                <<"until">> => Until
                            }),
                            {keep_state, Data1, [
                                {reply, From,
                                    {ok, #{
                                        <<"state">> => <<"wrapup">>,
                                        <<"wrapup_until">> => Until
                                    }}},
                                {{timeout, {wrapup, InteractionId}}, max(0, Until - Now), expire}
                            ]};
                        {error, conflict} ->
                            {keep_state_and_data, [{reply, From, {error, conflict}}]}
                    end;
                false ->
                    case finalize(Data, InteractionId, W, undefined) of
                        {ok, Data1} ->
                            {keep_state, Data1, [{reply, From, ok}]};
                        {error, conflict} ->
                            {keep_state_and_data, [{reply, From, {error, conflict}}]}
                    end
            end;
        %% a retried complete (lost response) finds the work already in
        %% ACW — idempotent success with the current wrap-up payload
        #{InteractionId := #work{phase = wrapup, wrapup_until = Until0}} when
            is_integer(Until0)
        ->
            {keep_state_and_data, [
                {reply, From,
                    {ok, #{
                        <<"state">> => <<"wrapup">>,
                        <<"wrapup_until">> => Until0
                    }}}
            ]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
handle_event({call, From}, {extend_wrapup, InteractionId, Ms}, _State, Data) ->
    case Data#agent_session.work of
        #{InteractionId := W = #work{phase = wrapup, wrapup_until = Until0}} when
            is_integer(Until0)
        ->
            Now = cx_time:now_ms(),
            StartedAt = W#work.wrapup_started_at,
            Until = Until0 + Ms,
            case within_wrapup_cap(W#work.queue_key, StartedAt, Until) of
                true ->
                    case set_state(Data, InteractionId, wrapup, wrapup, #{wrapup_until => Until}) of
                        ok ->
                            W1 = W#work{wrapup_until = Until},
                            Data1 = put_work(InteractionId, W1, Data),
                            publish_i(Data1, W1, InteractionId, wrapup_extended, #{
                                <<"until">> => Until
                            }),
                            %% Until can still be in the past: the qualification
                            %% hard block keeps overdue ACW alive without
                            %% re-arming, and a small extend may not catch up —
                            %% a clamped 0 fires straight into the expiry
                            %% clause, which holds or finalizes correctly.
                            {keep_state, Data1, [
                                {reply, From, ok},
                                {{timeout, {wrapup, InteractionId}}, max(0, Until - Now), expire}
                            ]};
                        {error, conflict} ->
                            {keep_state_and_data, [{reply, From, {error, conflict}}]}
                    end;
                false ->
                    {keep_state_and_data, [{reply, From, {error, wrapup_cap_exceeded}}]}
            end;
        #{InteractionId := _} ->
            {keep_state_and_data, [{reply, From, {error, not_in_wrapup}}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
handle_event({call, From}, {finalize_wrapup, InteractionId}, _State, Data) ->
    case Data#agent_session.work of
        #{InteractionId := #work{phase = wrapup, qualification_required = true, qualified = false}} ->
            {keep_state_and_data, [{reply, From, {error, qualification_required}}]};
        #{InteractionId := W = #work{phase = wrapup}} ->
            case finalize(Data, InteractionId, W, wrapup_cancelled) of
                {ok, Data1} ->
                    {keep_state, Data1, [
                        {reply, From, ok},
                        {{timeout, {wrapup, InteractionId}}, cancel}
                    ]};
                {error, conflict} ->
                    {keep_state_and_data, [{reply, From, {error, conflict}}]}
            end;
        #{InteractionId := _} ->
            {keep_state_and_data, [{reply, From, {error, not_in_wrapup}}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
handle_event({timeout, {wrapup, InteractionId}}, expire, _State, Data) ->
    case Data#agent_session.work of
        #{InteractionId := #work{phase = wrapup, qualification_required = true, qualified = false}} ->
            %% the hard block: an unqualified interaction on a
            %% qualification-required queue stays in ACW past its timer,
            %% holding the capacity slot — entering codes releases it
            %% (see the qualify handler)
            keep_state_and_data;
        #{InteractionId := W = #work{phase = wrapup}} ->
            case finalize(Data, InteractionId, W, wrapup_ended) of
                {ok, Data1} -> {keep_state, Data1};
                {error, conflict} -> keep_state_and_data
            end;
        _ ->
            keep_state_and_data
    end;
%% ---- qualification ----

handle_event({call, From}, {qualify, InteractionId, Ids}, _State, Data) ->
    case Data#agent_session.work of
        #{InteractionId := W = #work{phase = Phase}} ->
            case set_state(Data, InteractionId, Phase, Phase, #{qualification_ids => Ids}) of
                ok ->
                    W1 = W#work{qualified = Ids =/= []},
                    Data1 = put_work(InteractionId, W1, Data),
                    publish_i(Data1, W1, InteractionId, interaction_qualified, #{
                        <<"qualification_ids">> => Ids
                    }),
                    maybe_release_overdue(Data1, InteractionId, W1, From);
                {error, conflict} ->
                    {keep_state_and_data, [{reply, From, {error, conflict}}]}
            end;
        _ ->
            {keep_state_and_data, [{reply, From, {error, not_found}}]}
    end;
%% ---- introspection and shutdown ----

handle_event({call, From}, get_state, _State, Data) ->
    ByPhase = fun(Phase) ->
        [InteractionId || InteractionId := #work{phase = P} <- Data#agent_session.work, P =:= Phase]
    end,
    Offers = [
        offer_to_map(OfferId, O)
     || OfferId := O <- Data#agent_session.pending
    ],
    Info = #{
        <<"agent_id">> => Data#agent_session.agent_id,
        <<"ready">> => maps:map(
            fun(_, V) -> ready_to_json(V) end,
            Data#agent_session.ready
        ),
        <<"active">> => ByPhase(active),
        <<"held">> => ByPhase(held),
        <<"wrapup">> => ByPhase(wrapup),
        <<"pending_offers">> => Offers
    },
    {keep_state_and_data, [{reply, From, {ok, Info}}]};
handle_event({call, From}, list_work, _State, Data) ->
    {keep_state_and_data, [{reply, From, {ok, maps:keys(Data#agent_session.work)}}]};
handle_event({call, From}, stop_session, _State, Data) ->
    Engaged = [
        InteractionId
     || InteractionId := #work{phase = P} <- Data#agent_session.work,
        P =:= active orelse P =:= held
    ],
    Unqualified = [
        InteractionId
     || InteractionId := #work{phase = wrapup, qualification_required = true, qualified = false} <-
            Data#agent_session.work
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
                fun(InteractionId, W, Acc) ->
                    case finalize(Acc, InteractionId, W, wrapup_cancelled) of
                        {ok, Acc1} -> Acc1;
                        {error, conflict} -> remove_work(InteractionId, Acc)
                    end
                end,
                Data,
                Data#agent_session.work
            ),
            maps:foreach(
                fun(OfferId, #pending_offer{queue_pid = QueuePid}) ->
                    gen_statem:cast(QueuePid, {reject_cast, OfferId})
                end,
                Data1#agent_session.pending
            ),
            publish(Data1, undefined, undefined, session_ended, #{
                <<"agent_id">> => Data1#agent_session.agent_id
            }),
            {stop_and_reply, normal, [{reply, From, ok}]}
    end;
handle_event({call, From}, force_stop_session, _State, Data) ->
    %% The escape hatch (self ?force=true or supervisor kick): engaged
    %% work goes back to its queue at original position, ACW finalizes
    %% regardless of qualification, pending offers are handed back.
    Data1 = maps:fold(
        fun(InteractionId, W = #work{phase = Phase}, Acc) ->
            case Phase of
                wrapup ->
                    case finalize(Acc, InteractionId, W, wrapup_cancelled) of
                        {ok, Acc1} -> Acc1;
                        {error, conflict} -> remove_work(InteractionId, Acc)
                    end;
                _ ->
                    {_, QueueId} = W#work.queue_key,
                    case cx_queue_process:ensure_started(Acc#agent_session.tenant, QueueId) of
                        {ok, QueuePid} ->
                            gen_statem:cast(QueuePid, {requeue_active, InteractionId});
                        {error, _} ->
                            ok
                    end,
                    remove_work(InteractionId, Acc)
            end
        end,
        Data,
        Data#agent_session.work
    ),
    maps:foreach(
        fun(OfferId, #pending_offer{queue_pid = QueuePid}) ->
            gen_statem:cast(QueuePid, {reject_cast, OfferId})
        end,
        Data1#agent_session.pending
    ),
    publish(Data1, undefined, undefined, session_ended, #{
        <<"agent_id">> => Data1#agent_session.agent_id
    }),
    {stop_and_reply, normal, [{reply, From, ok}]};
handle_event(info, {'DOWN', MonitorRef, process, _Pid, _Reason}, _State, Data) ->
    %% a queue died while we held offers from it — drop those reservations
    Pending = maps:filter(
        fun(_, #pending_offer{monitor_ref = Ref}) -> Ref =/= MonitorRef end,
        Data#agent_session.pending
    ),
    case maps:size(Pending) =:= maps:size(Data#agent_session.pending) of
        true ->
            keep_state_and_data;
        false ->
            Data1 = touch_idle(Data#agent_session{pending = Pending}),
            write_snapshot(Data1),
            {keep_state, Data1}
    end;
handle_event(_Type, _Event, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, Data) ->
    try
        mnesia:dirty_delete(
            cx_agent_snapshot,
            {Data#agent_session.tenant, Data#agent_session.agent_id}
        )
    catch
        _:_ -> ok
    end,
    ok.

%% ---- helpers ----

mix_of(#agent_session{work = Work, pending = Pending}) ->
    Add = fun(Media, Acc) -> maps:update_with(Media, fun(N) -> N + 1 end, 1, Acc) end,
    Mix0 = maps:fold(fun(_, #work{media = Media}, Acc) -> Add(Media, Acc) end, #{}, Work),
    maps:fold(fun(_, #pending_offer{media = Media}, Acc) -> Add(Media, Acc) end, Mix0, Pending).

touch_idle(Data = #agent_session{work = Work, pending = Pending}) ->
    case maps:size(Work) + maps:size(Pending) of
        0 -> Data#agent_session{idle_since = cx_time:now_ms()};
        _ -> Data
    end.

put_work(InteractionId, W, Data) ->
    Data1 = Data#agent_session{work = maps:put(InteractionId, W, Data#agent_session.work)},
    write_snapshot(Data1),
    Data1.

remove_work(InteractionId, Data) ->
    Data1 = touch_idle(Data#agent_session{
        work = maps:remove(InteractionId, Data#agent_session.work)
    }),
    write_snapshot(Data1),
    Data1.

write_snapshot(Data = #agent_session{tenant = Tenant, agent_id = AgentId}) ->
    Rec = #cx_agent_snapshot{
        key = {Tenant, AgentId},
        pid = self(),
        ready = Data#agent_session.ready,
        mix = mix_of(Data),
        skills = Data#agent_session.skills,
        profile = Data#agent_session.profile,
        idle_since = Data#agent_session.idle_since
    },
    ok = mnesia:dirty_write(Rec).

%% Finalize an interaction: it leaves the mix and the agent's slot opens.
%% AcwEvent narrates how the ACW envelope ended (wrapup_ended on timer
%% expiry, wrapup_cancelled on early finalize, undefined when the queue
%% has no wrap-up at all); interaction_completed marks the terminal
%% transition in every case.
finalize(Data, InteractionId, W = #work{phase = Phase}, AcwEvent) ->
    case
        set_state(Data, InteractionId, Phase, completed, #{
            completed_at => cx_time:now_ms()
        })
    of
        ok ->
            Data1 = remove_work(InteractionId, Data),
            AcwEvent =/= undefined andalso
                publish_i(Data1, W, InteractionId, AcwEvent, #{}),
            publish_i(Data1, W, InteractionId, interaction_completed, #{}),
            cx_router_signal:agent_available(Data1#agent_session.tenant),
            {ok, Data1};
        {error, conflict} ->
            {error, conflict}
    end.

%% The single guarded Mnesia transition for owned interactions: the row
%% must be in the state matching our phase or nothing is written — a
%% racing cancel/delete must not be overwritten, and no event may narrate
%% a transition that never happened.
set_state(
    #agent_session{tenant = Tenant, agent_id = AgentId}, InteractionId, FromState, ToState, Extra
) ->
    cx_store:tx(fun() ->
        case mnesia:read(cx_interaction, {Tenant, InteractionId}) of
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
    InteractionId,
    W = #work{phase = wrapup, qualified = true, wrapup_until = Until},
    From
) when is_integer(Until) ->
    case Until =< cx_time:now_ms() of
        true ->
            case finalize(Data, InteractionId, W, wrapup_ended) of
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

offer_to_map(OfferId, #pending_offer{
    interaction_id = InteractionId,
    media = Media,
    queue_key = {_, QueueId},
    expires_at = ExpiresAt
}) ->
    #{
        <<"offer_id">> => OfferId,
        <<"interaction_id">> => InteractionId,
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

publish_i(Data, #work{media = Media, queue_key = {_, QueueId}}, InteractionId, Type, Extra) ->
    publish(
        Data,
        QueueId,
        Media,
        Type,
        Extra#{
            <<"interaction_id">> => InteractionId,
            <<"agent_id">> => Data#agent_session.agent_id
        }
    ).

publish(#agent_session{tenant = Tenant}, QueueId, Media, Type, ExtraData) ->
    cx_event:publish(Tenant, QueueId, Media, Type, ExtraData).
