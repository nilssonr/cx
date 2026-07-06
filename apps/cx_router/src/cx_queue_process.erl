-module(cx_queue_process).

%% One process per queue. Owns the waiting order (gb_trees keyed by
%% {enqueued_at, sequence} — assigned once, stored in Mnesia, so a rejected,
%% timed-out or recovered interaction never loses its place) and the live
%% offers. This process is the single serialization point for
%% accept-vs-timeout races.
%%
%% Widening timers are pure wake-ups: effective requirements are always
%% computed from wait time, never stored, so a stale timer is a no-op.

-behaviour(gen_statem).

-include_lib("cx_core/include/cx_core.hrl").

-export([start_link/2, ensure_started/2]).
-export([callback_mode/0, init/1, handle_event/4]).

-define(OFFER_CALL_TIMEOUT_MS, 5000).

-record(waiting_item, {
    interaction_id :: binary(),
    media :: binary(),
    %% snapshot at enqueue
    skill_requirements :: [#skill_requirement{}],
    enqueued_at :: integer(),
    sequence :: integer(),
    %% rejected/timed out; skipped
    offered_to = [] :: [binary()]
}).

-record(placed_offer, {
    offer_id :: binary(),
    agent_id :: binary(),
    agent_pid :: pid(),
    monitor_ref :: reference(),
    item :: #waiting_item{}
}).

-record(queue_state, {
    tenant :: binary(),
    queue_id :: binary(),
    config :: #cx_queue{},
    waiting = gb_trees:empty() :: gb_trees:tree(),
    by_id = #{} :: #{binary() => {integer(), integer()}},
    offers = #{} :: #{binary() => #placed_offer{}},
    sequence = 0 :: integer()
}).

start_link(TenantId, QueueId) ->
    gen_statem:start_link(
        {via, cx_registry, {queue, TenantId, QueueId}},
        ?MODULE,
        [TenantId, QueueId],
        []
    ).

-spec ensure_started(binary(), binary()) -> {ok, pid()} | {error, term()}.
ensure_started(TenantId, QueueId) ->
    case cx_registry:whereis_name({queue, TenantId, QueueId}) of
        undefined ->
            case cx_queue_sup:start_queue(TenantId, QueueId) of
                {ok, Pid} -> {ok, Pid};
                {error, {already_started, Pid}} -> {ok, Pid};
                {error, Reason} -> {error, Reason}
            end;
        Pid ->
            {ok, Pid}
    end.

callback_mode() -> handle_event_function.

init([TenantId, QueueId]) ->
    case cx_queue:fetch(TenantId, QueueId) of
        {ok, Config} ->
            ok = cx_router_signal:join(TenantId),
            {Data, Actions} = recover(#queue_state{
                tenant = TenantId,
                queue_id = QueueId,
                config = Config
            }),
            {ok, serving, Data, Actions ++ [{next_event, internal, route}]};
        {error, not_found} ->
            {stop, {queue_not_found, TenantId, QueueId}}
    end.

