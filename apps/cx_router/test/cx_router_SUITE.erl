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
    wrapup_extend_cancel/1,
    stop_session_rules/1,
    facade_permissions/1
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
        wrapup_extend_cancel,
        stop_session_rules,
        facade_permissions
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
    Media = media(Admin, <<"open_media">>),
    QueueId = queue(Admin, #{
        <<"name">> => <<"Building permits">>,
        <<"wrapup_duration_ms">> => 700
    }),
    UserId = user(Admin, #{}, undefined),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),

    Integrator = integrator(T),
    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            Integrator,
            #{
                <<"queue_id">> => QueueId,
                <<"media_type_id">> => Media,
                <<"properties">> => #{
                    <<"case">> => <<"42">>,
                    <<"source">> => <<"sap">>
                }
            }
        ),
    {ok, _} = wait_event(interaction_queued),
    {ok, #{<<"offer_id">> := OfferId, <<"interaction_id">> := I1}} =
        wait_data(offer_created),

    ok = cx_router:accept_offer(Agent, OfferId),
    {ok, _} = wait_event(offer_accepted),
    {ok, #{
        <<"state">> := <<"active">>,
        <<"properties">> := #{<<"case">> := <<"42">>}
    }} =
        cx_router:get_interaction(Integrator, I1),

    ok = cx_router:complete(Agent, I1),
    {ok, _} = wait_event(interaction_completed),
    {ok, _} = wait_event(wrapup_started),
    {ok, #{<<"state">> := <<"completed">>}} =
        cx_router:get_interaction(Integrator, I1),

    %% wrap-up blocks new offers until it expires
    {ok, #{<<"id">> := _I2}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type_id">> => Media}
        ),
    ?assertEqual(timeout, wait_event(offer_created, 300)),
    {ok, _} = wait_event(wrapup_ended, 2000),
    {ok, _} = wait_event(offer_created, 2000),
    ok.

multi_concurrent_offers(_Config) ->
    %% no profile => nothing is limited; one agent takes three at once
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = media(Admin, <<"open_media">>),
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
                        <<"media_type_id">> => Media
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
    [ok = cx_router:accept_offer(Agent, O) || O <- Offers],
    {ok, #{<<"active">> := Active}} = cx_router:get_session(Agent),
    ?assertEqual(lists:sort(Ids), lists:sort(Active)),
    ok.

reject_requeues_in_order(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = media(Admin, <<"open_media">>),
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
                            <<"media_type_id">> => Media
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
    Media = media(Admin, <<"open_media">>),
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
            #{<<"queue_id">> => QueueId, <<"media_type_id">> => Media}
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
    Media = media(Admin, <<"open_media">>),
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
        #{<<"queue_id">> => QueueId, <<"media_type_id">> => Media}
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
    Voice = media(Admin, <<"voice">>),
    Om = media(Admin, <<"open_media">>),
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
            #{<<"queue_id">> => QueueId, <<"media_type_id">> => Voice}
        ),
    {ok, #{<<"offer_id">> := VOffer}} = wait_data(offer_created),
    ok = cx_router:accept_offer(Agent, VOffer),
    {ok, _} = wait_event(offer_accepted),

    {ok, #{<<"id">> := _IOm}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type_id">> => Om}
        ),
    ?assertEqual(timeout, wait_event(offer_created, 300)),

    ok = cx_router:complete(Agent, IVoice),
    {ok, #{<<"interaction_id">> := _}} = wait_data(offer_created, 2000),
    ok.

not_ready_mid_offer(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = media(Admin, <<"open_media">>),
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
            #{<<"queue_id">> => QueueId, <<"media_type_id">> => Media}
        ),
    {ok, #{<<"offer_id">> := Offer1}} = wait_data(offer_created),

    %% going not-ready blocks NEW offers but leaves the pending one valid
    ok = cx_router:set_ready(Agent, Media, {not_ready, ReasonId}),
    {ok, #{<<"id">> := _I2}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type_id">> => Media}
        ),
    ?assertEqual(timeout, wait_event(offer_created, 300)),

    ok = cx_router:accept_offer(Agent, Offer1),
    {ok, #{<<"state">> := <<"active">>}} =
        cx_router:get_interaction(Integrator, I1),
    ok.

agent_crash_requeues(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = media(Admin, <<"open_media">>),
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
            #{<<"queue_id">> => QueueId, <<"media_type_id">> => Media}
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
    Media = media(Admin, <<"open_media">>),
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
                            <<"media_type_id">> => Media
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
    Media = media(Admin, <<"open_media">>),
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 0
    }),
    Integrator = integrator(T),

    %% queued -> cancellable
    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type_id">> => Media}
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
            #{<<"queue_id">> => QueueId, <<"media_type_id">> => Media}
        ),
    {ok, _} = wait_event(offer_created),
    ?assertEqual(
        {error, not_cancellable},
        cx_router:cancel_interaction(Integrator, I2)
    ),
    ok.

wrapup_extend_cancel(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = media(Admin, <<"open_media">>),
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 60000
    }),
    UserId = user(Admin, #{}, undefined),
    Agent = start_agent(T, UserId),
    ok = cx_router:set_ready(Agent, Media, ready),

    ?assertEqual({error, not_in_wrapup}, cx_router:extend_wrapup(Agent, 1000)),
    ?assertEqual({error, not_in_wrapup}, cx_router:cancel_wrapup(Agent)),

    Integrator = integrator(T),
    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type_id">> => Media}
        ),
    {ok, #{<<"offer_id">> := Offer1}} = wait_data(offer_created),
    ok = cx_router:accept_offer(Agent, Offer1),
    ok = cx_router:complete(Agent, I1),
    {ok, _} = wait_event(wrapup_started),

    ok = cx_router:extend_wrapup(Agent, 60000),
    {ok, _} = wait_event(wrapup_extended),

    %% no offers while wrapped up
    {ok, _} = cx_router:create_interaction(
        Integrator,
        #{<<"queue_id">> => QueueId, <<"media_type_id">> => Media}
    ),
    ?assertEqual(timeout, wait_event(offer_created, 300)),

    ok = cx_router:cancel_wrapup(Agent),
    {ok, _} = wait_event(wrapup_cancelled),
    {ok, _} = wait_event(offer_created, 2000),
    ok.

stop_session_rules(_Config) ->
    T = cx_id:new(),
    Admin = admin(T),
    ok = cx_event:subscribe(T),
    Media = media(Admin, <<"open_media">>),
    QueueId = queue(Admin, #{
        <<"name">> => <<"q">>,
        <<"wrapup_duration_ms">> => 0
    }),
    UserId = user(Admin, #{}, undefined),
    Agent = start_agent(T, UserId),
    ?assertEqual({error, already_started}, cx_router:start_session(Agent)),
    ok = cx_router:set_ready(Agent, Media, ready),

    {ok, #{<<"id">> := I1}} =
        cx_router:create_interaction(
            integrator(T),
            #{<<"queue_id">> => QueueId, <<"media_type_id">> => Media}
        ),
    {ok, #{<<"offer_id">> := Offer1}} = wait_data(offer_created),
    ok = cx_router:accept_offer(Agent, Offer1),
    ?assertEqual({error, has_active_interactions}, cx_router:stop_session(Agent)),

    ok = cx_router:complete(Agent, I1),
    ok = cx_router:stop_session(Agent),
    ?assertEqual({error, no_session}, cx_router:set_ready(Agent, Media, ready)),
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
    ?assertEqual({error, forbidden}, cx_router:cancel_wrapup(NoPerms)),
    ok.

%% ---- helpers ----

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
            <<"agent:wrapup:self">>,
            <<"interactions:read">>
        ]
    ).

media(Admin, Name) ->
    {ok, #{<<"id">> := Id}} = cx_media_type:create(Admin, #{<<"name">> => Name}),
    Id.

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
    Base = #{
        <<"name">> => <<"Agent">>,
        <<"email">> => <<"a@x">>,
        <<"skills">> => Skills
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
