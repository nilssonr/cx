-module(cx_router_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("cx_core/include/cx_core.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    happy_path_with_wrapup/1,
    multi_concurrent_offers/1,
    reject_requeues_in_order/1,
    offer_timeout_requeues/1,
    widening_admits_lower_rank/1,
    guard_blocks_media/1,
    not_ready_mid_offer/1,
    agent_crash_requeues/1,
    queue_restart_preserves_order/1,
    cancel_rules/1,
    wrapup_extend_finalize/1,
    wrapup_gates_only_its_media/1,
    wrapup_cap_enforced/1,
    hold_occupies_capacity/1,
    qualification_gate/1,
    stop_session_rules/1,
    accept_retry_idempotent/1,
    force_sign_out_requeues/1,
    dangling_profile_fails_closed/1,
    facade_permissions/1,
    reject_releases_monitor/1,
    backlog_drains_one_offer_per_pass/1,
    infinite_ring_offer_stays_pending/1
]).

all() ->
    [
        happy_path_with_wrapup,
        multi_concurrent_offers,
        reject_requeues_in_order,
        offer_timeout_requeues,
        widening_admits_lower_rank,
        guard_blocks_media,
        not_ready_mid_offer,
        agent_crash_requeues,
        queue_restart_preserves_order,
        cancel_rules,
        wrapup_extend_finalize,
        wrapup_gates_only_its_media,
        wrapup_cap_enforced,
        hold_occupies_capacity,
        qualification_gate,
        stop_session_rules,
        accept_retry_idempotent,
        force_sign_out_requeues,
        dangling_profile_fails_closed,
        facade_permissions,
        reject_releases_monitor,
        backlog_drains_one_offer_per_pass,
        infinite_ring_offer_stays_pending
    ].