%% Rebuild waiting state from Mnesia: queued and offered interactions are
%% re-enqueued under their preserved {enqueued_at, sequence} keys (an offer
%% that was live when we died simply degrades to "requeued at original
%% position").
recover(Data = #queue_state{tenant = TenantId, queue_id = QueueId}) ->
    Recs = cx_store:tx(fun() ->
        Found = mnesia:index_read(
            cx_interaction,
            {TenantId, QueueId},
            #cx_interaction.queue_key
        ),
        lists:filtermap(
            fun
                (Rec = #cx_interaction{state = queued}) ->
                    {true, Rec};
                (Rec = #cx_interaction{state = offered}) ->
                    Rec1 = Rec#cx_interaction{
                        state = queued,
                        agent_id = undefined
                    },
                    ok = mnesia:write(Rec1),
                    {true, Rec1};
                (_) ->
                    false
            end,
            Found
        )
    end),
    Now = cx_time:now_ms(),
    lists:foldl(
        fun(Rec, {Acc, Actions}) ->
            Item = #waiting_item{
                interaction_id = element(2, Rec#cx_interaction.key),
                media = Rec#cx_interaction.media_type,
                skill_requirements = (Acc#queue_state.config)#cx_queue.skill_requirements,
                enqueued_at = Rec#cx_interaction.enqueued_at,
                sequence = Rec#cx_interaction.sequence
            },
            %% prepend: uniquely-named timeouts, order-free (see try_route)
            {insert_item(Item, Acc), widen_actions(Item, Now) ++ Actions}
        end,
        {Data#queue_state{sequence = next_sequence(Recs)}, []},
        Recs
    ).

next_sequence([]) -> 0;
next_sequence(Recs) -> lists:max([R#cx_interaction.sequence || R <- Recs]) + 1.

%% ---- events ----

handle_event({call, From}, {enqueue, InteractionId, Media, Props, CreatedAt}, _S, Data) ->
    Config = refresh_config(Data),
    Now = cx_time:now_ms(),
    Sequence = Data#queue_state.sequence,
    Rec = #cx_interaction{
        key = {Data#queue_state.tenant, InteractionId},
        queue_key = {Data#queue_state.tenant, Data#queue_state.queue_id},
        media_type = Media,
        properties = Props,
        state = queued,
        created_at = CreatedAt,
        enqueued_at = Now,
        sequence = Sequence
    },
    ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
    Item = #waiting_item{
        interaction_id = InteractionId,
        media = Media,
        skill_requirements = Config#cx_queue.skill_requirements,
        enqueued_at = Now,
        sequence = Sequence
    },
    Data1 = insert_item(Item, Data#queue_state{sequence = Sequence + 1, config = Config}),
    publish(Data1, Media, interaction_queued, #{<<"interaction_id">> => InteractionId}),
    {keep_state, Data1,
        [{reply, From, {ok, InteractionId}} | widen_actions(Item, Now)] ++
            [{next_event, internal, route}]};
handle_event({call, From}, {cancel, InteractionId}, _S, Data) ->
    case maps:take(InteractionId, Data#queue_state.by_id) of
        {Key, ById} ->
            {Item, Waiting} = take_item(Key, Data#queue_state.waiting),
            ok = cx_store:tx(fun() ->
                case mnesia:read(cx_interaction, {Data#queue_state.tenant, InteractionId}) of
                    [Rec = #cx_interaction{state = queued}] ->
                        mnesia:write(Rec#cx_interaction{state = cancelled});
                    _ ->
                        ok
                end
            end),
            Data1 = Data#queue_state{by_id = ById, waiting = Waiting},
            publish(
                Data1,
                Item#waiting_item.media,
                interaction_cancelled,
                #{<<"interaction_id">> => InteractionId}
            ),
            {keep_state, Data1, [{reply, From, ok}]};
        error ->
            %% offered or active interactions are not cancellable in M1
            {keep_state_and_data, [{reply, From, {error, not_cancellable}}]}
    end;
handle_event({call, From}, {accepted, OfferId}, _S, Data) ->
    case take_offer(OfferId, Data) of
        {Offer = #placed_offer{item = Item}, Data0} ->
            InteractionId = Item#waiting_item.interaction_id,
            ok = cx_store:tx(fun() ->
                [Rec] = mnesia:read(cx_interaction, {Data#queue_state.tenant, InteractionId}),
                mnesia:write(Rec#cx_interaction{
                    state = active,
                    agent_id = Offer#placed_offer.agent_id,
                    accepted_at = cx_time:now_ms()
                })
            end),
            gen_statem:cast(Offer#placed_offer.agent_pid, {offer_accepted, OfferId}),
            publish(
                Data0,
                Item#waiting_item.media,
                offer_accepted,
                #{
                    <<"interaction_id">> => InteractionId,
                    <<"offer_id">> => OfferId,
                    <<"agent_id">> => Offer#placed_offer.agent_id
                }
            ),
            %% wake routing: each pass offers an agent at most once, so
            %% a multi-capacity agent gets the next waiting item from a
            %% fresh pass
            {keep_state, Data0, [
                {reply, From, {ok, InteractionId}},
                {{timeout, {offer, OfferId}}, cancel},
                {next_event, internal, route}
            ]};
        error ->
            {keep_state_and_data, [{reply, From, {error, expired}}]}
    end;
handle_event({call, From}, {rejected, OfferId}, _S, Data) ->
    case take_offer(OfferId, Data) of
        {Offer, Data0} ->
            gen_statem:cast(Offer#placed_offer.agent_pid, {offer_withdrawn, OfferId}),
            Data1 = requeue(Offer, _Penalize = true, offer_rejected, Data0),
            {keep_state, Data1, [
                {reply, From, ok},
                {{timeout, {offer, OfferId}}, cancel},
                {next_event, internal, route}
            ]};
        error ->
            {keep_state_and_data, [{reply, From, {error, expired}}]}
    end;
%% force sign-out hands an ENGAGED (active/held) interaction back: it
%% re-enters the waiting order under its preserved {enqueued_at, sequence},
%% so it never loses its place. The state guard makes a duplicate cast
%% a no-op (first one flips the row to queued).
handle_event(cast, {requeue_active, InteractionId}, _S, Data) ->
    Config = refresh_config(Data),
    Requeued = cx_store:tx(fun() ->
        case mnesia:read(cx_interaction, {Data#queue_state.tenant, InteractionId}) of
            [Rec = #cx_interaction{state = S}] when S =:= active; S =:= held ->
                Rec1 = Rec#cx_interaction{
                    state = queued,
                    agent_id = undefined,
                    accepted_at = undefined
                },
                ok = mnesia:write(Rec1),
                {requeue, Rec1, Rec#cx_interaction.agent_id};
            _ ->
                skip
        end
    end),
    case Requeued of
        {requeue, Rec, PrevAgent} ->
            Item = #waiting_item{
                interaction_id = InteractionId,
                media = Rec#cx_interaction.media_type,
                skill_requirements = Config#cx_queue.skill_requirements,
                enqueued_at = Rec#cx_interaction.enqueued_at,
                sequence = Rec#cx_interaction.sequence
            },
            Data1 = insert_item(Item, Data#queue_state{config = Config}),
            publish(
                Data1,
                Item#waiting_item.media,
                interaction_requeued,
                #{
                    <<"interaction_id">> => InteractionId,
                    <<"agent_id">> => PrevAgent
                }
            ),
            {keep_state, Data1,
                widen_actions(Item, cx_time:now_ms()) ++
                    [{next_event, internal, route}]};
        skip ->
            keep_state_and_data
    end;
%% a stopping agent session hands its pending offers back asynchronously
handle_event(cast, {reject_cast, OfferId}, _S, Data) ->
    case take_offer(OfferId, Data) of
        {Offer, Data0} ->
            Data1 = requeue(Offer, true, offer_rejected, Data0),
            {keep_state, Data1, [
                {{timeout, {offer, OfferId}}, cancel},
                {next_event, internal, route}
            ]};
        error ->
            keep_state_and_data
    end;
handle_event({timeout, {offer, OfferId}}, _Content, _S, Data) ->
    case take_offer(OfferId, Data) of
        {Offer, Data0} ->
            gen_statem:cast(Offer#placed_offer.agent_pid, {offer_withdrawn, OfferId}),
            Data1 = requeue(Offer, true, offer_timeout, Data0),
            {keep_state, Data1, [{next_event, internal, route}]};
        error ->
            keep_state_and_data
    end;
handle_event(info, {'DOWN', MonitorRef, process, _Pid, _Reason}, _S, Data) ->
    %% agent session died mid-offer: requeue at original position,
    %% without penalizing the agent (they never saw it resolve)
    case
        [
            O
         || O = #placed_offer{monitor_ref = R} <- maps:values(Data#queue_state.offers),
            R =:= MonitorRef
        ]
    of
        [Offer] ->
            Offers = maps:remove(Offer#placed_offer.offer_id, Data#queue_state.offers),
            Data1 = requeue(
                Offer,
                false,
                interaction_requeued,
                Data#queue_state{offers = Offers}
            ),
            {keep_state, Data1, [
                {{timeout, {offer, Offer#placed_offer.offer_id}}, cancel},
                {next_event, internal, route}
            ]};
        [] ->
            keep_state_and_data
    end;
handle_event({timeout, {widen, _IId, _AfterMs}}, _Content, _S, _Data) ->
    %% pure wake-up; requirements are recomputed from wait time
    {keep_state_and_data, [{next_event, internal, route}]};
handle_event(info, cx_agent_available, _S, _Data) ->
    {keep_state_and_data, [{next_event, internal, route}]};
handle_event(internal, route, _S, Data) ->
    {Data1, Actions} = try_route(Data),
    {keep_state, Data1, Actions};
handle_event(_Type, _Event, _S, _Data) ->
    keep_state_and_data.

%% ---- routing pass ----

%% Returns {Data, Actions} — the actions arm one offer timeout per offer
%% placed during this pass. The snapshots are taken once per pass, so an
%% agent already given an offer THIS pass is excluded from later items
%% (the snapshot no longer reflects their pending offer); the accept
%% handler re-triggers routing, so spare capacity is picked up by the
%% next pass with fresh snapshots. Actions are uniquely-named generic
%% timeouts, so accumulation order is irrelevant — prepend, don't append
%% (appending is quadratic in offers placed).
try_route(Data = #queue_state{tenant = TenantId}) ->
    Now = cx_time:now_ms(),
    Snapshots = agent_snapshots(TenantId),
    Items = [Item || {_, Item} <- gb_trees:to_list(Data#queue_state.waiting)],
    {Data1, Actions, _Offered} = lists:foldl(
        fun(Item, {Acc, Actions, Offered}) ->
            {Acc1, ItemActions, Offered1} =
                route_item(Item, Snapshots, Now, Acc, Offered),
            {Acc1, ItemActions ++ Actions, Offered1}
        end,
        {Data, [], #{}},
        Items
    ),
    {Data1, Actions}.

route_item(Item, Snapshots, Now, Data, Offered) ->
    Reqs = cx_routing:effective_requirements(
        Item#waiting_item.skill_requirements,
        Now - Item#waiting_item.enqueued_at
    ),
    Eligible = [
        S
     || S <- cx_routing:eligible(
            Item#waiting_item.media,
            Reqs,
            Snapshots,
            Now
        ),
        not lists:member(
            maps:get(agent_id, S),
            Item#waiting_item.offered_to
        ),
        not is_map_key(maps:get(agent_id, S), Offered)
    ],
    offer_to_first(cx_routing:rank(Reqs, Eligible), Item, Data, Offered).

offer_to_first([], _Item, Data, Offered) ->
    {Data, [], Offered};
offer_to_first([Snapshot | Rest], Item, Data, Offered) ->
    #{agent_id := AgentId, pid := AgentPid} = Snapshot,
    OfferId = cx_id:new(),
    InteractionId = Item#waiting_item.interaction_id,
    %% the ring deadline travels WITH the offer so countdown UIs need no
    %% queue-config knowledge; null = ring forever
    OfferTimeout = (Data#queue_state.config)#cx_queue.offer_timeout_ms,
    ExpiresAt =
        case OfferTimeout of
            infinity -> null;
            Ms -> cx_time:now_ms() + Ms
        end,
    Offer = #{
        offer_id => OfferId,
        interaction_id => InteractionId,
        media => Item#waiting_item.media,
        queue_key => {Data#queue_state.tenant, Data#queue_state.queue_id},
        queue_pid => self(),
        expires_at => ExpiresAt
    },
    case
        try
            gen_statem:call(AgentPid, {offer, Offer}, ?OFFER_CALL_TIMEOUT_MS)
        catch
            exit:{noproc, _} -> stale_snapshot(Data#queue_state.tenant, AgentId, AgentPid);
            exit:_ -> {error, not_routable}
        end
    of
        ok ->
            MonitorRef = erlang:monitor(process, AgentPid),
            ok = cx_store:tx(fun() ->
                [Rec] = mnesia:read(cx_interaction, {Data#queue_state.tenant, InteractionId}),
                mnesia:write(Rec#cx_interaction{state = offered})
            end),
            {_, Waiting} = take_item(
                {Item#waiting_item.enqueued_at, Item#waiting_item.sequence},
                Data#queue_state.waiting
            ),
            PlacedOffer = #placed_offer{
                offer_id = OfferId,
                agent_id = AgentId,
                agent_pid = AgentPid,
                monitor_ref = MonitorRef,
                item = Item
            },
            Data1 = Data#queue_state{
                waiting = Waiting,
                by_id = maps:remove(InteractionId, Data#queue_state.by_id),
                offers = maps:put(OfferId, PlacedOffer, Data#queue_state.offers)
            },
            publish(
                Data1,
                Item#waiting_item.media,
                offer_created,
                #{
                    <<"interaction_id">> => InteractionId,
                    <<"offer_id">> => OfferId,
                    <<"agent_id">> => AgentId,
                    <<"expires_at">> => ExpiresAt
                }
            ),
            %% infinity = ring forever: gen_statem never arms the timer
            {
                Data1,
                [{{timeout, {offer, OfferId}}, OfferTimeout, expire}],
                Offered#{AgentId => true}
            };
        {error, not_routable} ->
            offer_to_first(Rest, Item, Data, Offered)
    end.

stale_snapshot(TenantId, AgentId, DeadPid) ->
    %% presence row points at a dead session (kill -9 etc.); clean it up
    case mnesia:dirty_read(cx_agent_snapshot, {TenantId, AgentId}) of
        [#cx_agent_snapshot{pid = DeadPid}] ->
            mnesia:dirty_delete(cx_agent_snapshot, {TenantId, AgentId});
        _ ->
            ok
    end,
    {error, not_routable}.

%% ---- helpers ----

%% Remove a live offer, always releasing its monitor — every resolution
%% path (accept, reject, timeout) must demonitor or the queue leaks one
%% monitor per resolved offer. The 'DOWN' handler is the one exception:
%% its monitor already fired.
take_offer(OfferId, Data) ->
    case maps:take(OfferId, Data#queue_state.offers) of
        {Offer, Offers} ->
            erlang:demonitor(Offer#placed_offer.monitor_ref, [flush]),
            {Offer, Data#queue_state{offers = Offers}};
        error ->
            error
    end.

insert_item(Item = #waiting_item{enqueued_at = At, sequence = Sequence}, Data) ->
    Key = {At, Sequence},
    Data#queue_state{
        waiting = gb_trees:insert(Key, Item, Data#queue_state.waiting),
        by_id = maps:put(Item#waiting_item.interaction_id, Key, Data#queue_state.by_id)
    }.

take_item(Key, Tree) ->
    Item = gb_trees:get(Key, Tree),
    {Item, gb_trees:delete(Key, Tree)}.

requeue(#placed_offer{item = Item, agent_id = AgentId}, Penalize, EventType, Data) ->
    Item1 =
        case Penalize of
            true -> Item#waiting_item{offered_to = [AgentId | Item#waiting_item.offered_to]};
            false -> Item
        end,
    InteractionId = Item1#waiting_item.interaction_id,
    ok = cx_store:tx(fun() ->
        case mnesia:read(cx_interaction, {Data#queue_state.tenant, InteractionId}) of
            [Rec = #cx_interaction{state = offered}] ->
                mnesia:write(Rec#cx_interaction{
                    state = queued,
                    agent_id = undefined
                });
            _ ->
                ok
        end
    end),
    Data1 = insert_item(Item1, Data),
    publish(
        Data1,
        Item1#waiting_item.media,
        EventType,
        #{<<"interaction_id">> => InteractionId, <<"agent_id">> => AgentId}
    ),
    Data1.

widen_actions(
    #waiting_item{
        interaction_id = InteractionId,
        skill_requirements = Reqs,
        enqueued_at = At
    },
    Now
) ->
    Waited = Now - At,
    Steps = lists:usort([
        AfterMs
     || #skill_requirement{widening = W} <- Reqs,
        {AfterMs, _} <- W,
        AfterMs > Waited
    ]),
    [
        {{timeout, {widen, InteractionId, AfterMs}}, AfterMs - Waited, widen}
     || AfterMs <- Steps
    ].

refresh_config(Data = #queue_state{tenant = TenantId, queue_id = QueueId}) ->
    case cx_queue:fetch(TenantId, QueueId) of
        {ok, Config} -> Config;
        {error, not_found} -> Data#queue_state.config
    end.

agent_snapshots(TenantId) ->
    Recs = mnesia:dirty_match_object(cx_patterns:agent_snapshots(TenantId)),
    [
        #{
            agent_id => AgentId,
            pid => Pid,
            ready => Ready,
            mix => Mix,
            skills => Skills,
            profile => Profile,
            idle_since => IdleSince
        }
     || #cx_agent_snapshot{
            key = {_, AgentId},
            pid = Pid,
            ready = Ready,
            mix = Mix,
            skills = Skills,
            profile = Profile,
            idle_since = IdleSince
        } <- Recs
    ].

publish(#queue_state{tenant = TenantId, queue_id = QueueId}, Media, Type, ExtraData) ->
    cx_event:publish(TenantId, QueueId, Media, Type, ExtraData).
