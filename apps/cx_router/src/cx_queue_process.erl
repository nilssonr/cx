-module(cx_queue_process).

%% One process per queue. Owns the waiting order (gb_trees keyed by
%% {enqueued_at, seq} — assigned once, stored in Mnesia, so a rejected,
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

-record(witem, {
    interaction_id :: binary(),
    media :: binary(),
    %% snapshot at enqueue
    skill_reqs :: [#skill_req{}],
    enqueued_at :: integer(),
    seq :: integer(),
    %% rejected/timed out; skipped
    offered_to = [] :: [binary()]
}).

-record(qoffer, {
    offer_id :: binary(),
    agent_id :: binary(),
    agent_pid :: pid(),
    mon_ref :: reference(),
    item :: #witem{}
}).

-record(qd, {
    tenant :: binary(),
    queue_id :: binary(),
    config :: #cx_queue{},
    waiting = gb_trees:empty() :: gb_trees:tree(),
    by_id = #{} :: #{binary() => {integer(), integer()}},
    offers = #{} :: #{binary() => #qoffer{}},
    seq = 0 :: integer()
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
            {Data, Actions} = recover(#qd{
                tenant = TenantId,
                queue_id = QueueId,
                config = Config
            }),
            {ok, serving, Data, Actions ++ [{next_event, internal, route}]};
        {error, not_found} ->
            {stop, {queue_not_found, TenantId, QueueId}}
    end.

%% Rebuild waiting state from Mnesia: queued and offered interactions are
%% re-enqueued under their preserved {enqueued_at, seq} keys (an offer
%% that was live when we died simply degrades to "requeued at original
%% position").
recover(Data = #qd{tenant = TenantId, queue_id = QueueId}) ->
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
            Item = #witem{
                interaction_id = element(2, Rec#cx_interaction.key),
                media = Rec#cx_interaction.media_type,
                skill_reqs = (Acc#qd.config)#cx_queue.skill_reqs,
                enqueued_at = Rec#cx_interaction.enqueued_at,
                seq = Rec#cx_interaction.seq
            },
            %% prepend: uniquely-named timeouts, order-free (see try_route)
            {insert_item(Item, Acc), widen_actions(Item, Now) ++ Actions}
        end,
        {Data#qd{seq = next_seq(Recs)}, []},
        Recs
    ).

next_seq([]) -> 0;
next_seq(Recs) -> lists:max([R#cx_interaction.seq || R <- Recs]) + 1.

%% ---- events ----

handle_event({call, From}, {enqueue, IId, Media, Props, CreatedAt}, _S, Data) ->
    Config = refresh_config(Data),
    Now = cx_time:now_ms(),
    Seq = Data#qd.seq,
    Rec = #cx_interaction{
        key = {Data#qd.tenant, IId},
        queue_key = {Data#qd.tenant, Data#qd.queue_id},
        media_type = Media,
        properties = Props,
        state = queued,
        created_at = CreatedAt,
        enqueued_at = Now,
        seq = Seq
    },
    ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
    Item = #witem{
        interaction_id = IId,
        media = Media,
        skill_reqs = Config#cx_queue.skill_reqs,
        enqueued_at = Now,
        seq = Seq
    },
    Data1 = insert_item(Item, Data#qd{seq = Seq + 1, config = Config}),
    publish(Data1, Media, interaction_queued, #{<<"interaction_id">> => IId}),
    {keep_state, Data1,
        [{reply, From, {ok, IId}} | widen_actions(Item, Now)] ++
            [{next_event, internal, route}]};
handle_event({call, From}, {cancel, IId}, _S, Data) ->
    case maps:take(IId, Data#qd.by_id) of
        {Key, ById} ->
            {Item, Waiting} = take_item(Key, Data#qd.waiting),
            ok = cx_store:tx(fun() ->
                case mnesia:read(cx_interaction, {Data#qd.tenant, IId}) of
                    [Rec = #cx_interaction{state = queued}] ->
                        mnesia:write(Rec#cx_interaction{state = cancelled});
                    _ ->
                        ok
                end
            end),
            Data1 = Data#qd{by_id = ById, waiting = Waiting},
            publish(
                Data1,
                Item#witem.media,
                interaction_cancelled,
                #{<<"interaction_id">> => IId}
            ),
            {keep_state, Data1, [{reply, From, ok}]};
        error ->
            %% offered or active interactions are not cancellable in M1
            {keep_state_and_data, [{reply, From, {error, not_cancellable}}]}
    end;
handle_event({call, From}, {accepted, OfferId}, _S, Data) ->
    case take_offer(OfferId, Data) of
        {Offer = #qoffer{item = Item}, Data0} ->
            IId = Item#witem.interaction_id,
            ok = cx_store:tx(fun() ->
                [Rec] = mnesia:read(cx_interaction, {Data#qd.tenant, IId}),
                mnesia:write(Rec#cx_interaction{
                    state = active,
                    agent_id = Offer#qoffer.agent_id,
                    accepted_at = cx_time:now_ms()
                })
            end),
            gen_statem:cast(Offer#qoffer.agent_pid, {offer_accepted, OfferId}),
            publish(
                Data0,
                Item#witem.media,
                offer_accepted,
                #{
                    <<"interaction_id">> => IId,
                    <<"offer_id">> => OfferId,
                    <<"agent_id">> => Offer#qoffer.agent_id
                }
            ),
            %% wake routing: each pass offers an agent at most once, so
            %% a multi-capacity agent gets the next waiting item from a
            %% fresh pass
            {keep_state, Data0, [
                {reply, From, {ok, IId}},
                {{timeout, {offer, OfferId}}, cancel},
                {next_event, internal, route}
            ]};
        error ->
            {keep_state_and_data, [{reply, From, {error, expired}}]}
    end;
handle_event({call, From}, {rejected, OfferId}, _S, Data) ->
    case take_offer(OfferId, Data) of
        {Offer, Data0} ->
            gen_statem:cast(Offer#qoffer.agent_pid, {offer_withdrawn, OfferId}),
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
%% re-enters the waiting order under its preserved {enqueued_at, seq},
%% so it never loses its place. The state guard makes a duplicate cast
%% a no-op (first one flips the row to queued).
handle_event(cast, {requeue_active, IId}, _S, Data) ->
    Config = refresh_config(Data),
    Requeued = cx_store:tx(fun() ->
        case mnesia:read(cx_interaction, {Data#qd.tenant, IId}) of
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
            Item = #witem{
                interaction_id = IId,
                media = Rec#cx_interaction.media_type,
                skill_reqs = Config#cx_queue.skill_reqs,
                enqueued_at = Rec#cx_interaction.enqueued_at,
                seq = Rec#cx_interaction.seq
            },
            Data1 = insert_item(Item, Data#qd{config = Config}),
            publish(
                Data1,
                Item#witem.media,
                interaction_requeued,
                #{
                    <<"interaction_id">> => IId,
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
            gen_statem:cast(Offer#qoffer.agent_pid, {offer_withdrawn, OfferId}),
            Data1 = requeue(Offer, true, offer_timeout, Data0),
            {keep_state, Data1, [{next_event, internal, route}]};
        error ->
            keep_state_and_data
    end;
handle_event(info, {'DOWN', MonRef, process, _Pid, _Reason}, _S, Data) ->
    %% agent session died mid-offer: requeue at original position,
    %% without penalizing the agent (they never saw it resolve)
    case
        [
            O
         || O = #qoffer{mon_ref = R} <- maps:values(Data#qd.offers),
            R =:= MonRef
        ]
    of
        [Offer] ->
            Offers = maps:remove(Offer#qoffer.offer_id, Data#qd.offers),
            Data1 = requeue(
                Offer,
                false,
                interaction_requeued,
                Data#qd{offers = Offers}
            ),
            {keep_state, Data1, [
                {{timeout, {offer, Offer#qoffer.offer_id}}, cancel},
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
try_route(Data = #qd{tenant = TenantId}) ->
    Now = cx_time:now_ms(),
    Snapshots = agent_snapshots(TenantId),
    Items = [Item || {_, Item} <- gb_trees:to_list(Data#qd.waiting)],
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
        Item#witem.skill_reqs,
        Now - Item#witem.enqueued_at
    ),
    Eligible = [
        S
     || S <- cx_routing:eligible(
            Item#witem.media,
            Reqs,
            Snapshots,
            Now
        ),
        not lists:member(
            maps:get(agent_id, S),
            Item#witem.offered_to
        ),
        not is_map_key(maps:get(agent_id, S), Offered)
    ],
    offer_to_first(cx_routing:rank(Reqs, Eligible), Item, Data, Offered).

offer_to_first([], _Item, Data, Offered) ->
    {Data, [], Offered};
offer_to_first([Snapshot | Rest], Item, Data, Offered) ->
    #{agent_id := AgentId, pid := AgentPid} = Snapshot,
    OfferId = cx_id:new(),
    IId = Item#witem.interaction_id,
    %% the ring deadline travels WITH the offer so countdown UIs need no
    %% queue-config knowledge; null = ring forever
    OfferTimeout = (Data#qd.config)#cx_queue.offer_timeout_ms,
    ExpiresAt =
        case OfferTimeout of
            infinity -> null;
            Ms -> cx_time:now_ms() + Ms
        end,
    Offer = #{
        offer_id => OfferId,
        interaction_id => IId,
        media => Item#witem.media,
        queue_key => {Data#qd.tenant, Data#qd.queue_id},
        queue_pid => self(),
        expires_at => ExpiresAt
    },
    case
        try
            gen_statem:call(AgentPid, {offer, Offer}, ?OFFER_CALL_TIMEOUT_MS)
        catch
            exit:{noproc, _} -> stale_snapshot(Data#qd.tenant, AgentId, AgentPid);
            exit:_ -> {error, not_routable}
        end
    of
        ok ->
            MonRef = erlang:monitor(process, AgentPid),
            ok = cx_store:tx(fun() ->
                [Rec] = mnesia:read(cx_interaction, {Data#qd.tenant, IId}),
                mnesia:write(Rec#cx_interaction{state = offered})
            end),
            {_, Waiting} = take_item(
                {Item#witem.enqueued_at, Item#witem.seq},
                Data#qd.waiting
            ),
            QOffer = #qoffer{
                offer_id = OfferId,
                agent_id = AgentId,
                agent_pid = AgentPid,
                mon_ref = MonRef,
                item = Item
            },
            Data1 = Data#qd{
                waiting = Waiting,
                by_id = maps:remove(IId, Data#qd.by_id),
                offers = maps:put(OfferId, QOffer, Data#qd.offers)
            },
            publish(
                Data1,
                Item#witem.media,
                offer_created,
                #{
                    <<"interaction_id">> => IId,
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
    case maps:take(OfferId, Data#qd.offers) of
        {Offer, Offers} ->
            erlang:demonitor(Offer#qoffer.mon_ref, [flush]),
            {Offer, Data#qd{offers = Offers}};
        error ->
            error
    end.

insert_item(Item = #witem{enqueued_at = At, seq = Seq}, Data) ->
    Key = {At, Seq},
    Data#qd{
        waiting = gb_trees:insert(Key, Item, Data#qd.waiting),
        by_id = maps:put(Item#witem.interaction_id, Key, Data#qd.by_id)
    }.

take_item(Key, Tree) ->
    Item = gb_trees:get(Key, Tree),
    {Item, gb_trees:delete(Key, Tree)}.

requeue(#qoffer{item = Item, agent_id = AgentId}, Penalize, EventType, Data) ->
    Item1 =
        case Penalize of
            true -> Item#witem{offered_to = [AgentId | Item#witem.offered_to]};
            false -> Item
        end,
    IId = Item1#witem.interaction_id,
    ok = cx_store:tx(fun() ->
        case mnesia:read(cx_interaction, {Data#qd.tenant, IId}) of
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
        Item1#witem.media,
        EventType,
        #{<<"interaction_id">> => IId, <<"agent_id">> => AgentId}
    ),
    Data1.

widen_actions(
    #witem{
        interaction_id = IId,
        skill_reqs = Reqs,
        enqueued_at = At
    },
    Now
) ->
    Waited = Now - At,
    Steps = lists:usort([
        AfterMs
     || #skill_req{widening = W} <- Reqs,
        {AfterMs, _} <- W,
        AfterMs > Waited
    ]),
    [
        {{timeout, {widen, IId, AfterMs}}, AfterMs - Waited, widen}
     || AfterMs <- Steps
    ].

refresh_config(Data = #qd{tenant = TenantId, queue_id = QueueId}) ->
    case cx_queue:fetch(TenantId, QueueId) of
        {ok, Config} -> Config;
        {error, not_found} -> Data#qd.config
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

publish(#qd{tenant = TenantId, queue_id = QueueId}, Media, Type, ExtraData) ->
    cx_event:publish(TenantId, QueueId, Media, Type, ExtraData).