init_per_suite(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    %% persistent: application load must not reset these to .app defaults
    ok = application:set_env(
        cx_core,
        mnesia_dir,
        filename:join(PrivDir, "mnesia"),
        [{persistent, true}]
    ),
    ok = application:set_env(
        cx_auth,
        key_source,
        {static, []},
        [{persistent, true}]
    ),
    {ok, _} = application:ensure_all_started(cx_router),
    Config.

end_per_suite(_Config) ->
    application:stop(cx_router),
    application:stop(cx_auth),
    application:stop(cx_core),
    application:stop(mnesia),
    ok.

%% ---- cases ----

happy_path_with_wrapup(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"Building permits">>,
        <<"wrapup_duration_ms">> => 700
    }),
    %% capacity 1: after-call work occupies the slot, so it gates the
    %% next offer purely through the profile (an uncapped agent is
    %% deliberately never blocked by ACW)
    ProfileId = profile(Admin, #{<<"name">> => <<"one">>, <<"max_total">> => 1}),
    UserId = user(Admin, #{}, ProfileId),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),

    Integrator = integrator(T),
    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            Integrator,
            #{
                <<"queue_id">> => QueueId,
                <<"media_type">> => Media,
                <<"properties">> => #{
                    <<"case">> => <<"42">>,
                    <<"source">> => <<"sap">>
                }
            }
        ),
    {ok, _} = wait_event(interaction_queued),
    {ok, #{<<"offer_id">> := OfferId, <<"interaction_id">> := I1}} =
        wait_data(offer_created),

    {ok, _} = cx_router:accept_offer(Agent, OfferId),
    {ok, _} = wait_event(offer_accepted),
    {ok, #{
        <<"state">> := <<"active">>,
        <<"properties">> := #{<<"case">> := <<"42">>}
    }} =
        cx_router:get_interaction(Integrator, I1),

    {ok, #{<<"state">> := <<"wrapup">>, <<"wrapup_until">> := _}} =
        cx_router:complete(Agent, I1),
    {ok, _} = wait_event(wrapup_started),
    {ok, #{<<"state">> := <<"wrapup">>}} =
        cx_router:get_interaction(Integrator, I1),

    %% the interaction's ACW occupies the slot until it expires
    {ok, #{<<"id">> := _I2}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    ?assertEqual(timeout, wait_event(offer_created, 300)),
    {ok, _} = wait_event(wrapup_ended, 2000),
    {ok, #{<<"interaction_id">> := I1}} = wait_data(interaction_completed),
    {ok, #{<<"state">> := <<"completed">>}} =
        cx_router:get_interaction(Integrator, I1),
    {ok, _} = wait_event(offer_created, 2000),
    ok.

multi_concurrent_offers(_Config) ->
    %% no profile => nothing is limited; one agent takes three at once
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 0
    }),
    UserId = user(Admin, #{}, undefined),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),

    Integrator = integrator(T),
    Ids = [
        begin
            {ok, #{<<"id">> := I}} =
                cx_router:create_interaction(
                    Integrator,
                    #{
                        <<"queue_id">> => QueueId,
                        <<"media_type">> => Media
                    }
                ),
            I
        end
     || _ <- [1, 2, 3]
    ],
    Offers = [
        begin
            {ok, #{<<"offer_id">> := O}} = wait_data(offer_created),
            O
        end
     || _ <- [1, 2, 3]
    ],
    [{ok, _} = cx_router:accept_offer(Agent, O) || O <- Offers],
    {ok, #{<<"active">> := Active}} = cx_router:get_session(Agent),
    ?assertEqual(lists:sort(Ids), lists:sort(Active)),
    ok.

reject_requeues_in_order(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 0
    }),
    ProfileId = profile(Admin, #{
        <<"name">> => <<"one">>,
        <<"max_total">> => 1
    }),
    UserA = user(Admin, #{}, ProfileId),
    AgentA = start_agent(T, UserA),
    ok = cx_router:set_ready(AgentA, Media, ready),

    Integrator = integrator(T),
    [I1, I2, _I3] =
        [
            begin
                {ok, #{<<"id">> := I}} =
                    cx_router:create_interaction(
                        Integrator,
                        #{
                            <<"queue_id">> => QueueId,
                            <<"media_type">> => Media
                        }
                    ),
                I
            end
         || _ <- [1, 2, 3]
        ],

    %% A (capacity 1) is offered the head of the queue: I1
    {ok, #{<<"offer_id">> := Offer1, <<"interaction_id">> := I1}} =
        wait_data(offer_created),
    ok = cx_router:reject_offer(AgentA, Offer1),
    {ok, _} = wait_event(offer_rejected),
    %% A is penalized for I1, so A now gets I2
    {ok, #{<<"interaction_id">> := I2}} = wait_data(offer_created),

    %% B arrives: I1 must be offered before I3 — position preserved
    UserB = user(Admin, #{}, ProfileId),
    AgentB = start_agent(T, UserB),
    ok = cx_router:set_ready(AgentB, Media, ready),
    {ok, #{<<"interaction_id">> := OfferedToB, <<"agent_id">> := UserB}} =
        wait_data(offer_created),
    ?assertEqual(I1, OfferedToB),
    ok.

offer_timeout_requeues(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"offer_timeout_ms">> => 300,
        <<"wrapup_duration_ms">> => 0
    }),
    UserA = user(Admin, #{}, undefined),
    AgentA = start_agent(T, UserA),
    ok = cx_router:set_ready(AgentA, Media, ready),

    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            integrator(T),
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    {ok, #{<<"interaction_id">> := I1, <<"agent_id">> := UserA}} =
        wait_data(offer_created),
    %% agent ignores it; the queue times the offer out and requeues
    {ok, #{<<"interaction_id">> := I1}} = wait_data(offer_timeout, 2000),

    UserB = user(Admin, #{}, undefined),
    AgentB = start_agent(T, UserB),
    ok = cx_router:set_ready(AgentB, Media, ready),
    {ok, #{<<"interaction_id">> := I1, <<"agent_id">> := UserB}} =
        wait_data(offer_created),
    ok.

widening_admits_lower_rank(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    SkillId = skill(Admin, <<"permits">>),
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 0,
        <<"skill_reqs">> =>
            [
                #{
                    <<"skill_id">> => SkillId,
                    <<"min_rank">> => 3,
                    <<"widening">> =>
                        [
                            #{
                                <<"after_ms">> => 600,
                                <<"min_rank">> => 1
                            }
                        ]
                }
            ]
    }),
    UserId = user(Admin, #{SkillId => 1}, undefined),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),

    {ok, _} = cx_router:create_interaction(
        integrator(T),
        #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
    ),
    %% rank 1 < required 3: no offer yet
    ?assertEqual(timeout, wait_event(offer_created, 300)),
    %% after 600 ms the requirement widens to rank 1
    {ok, _} = wait_event(offer_created, 2000),
    ok.

guard_blocks_media(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Voice = <<"voice">>,
    Om = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 0
    }),
    %% "if I am handling one voice call, don't route me open media"
    ProfileId = profile(Admin, #{
        <<"name">> => <<"g">>,
        <<"guards">> =>
            [
                #{
                    <<"when_media">> => Voice,
                    <<"gte">> => 1,
                    <<"block">> => [Om]
                }
            ]
    }),
    UserId = user(Admin, #{}, ProfileId),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Voice, ready),
    ok = cx_router:set_ready(Agent, Om, ready),

    Integrator = integrator(T),
    {ok, #{<<"id">> := IVoice}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Voice}
        ),
    {ok, #{<<"offer_id">> := VOffer}} = wait_data(offer_created),
    {ok, _} = cx_router:accept_offer(Agent, VOffer),
    {ok, _} = wait_event(offer_accepted),

    {ok, #{<<"id">> := _IOm}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Om}
        ),
    ?assertEqual(timeout, wait_event(offer_created, 300)),

    ok = cx_router:complete(Agent, IVoice),
    {ok, #{<<"interaction_id">> := _}} = wait_data(offer_created, 2000),
    ok.

not_ready_mid_offer(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 0
    }),
    ReasonId = not_ready_reason(Admin, <<"Lunch">>),
    UserId = user(Admin, #{}, undefined),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),

    Integrator = integrator(T),
    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    {ok, #{<<"offer_id">> := Offer1}} = wait_data(offer_created),

    %% going not-ready blocks NEW offers but leaves the pending one valid
    ok = cx_router:set_ready(Agent, Media, {not_ready, ReasonId}),
    {ok, #{<<"id">> := _I2}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    ?assertEqual(timeout, wait_event(offer_created, 300)),

    {ok, _} = cx_router:accept_offer(Agent, Offer1),
    {ok, #{<<"state">> := <<"active">>}} =
        cx_router:get_interaction(Integrator, I1),
    ok.

agent_crash_requeues(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 0
    }),
    UserA = user(Admin, #{}, undefined),
    AgentA = start_agent(T, UserA),
    ok = cx_router:set_ready(AgentA, Media, ready),

    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            integrator(T),
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    {ok, #{<<"interaction_id">> := I1}} = wait_data(offer_created),

    SessionPid = cx_reg:whereis_name({agent, T, UserA}),
    true = is_pid(SessionPid) andalso exit(SessionPid, kill),
    {ok, #{<<"interaction_id">> := I1}} = wait_data(interaction_requeued),

    UserB = user(Admin, #{}, undefined),
    AgentB = start_agent(T, UserB),
    ok = cx_router:set_ready(AgentB, Media, ready),
    {ok, #{<<"interaction_id">> := I1, <<"agent_id">> := UserB}} =
        wait_data(offer_created),
    ok.

queue_restart_preserves_order(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 0
    }),
    Integrator = integrator(T),
    [I1 | _] =
        [
            begin
                {ok, #{<<"id">> := I}} =
                    cx_router:create_interaction(
                        Integrator,
                        #{
                            <<"queue_id">> => QueueId,
                            <<"media_type">> => Media
                        }
                    ),
                I
            end
         || _ <- [1, 2, 3]
        ],

    OldPid = cx_reg:whereis_name({queue, T, QueueId}),
    true = is_pid(OldPid) andalso exit(OldPid, kill),
    ok = wait_until(fun() ->
        case cx_reg:whereis_name({queue, T, QueueId}) of
            undefined -> false;
            Pid -> Pid =/= OldPid
        end
    end),

    ProfileId = profile(Admin, #{
        <<"name">> => <<"one">>,
        <<"max_total">> => 1
    }),
    UserId = user(Admin, #{}, ProfileId),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),
    {ok, #{<<"interaction_id">> := First}} = wait_data(offer_created, 2000),
    ?assertEqual(I1, First),
    ok.

cancel_rules(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 0
    }),
    Integrator = integrator(T),

    %% queued -> cancellable
    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    ok = cx_router:cancel_interaction(Integrator, I1),
    {ok, #{<<"state">> := <<"cancelled">>}} =
        cx_router:get_interaction(Integrator, I1),
    ?assertEqual(
        {error, not_cancellable},
        cx_router:cancel_interaction(Integrator, I1)
    ),

    %% offered -> not cancellable in M1
    UserId = user(Admin, #{}, undefined),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),
    {ok, #{<<"id">> := I2}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    {ok, _} = wait_event(offer_created),
    ?assertEqual(
        {error, not_cancellable},
        cx_router:cancel_interaction(Integrator, I2)
    ),
    ok.

wrapup_extend_finalize(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 60000
    }),
    ProfileId = profile(Admin, #{<<"name">> => <<"one">>, <<"max_total">> => 1}),
    UserId = user(Admin, #{}, ProfileId),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),

    ?assertEqual({error, not_found}, cx_router:extend_wrapup(Agent, <<"ghost">>, 1000)),
    ?assertEqual({error, not_found}, cx_router:finalize_wrapup(Agent, <<"ghost">>)),

    Integrator = integrator(T),
    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    {ok, #{<<"offer_id">> := Offer1}} = wait_data(offer_created),
    {ok, _} = cx_router:accept_offer(Agent, Offer1),

    %% wrap-up operations are per interaction and phase-guarded
    ?assertEqual({error, not_in_wrapup}, cx_router:extend_wrapup(Agent, I1, 1000)),
    ?assertEqual({error, not_in_wrapup}, cx_router:finalize_wrapup(Agent, I1)),

    {ok, #{<<"state">> := <<"wrapup">>}} = cx_router:complete(Agent, I1),
    {ok, _} = wait_event(wrapup_started),

    ok = cx_router:extend_wrapup(Agent, I1, 60000),
    {ok, #{<<"interaction_id">> := I1}} = wait_data(wrapup_extended),

    %% the ACW slot blocks offers of this media at capacity 1
    {ok, _} = cx_router:create_interaction(
        Integrator,
        #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
    ),
    ?assertEqual(timeout, wait_event(offer_created, 300)),

    ok = cx_router:finalize_wrapup(Agent, I1),
    {ok, _} = wait_event(wrapup_cancelled),
    {ok, #{<<"interaction_id">> := I1}} = wait_data(interaction_completed),
    {ok, _} = wait_event(offer_created, 2000),
    ok.

%% After-call work gates ONLY its own media (through the mix + media
%% cap) — a chat in ACW must not block a voice offer.
wrapup_gates_only_its_media(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Chat = <<"chat">>,
    Voice = <<"voice">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 60000
    }),
    ProfileId = profile(Admin, #{
        <<"name">> => <<"capped-chat">>,
        <<"media_caps">> => #{Chat => 1}
    }),
    UserId = user(Admin, #{}, ProfileId),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Chat, ready),
    ok = cx_router:set_ready(Agent, Voice, ready),

    Integrator = integrator(T),
    {ok, #{<<"id">> := IChat}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Chat}
        ),
    {ok, #{<<"offer_id">> := ChatOffer}} = wait_data(offer_created),
    {ok, _} = cx_router:accept_offer(Agent, ChatOffer),
    {ok, #{<<"state">> := <<"wrapup">>}} = cx_router:complete(Agent, IChat),
    {ok, _} = wait_event(wrapup_started),

    %% chat is blocked by its ACW slot...
    {ok, _} = cx_router:create_interaction(
        Integrator,
        #{<<"queue_id">> => QueueId, <<"media_type">> => Chat}
    ),
    ?assertEqual(timeout, wait_event(offer_created, 300)),

    %% ...but voice flows
    {ok, #{<<"id">> := IVoice}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Voice}
        ),
    {ok, #{<<"interaction_id">> := IVoice}} = wait_data(offer_created, 2000),
    ok.

%% wrapup_max_ms caps TOTAL ACW per interaction (initial + extensions).
wrapup_cap_enforced(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 30000,
        <<"wrapup_max_ms">> => 40000
    }),
    UserId = user(Admin, #{}, undefined),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),

    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            integrator(T),
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    {ok, #{<<"offer_id">> := Offer1}} = wait_data(offer_created),
    {ok, _} = cx_router:accept_offer(Agent, Offer1),
    {ok, #{<<"state">> := <<"wrapup">>}} = cx_router:complete(Agent, I1),

    %% 30000 + 10000 = 40000 <= cap
    ok = cx_router:extend_wrapup(Agent, I1, 10000),
    %% one more ms would exceed it
    ?assertEqual(
        {error, wrapup_cap_exceeded},
        cx_router:extend_wrapup(Agent, I1, 1)
    ),
    ok = cx_router:finalize_wrapup(Agent, I1),
    ok.

%% A qualification-required queue hard-blocks ACW finalize (timer,
%% DELETE and sign-out) until the interaction carries codes; entering
%% them releases an overdue wrap-up immediately. Interior tree nodes
%% are selectable.
qualification_gate(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    {ok, #{<<"id">> := TopicA}} =
        cx_qualification_code:create(Admin, #{<<"name">> => <<"Topic A">>}),
    {ok, #{<<"id">> := _TopicA1}} =
        cx_qualification_code:create(Admin, #{
            <<"name">> => <<"Topic A.1">>,
            <<"parent_id">> => TopicA
        }),
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 300,
        <<"qualification_required">> => true
    }),
    UserId = user(Admin, #{}, undefined),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),

    Integrator = integrator(T),
    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    {ok, #{<<"offer_id">> := Offer1}} = wait_data(offer_created),
    {ok, _} = cx_router:accept_offer(Agent, Offer1),

    ?assertEqual(
        {error, {invalid, <<"qualification_ids">>}},
        cx_router:qualify(Agent, I1, #{<<"qualification_ids">> => [<<"ghost">>]})
    ),

    {ok, #{<<"state">> := <<"wrapup">>}} = cx_router:complete(Agent, I1),
    {ok, _} = wait_event(wrapup_started),

    %% the 300 ms timer fires against the block: no finalize
    ?assertEqual(timeout, wait_event(wrapup_ended, 600)),
    ?assertEqual(
        {error, qualification_required},
        cx_router:finalize_wrapup(Agent, I1)
    ),
    ?assertEqual({error, qualification_required}, cx_router:stop_session(Agent)),

    %% an interior node qualifies; entering codes releases the overdue ACW
    ok = cx_router:qualify(Agent, I1, #{<<"qualification_ids">> => [TopicA]}),
    {ok, #{<<"qualification_ids">> := [TopicA]}} = wait_data(interaction_qualified),
    {ok, _} = wait_event(wrapup_ended),
    {ok, #{<<"interaction_id">> := I1}} = wait_data(interaction_completed),
    {ok, #{
        <<"state">> := <<"completed">>,
        <<"qualification_ids">> := [TopicA]
    }} = cx_router:get_interaction(Integrator, I1),

    %% qualifying EARLY (while still active) lets the timer finalize
    {ok, #{<<"id">> := I2}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    {ok, #{<<"offer_id">> := Offer2}} = wait_data(offer_created),
    {ok, _} = cx_router:accept_offer(Agent, Offer2),
    ok = cx_router:qualify(Agent, I2, #{<<"qualification_ids">> => [TopicA]}),
    {ok, _} = wait_data(interaction_qualified),
    {ok, #{<<"state">> := <<"wrapup">>}} = cx_router:complete(Agent, I2),
    {ok, _} = wait_event(wrapup_ended, 2000),
    {ok, #{<<"interaction_id">> := I2}} = wait_data(interaction_completed),

    ok = cx_router:stop_session(Agent),
    ok.

%% Held interactions keep occupying capacity; hold/resume are
%% phase-guarded; complete is legal straight from held.
hold_occupies_capacity(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 0
    }),
    ProfileId = profile(Admin, #{<<"name">> => <<"one">>, <<"max_total">> => 1}),
    UserId = user(Admin, #{}, ProfileId),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),

    Integrator = integrator(T),
    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    {ok, #{<<"offer_id">> := Offer1}} = wait_data(offer_created),
    {ok, _} = cx_router:accept_offer(Agent, Offer1),

    ?assertEqual({error, not_held}, cx_router:resume(Agent, I1)),
    ok = cx_router:hold(Agent, I1),
    {ok, #{<<"interaction_id">> := I1}} = wait_data(interaction_held),
    {ok, #{<<"state">> := <<"held">>}} = cx_router:get_interaction(Agent, I1),
    ?assertEqual({error, not_active}, cx_router:hold(Agent, I1)),

    %% held still occupies the slot: nothing else is offered
    {ok, _} = cx_router:create_interaction(
        Integrator,
        #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
    ),
    ?assertEqual(timeout, wait_event(offer_created, 300)),

    ok = cx_router:resume(Agent, I1),
    {ok, #{<<"interaction_id">> := I1}} = wait_data(interaction_resumed),
    {ok, #{<<"state">> := <<"active">>}} = cx_router:get_interaction(Agent, I1),

    %% complete straight from held (caller hung up while parked)
    ok = cx_router:hold(Agent, I1),
    {ok, _} = wait_data(interaction_held),
    ok = cx_router:complete(Agent, I1),
    {ok, #{<<"interaction_id">> := I1}} = wait_data(interaction_completed),
    {ok, _} = wait_event(offer_created, 2000),
    ok.

stop_session_rules(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 0
    }),
    UserId = user(Admin, #{}, undefined),
    Agent = start_agent(T, UserId),
    %% sign-in is idempotent: a retried POST returns the live state
    {ok, #{<<"agent_id">> := UserId}} = cx_router:start_session(Agent),
    ok = cx_router:set_ready(Agent, Media, ready),

    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            integrator(T),
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    {ok, #{<<"offer_id">> := Offer1}} = wait_data(offer_created),
    {ok, _} = cx_router:accept_offer(Agent, Offer1),
    ?assertEqual({error, has_active_interactions}, cx_router:stop_session(Agent)),

    ok = cx_router:complete(Agent, I1),
    %% a retried complete finds the row already completed by this agent
    ok = cx_router:complete(Agent, I1),
    ok = cx_router:stop_session(Agent),
    ?assertEqual({error, no_session}, cx_router:set_ready(Agent, Media, ready)),
    %% sign-out is idempotent too
    ok = cx_router:stop_session(Agent),
    ok.

%% A retried accept is served from the tombstone: same interaction_id,
%% while a late reject of the same offer is a stale race (expired).
accept_retry_idempotent(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{<<"name">> => <<"q">>, <<"wrapup_duration_ms">> => 0}),
    UserId = user(Admin, #{}, undefined),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),
    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            integrator(T),
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    {ok, #{<<"offer_id">> := Offer1, <<"expires_at">> := ExpiresAt}} =
        wait_data(offer_created),
    %% a timed queue stamps a concrete ring deadline on the offer
    ?assert(is_integer(ExpiresAt)),
    {ok, #{<<"expires_at">> := ExpiresAt, <<"interaction_id">> := I1}} =
        cx_router:get_offer(Agent, Offer1),
    {ok, #{<<"interaction_id">> := I1}} = cx_router:accept_offer(Agent, Offer1),
    {ok, #{<<"interaction_id">> := I1}} = cx_router:accept_offer(Agent, Offer1),
    ?assertEqual({error, expired}, cx_router:reject_offer(Agent, Offer1)),
    %% resolved offers vanish from the read surface
    ?assertEqual({error, not_found}, cx_router:get_offer(Agent, Offer1)),
    {ok, []} = cx_router:list_offers(Agent),
    %% the accepted interaction is readable through the agent's own eyes
    {ok, #{<<"id">> := I1, <<"state">> := <<"active">>}} =
        cx_router:agent_interaction(Agent, I1),
    ?assertEqual({error, not_found}, cx_router:agent_interaction(Agent, <<"ghost">>)),
    ok = cx_router:complete(Agent, I1),
    ok.

%% Force sign-out: engaged work requeues at its original position (a
%% second agent receives it), ACW finalizes past the qualification
%% block, and the session ends.
force_sign_out_requeues(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 60000,
        <<"qualification_required">> => true
    }),
    UserA = user(Admin, #{}, undefined),
    AgentA = start_agent(T, UserA),
    ok = cx_router:set_ready(AgentA, Media, ready),

    Integrator = integrator(T),
    [I1, I2] =
        [
            begin
                {ok, #{<<"id">> := I}} =
                    cx_router:create_interaction(
                        Integrator,
                        #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
                    ),
                I
            end
         || _ <- [1, 2]
        ],
    {ok, #{<<"offer_id">> := O1, <<"interaction_id">> := I1}} =
        wait_data(offer_created),
    {ok, _} = cx_router:accept_offer(AgentA, O1),
    {ok, #{<<"offer_id">> := O2, <<"interaction_id">> := I2}} =
        wait_data(offer_created),
    {ok, _} = cx_router:accept_offer(AgentA, O2),

    %% I2 sits unqualified in ACW (would block a normal sign-out), I1
    %% is still engaged (held, to cover the held path too)
    ok = cx_router:hold(AgentA, I1),
    {ok, _} = wait_data(interaction_held),
    {ok, #{<<"state">> := <<"wrapup">>}} = cx_router:complete(AgentA, I2),
    {ok, _} = wait_event(wrapup_started),
    %% normal sign-out refuses: engaged work wins the error precedence
    %% (the unqualified-ACW refusal is covered in qualification_gate)
    ?assertEqual({error, has_active_interactions}, cx_router:stop_session(AgentA)),

    ok = cx_router:stop_session(AgentA, true),
    {ok, _} = wait_event(session_ended),
    {ok, #{<<"interaction_id">> := I1}} = wait_data(interaction_requeued, 2000),
    {ok, #{<<"interaction_id">> := I2}} = wait_data(interaction_completed),
    {ok, #{<<"state">> := <<"queued">>, <<"agent_id">> := null}} =
        cx_router:get_interaction(Integrator, I1),

    %% supervisor kick-out needs its own authority
    NoAuthority = cx_authz:ctx(T, [<<"agent:session:self">>]),
    ?assertEqual(
        {error, forbidden},
        cx_router:force_stop_session(NoAuthority, UserA)
    ),
    Supervisor = cx_authz:ctx(T, [<<"agent:session:any">>]),
    %% idempotent: A is already gone
    ok = cx_router:force_stop_session(Supervisor, UserA),

    %% a second agent receives the requeued I1
    UserB = user(Admin, #{}, undefined),
    AgentB = start_agent(T, UserB),
    ok = cx_router:set_ready(AgentB, Media, ready),
    {ok, #{<<"interaction_id">> := I1, <<"agent_id">> := UserB}} =
        wait_data(offer_created, 2000),

    %% and the supervisor can kick a LIVE session
    ok = cx_router:force_stop_session(Supervisor, UserB),
    {ok, _} = wait_event(session_ended),
    ?assertEqual({error, no_session}, cx_router:get_session(AgentB)),
    ok.

%% A configured-but-missing routing profile must refuse the session —
%% never silently fall back to unlimited capacity. The dangler is forged
%% with a direct Mnesia write because the API layer now prevents it.
dangling_profile_fails_closed(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    UserId = user(Admin, #{}, undefined),
    {ok, Rec} = cx_user:fetch(T, UserId),
    ok = mnesia:dirty_write(Rec#cx_user{routing_profile_id = <<"ghost">>}),
    ?assertEqual(
        {error, profile_missing},
        cx_router:start_session(agent_ctx(T, UserId))
    ),
    ok.

facade_permissions(_Config) ->
    T = cx_id:new(),
    NoPerms = cx_authz:ctx(T, <<"u">>, <<"s">>, []),
    ?assertEqual({error, forbidden}, cx_router:start_session(NoPerms)),
    ?assertEqual({error, forbidden}, cx_router:set_ready(NoPerms, <<"m">>, ready)),
    ?assertEqual(
        {error, forbidden},
        cx_router:create_interaction(NoPerms, #{})
    ),
    ?assertEqual({error, forbidden}, cx_router:accept_offer(NoPerms, <<"o">>)),
    ?assertEqual({error, forbidden}, cx_router:complete(NoPerms, <<"i">>)),
    ?assertEqual({error, forbidden}, cx_router:hold(NoPerms, <<"i">>)),
    ?assertEqual({error, forbidden}, cx_router:resume(NoPerms, <<"i">>)),
    ?assertEqual({error, forbidden}, cx_router:finalize_wrapup(NoPerms, <<"i">>)),
    ok.

%% ---- helpers ----

%% Every offer resolution path must release the queue's monitor on the
%% agent session — a long-lived queue must not accumulate one dangling
%% monitor per reject.
reject_releases_monitor(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{<<"name">> => <<"q">>, <<"wrapup_duration_ms">> => 0}),
    UserA = user(Admin, #{}, undefined),
    AgentA = start_agent(T, UserA),
    ok = cx_router:set_ready(AgentA, Media, ready),
    Integrator = integrator(T),
    {ok, _} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    {ok, #{<<"offer_id">> := OfferId}} = wait_data(offer_created),
    QueuePid =
        case cx_reg:whereis_name({queue, T, QueueId}) of
            P when is_pid(P) -> P
        end,
    ?assertMatch({monitors, [_]}, erlang:process_info(QueuePid, monitors)),

    %% explicit reject (the {rejected, _} call path)
    ok = cx_router:reject_offer(AgentA, OfferId),
    {ok, _} = wait_event(offer_rejected),
    _ = sys:get_state(QueuePid),
    ?assertEqual({monitors, []}, erlang:process_info(QueuePid, monitors)),

    %% reject_cast path: a second agent takes the re-offer, then stops,
    %% handing the pending offer back asynchronously
    UserB = user(Admin, #{}, undefined),
    AgentB = start_agent(T, UserB),
    ok = cx_router:set_ready(AgentB, Media, ready),
    {ok, #{<<"offer_id">> := _}} = wait_data(offer_created),
    _ = sys:get_state(QueuePid),
    ?assertMatch({monitors, [_]}, erlang:process_info(QueuePid, monitors)),
    ok = cx_router:stop_session(AgentB),
    {ok, _} = wait_event(offer_rejected),
    _ = sys:get_state(QueuePid),
    ?assertEqual({monitors, []}, erlang:process_info(QueuePid, monitors)),
    ok.

%% A routing pass offers each agent at most once (the snapshot cannot
%% see offers placed in the same pass); the accept handler wakes the
%% next pass, so a backlog drains in order — one live offer at a time.
backlog_drains_one_offer_per_pass(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{<<"name">> => <<"q">>, <<"wrapup_duration_ms">> => 0}),
    Integrator = integrator(T),
    Ids = [
        begin
            {ok, #{<<"id">> := I}} =
                cx_router:create_interaction(
                    Integrator,
                    #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
                ),
            I
        end
     || _ <- [1, 2, 3]
    ],
    %% nobody ready: the backlog just waits
    ?assertEqual(timeout, wait_event(offer_created, 300)),
    UserId = user(Admin, #{}, undefined),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),
    Drained = lists:map(
        fun(_) ->
            {ok, #{<<"offer_id">> := O, <<"interaction_id">> := I}} =
                wait_data(offer_created),
            %% at most one offer per pass — nothing else until we accept
            ?assertEqual(timeout, wait_event(offer_created, 200)),
            {ok, _} = cx_router:accept_offer(Agent, O),
            {ok, _} = wait_event(offer_accepted),
            I
        end,
        [1, 2, 3]
    ),
    ?assertEqual(Ids, Drained),
    ok.

%% offer_timeout_ms = 0 (ring forever): the queue never arms the offer
%% timer, so the offer rings until the agent answers.
infinite_ring_offer_stays_pending(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = <<"open_media">>,
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 0,
        <<"offer_timeout_ms">> => 0
    }),
    UserId = user(Admin, #{}, undefined),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),
    Integrator = integrator(T),
    {ok, #{<<"id">> := IId}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => Media}
        ),
    {ok, #{<<"offer_id">> := OfferId}} = wait_data(offer_created),
    %% no timeout fires — the offer is still pending well after any
    %% finite timer would have been noise at this scale
    ?assertEqual(timeout, wait_event(offer_timeout, 400)),
    %% ring-forever offers carry no deadline
    {ok, #{
        <<"pending_offers">> := [
            #{<<"offer_id">> := OfferId, <<"expires_at">> := null}
        ]
    }} =
        cx_router:get_session(Agent),
    {ok, [#{<<"offer_id">> := OfferId}]} = cx_router:list_offers(Agent),
    {ok, #{<<"expires_at">> := null}} = cx_router:get_offer(Agent, OfferId),
    {ok, _} = cx_router:accept_offer(Agent, OfferId),
    {ok, _} = wait_event(offer_accepted),
    ok = cx_router:complete(Agent, IId),
    ok.

admin(T) -> cx_authz:ctx(T, [<<"*">>]).

integrator(T) ->
    cx_authz:ctx(T, [
        <<"interactions:create">>,
        <<"interactions:cancel">>,
        <<"interactions:read">>
    ]).

agent_ctx(T, UserId) ->
    cx_authz:ctx(
        T,
        UserId,
        <<"sub-", UserId/binary>>,
        [
            <<"agent:session:self">>,
            <<"agent:ready:self">>,
            <<"agent:offers:self">>,
            <<"agent:interactions:self">>,
            <<"agent:wrapup:self">>,
            <<"interactions:read">>
        ]
    ).

skill(Admin, Name) ->
    {ok, #{<<"id">> := Id}} = cx_skill:create(Admin, #{<<"name">> => Name}),
    Id.

queue(Admin, Params) ->
    {ok, #{<<"id">> := Id}} = cx_queue:create(Admin, Params),
    Id.

profile(Admin, Params) ->
    {ok, #{<<"id">> := Id}} = cx_routing_profile:create(Admin, Params),
    Id.

not_ready_reason(Admin, Name) ->
    {ok, #{<<"id">> := Id}} = cx_not_ready_reason:create(Admin, #{<<"name">> => Name}),
    Id.

user(Admin, Skills, ProfileId) ->
    SkillsList = [
        #{<<"skill_id">> => S, <<"rank">> => R}
     || {S, R} <- maps:to_list(Skills)
    ],
    Base = #{
        <<"name">> => <<"Agent">>,
        <<"email">> => <<"a@x">>,
        <<"skills">> => SkillsList
    },
    Params =
        case ProfileId of
            undefined -> Base;
            _ -> Base#{<<"routing_profile_id">> => ProfileId}
        end,
    {ok, #{<<"id">> := Id}} = cx_user:create(Admin, Params),
    Id.

start_agent(T, UserId) ->
    Ctx = agent_ctx(T, UserId),
    {ok, _} = cx_router:start_session(Ctx),
    Ctx.

wait_event(Type) ->
    wait_event(Type, 2000).

wait_event(Type, Timeout) ->
    receive
        {cx_event, {_, _, _, #{type := Type}} = Payload} -> {ok, Payload}
    after Timeout -> timeout
    end.

wait_data(Type) ->
    wait_data(Type, 2000).

wait_data(Type, Timeout) ->
    case wait_event(Type, Timeout) of
        {ok, {_, _, _, #{data := Data}}} -> {ok, Data};
        timeout -> timeout
    end.

wait_until(Fun) ->
    wait_until(Fun, 200).

wait_until(_Fun, 0) ->
    error(condition_never_true);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(10),
            wait_until(Fun, N - 1)
    end.
