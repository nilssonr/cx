-module(cx_api_rest_SUITE).

%% Full-stack e2e over real HTTP: httpc client -> cowboy -> middleware ->
%% domain -> Mnesia, with real signed JWTs against a static key source.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    health_no_auth/1,
    unauthorized_paths/1,
    admin_crud_roundtrip/1,
    cross_tenant_forbidden/1,
    agent_open_media_flow/1,
    qualification_wrapup_flow/1,
    self_force_sign_out_qualification_409/1,
    read_surface_and_pagination/1,
    integrator_cancel_rules/1,
    forbidden_without_permission/1,
    presence_roundtrip/1
]).

all() ->
    [
        health_no_auth,
        unauthorized_paths,
        admin_crud_roundtrip,
        cross_tenant_forbidden,
        agent_open_media_flow,
        qualification_wrapup_flow,
        self_force_sign_out_qualification_409,
        read_surface_and_pagination,
        integrator_cancel_rules,
        forbidden_without_permission,
        presence_roundtrip
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
    ok = application:set_env(cx_api_rest, port, 0, [{persistent, true}]),
    Keypair = cx_auth_test:new_keypair(),
    ok = cx_auth_test:install(
        Keypair,
        #{platform_admin_subjects => [<<"boss">>]}
    ),
    {ok, _} = application:ensure_all_started(cx_api_rest),
    {ok, _} = application:ensure_all_started(inets),
    Port = ranch:get_port(cx_http),
    [{keypair, Keypair}, {port, Port} | Config].

end_per_suite(_Config) ->
    application:stop(cx_api_rest),
    application:stop(cx_router),
    application:stop(cx_auth),
    application:stop(cx_core),
    application:stop(mnesia),
    ok.

%% ---- cases ----

health_no_auth(Config) ->
    {200, #{<<"status">> := <<"ok">>}} = req(Config, get, "/healthz", none),
    ok.

unauthorized_paths(Config) ->
    {401, _} = req(Config, get, "/api/v1/tenants", none),
    {401, _} = req(Config, get, "/api/v1/tenants", <<"not-a-token">>),
    {401, _} = req(Config, post, "/api/v1/interactions", none, #{}),
    {401, _} = req(Config, get, "/api/v1/presence", none),
    ok.

admin_crud_roundtrip(Config) ->
    Boss = boss_token(Config, <<"bootstrap">>),
    %% bootstrap: create the tenant itself
    {200, #{<<"id">> := TenantId}} =
        req(Config, post, "/api/v1/tenants", Boss, #{<<"name">> => <<"Acme">>}),
    Admin = boss_token(Config, TenantId),
    Base = binary_to_list(<<"/api/v1/tenants/", TenantId/binary>>),

    %% skill with tenant-defined levels
    {200, #{<<"id">> := SkillId}} =
        req(
            Config,
            post,
            Base ++ "/skills",
            Admin,
            #{
                <<"name">> => <<"Permits">>,
                <<"levels">> => [
                    #{<<"rank">> => 1, <<"name">> => <<"trainee">>},
                    #{<<"rank">> => 2, <<"name">> => <<"expert">>}
                ]
            }
        ),
    %% queue, profile, reason (media types are product constants)
    {200, #{<<"id">> := QueueId}} =
        req(
            Config,
            post,
            Base ++ "/queues",
            Admin,
            #{
                <<"name">> => <<"Building permits">>,
                <<"skill_requirements">> => [
                    #{
                        <<"skill_id">> => SkillId,
                        <<"min_rank">> => 1
                    }
                ]
            }
        ),
    {200, #{<<"id">> := ProfileId, <<"max_total">> := 5}} =
        req(
            Config,
            post,
            Base ++ "/routing-profiles",
            Admin,
            #{<<"name">> => <<"Default">>, <<"max_total">> => 5}
        ),
    {200, #{<<"id">> := _ReasonId}} =
        req(
            Config,
            post,
            Base ++ "/not-ready-reasons",
            Admin,
            #{<<"name">> => <<"Lunch">>}
        ),

    %% update + get + list + delete round trip on the queue
    {200, #{<<"wrapup_duration_ms">> := 5000}} =
        req(
            Config,
            put,
            Base ++ "/queues/" ++ binary_to_list(QueueId),
            Admin,
            #{<<"wrapup_duration_ms">> => 5000}
        ),
    {200, #{<<"name">> := <<"Building permits">>}} =
        req(Config, get, Base ++ "/queues/" ++ binary_to_list(QueueId), Admin),
    {200, [_]} = req(Config, get, Base ++ "/queues", Admin),

    %% user wiring: role -> user with skills + profile
    {200, #{<<"id">> := RoleId}} =
        req(
            Config,
            post,
            Base ++ "/roles",
            Admin,
            #{
                <<"name">> => <<"Agent">>,
                <<"permissions">> => [<<"agent:session:self">>]
            }
        ),
    {200, #{<<"id">> := UserId, <<"skills">> := SkillsOut}} =
        req(
            Config,
            post,
            Base ++ "/users",
            Admin,
            #{
                <<"name">> => <<"Robin">>,
                <<"email">> => <<"r@x.dev">>,
                <<"subject">> => <<"crud-agent">>,
                <<"role_ids">> => [RoleId],
                <<"skills">> => [#{<<"skill_id">> => SkillId, <<"rank">> => 2}],
                <<"routing_profile_id">> => ProfileId
            }
        ),
    [#{<<"skill_id">> := SkillId, <<"rank">> := 2}] = SkillsOut,
    %% escalation guard over the wire: the wildcard and platform-only
    %% perms are not tenant-assignable
    {422, #{<<"error">> := <<"invalid:permissions">>}} =
        req(
            Config,
            post,
            Base ++ "/roles",
            Admin,
            #{<<"name">> => <<"Escalate">>, <<"permissions">> => [<<"*">>]}
        ),
    {422, #{<<"error">> := <<"invalid:permissions">>}} =
        req(
            Config,
            post,
            Base ++ "/roles",
            Admin,
            #{
                <<"name">> => <<"Escalate">>,
                <<"permissions">> => [<<"tenants:admin">>]
            }
        ),
    {422, #{<<"error">> := <<"invalid:levels">>}} =
        req(
            Config,
            post,
            Base ++ "/skills",
            Admin,
            #{
                <<"name">> => <<"bad">>,
                <<"levels">> => [#{<<"rank">> => 0, <<"name">> => <<"x">>}]
            }
        ),
    %% referential integrity over the wire: unknown skill on a user is
    %% 422; deleting a referenced skill/profile/role is 409
    {422, #{<<"error">> := <<"invalid:skills">>}} =
        req(
            Config,
            post,
            Base ++ "/users",
            Admin,
            #{
                <<"name">> => <<"G">>,
                <<"email">> => <<"g@x">>,
                <<"skills">> => [#{<<"skill_id">> => <<"ghost">>, <<"rank">> => 1}]
            }
        ),
    {409, #{<<"error">> := <<"in_use">>}} =
        req(Config, delete, Base ++ "/skills/" ++ binary_to_list(SkillId), Admin),
    {409, #{<<"error">> := <<"in_use">>}} =
        req(
            Config,
            delete,
            Base ++ "/routing-profiles/" ++ binary_to_list(ProfileId),
            Admin
        ),
    {409, #{<<"error">> := <<"in_use">>}} =
        req(Config, delete, Base ++ "/roles/" ++ binary_to_list(RoleId), Admin),
    %% dropping the user is not enough — the queue's skill_requirements still
    %% hold the skill, so it stays blocked
    {204, _} = req(Config, delete, Base ++ "/users/" ++ binary_to_list(UserId), Admin),
    {409, #{<<"error">> := <<"in_use">>}} =
        req(Config, delete, Base ++ "/skills/" ++ binary_to_list(SkillId), Admin),
    {404, _} = req(Config, delete, Base ++ "/not-ready-reasons/x", Admin),
    ok.

cross_tenant_forbidden(Config) ->
    Boss = boss_token(Config, <<"bootstrap">>),
    {200, #{<<"id">> := T1}} =
        req(Config, post, "/api/v1/tenants", Boss, #{<<"name">> => <<"One">>}),
    {200, #{<<"id">> := T2}} =
        req(Config, post, "/api/v1/tenants", Boss, #{<<"name">> => <<"Two">>}),

    %% a T2-scoped user token must not touch T1's config
    AdminT2 = user_token(Config, T2, <<"t2-admin">>, [
        <<"queues:read">>,
        <<"queues:write">>
    ]),
    Base1 = binary_to_list(<<"/api/v1/tenants/", T1/binary>>),
    {403, _} = req(Config, get, Base1 ++ "/queues", AdminT2),
    {403, _} = req(
        Config,
        post,
        Base1 ++ "/queues",
        AdminT2,
        #{<<"name">> => <<"sneaky">>}
    ),
    ok.

agent_open_media_flow(Config) ->
    Boss = boss_token(Config, <<"bootstrap">>),
    {200, #{<<"id">> := TenantId}} =
        req(Config, post, "/api/v1/tenants", Boss, #{<<"name">> => <<"Flow">>}),
    Admin = boss_token(Config, TenantId),
    Base = binary_to_list(<<"/api/v1/tenants/", TenantId/binary>>),

    MediaId = <<"open_media">>,
    {200, #{<<"id">> := QueueId}} =
        req(
            Config,
            post,
            Base ++ "/queues",
            Admin,
            #{<<"name">> => <<"q">>, <<"wrapup_duration_ms">> => 0}
        ),
    Agent = user_token(
        Config,
        TenantId,
        <<"flow-agent">>,
        [
            <<"agent:session:self">>,
            <<"agent:ready:self">>,
            <<"agent:offers:self">>,
            <<"agent:interactions:self">>,
            <<"agent:wrapup:self">>
        ]
    ),
    Integrator = user_token(
        Config,
        TenantId,
        <<"flow-integrator">>,
        [
            <<"interactions:create">>,
            <<"interactions:cancel">>,
            <<"interactions:read">>
        ]
    ),

    %% agent signs in and goes ready for open media; a retried sign-in
    %% is idempotent (200 + current state, not 409)
    {200, #{<<"agent_id">> := _}} =
        req(Config, post, "/api/v1/agent/session", Agent, #{}),
    {200, #{<<"agent_id">> := _, <<"ready">> := _}} =
        req(Config, post, "/api/v1/agent/session", Agent, #{}),
    {204, _} = req(
        Config,
        put,
        "/api/v1/agent/media/" ++ binary_to_list(MediaId) ++ "/state",
        Agent,
        #{<<"state">> => <<"ready">>}
    ),

    %% integrator: "put this request on this queue"
    {200, #{<<"id">> := IId}} =
        req(
            Config,
            post,
            "/api/v1/interactions",
            Integrator,
            #{
                <<"queue_id">> => QueueId,
                <<"media_type">> => MediaId,
                <<"properties">> => #{<<"sap_case">> => <<"0815">>}
            }
        ),

    %% the offer shows up on the agent session (the WS transport pushes
    %% it too; polling the session stays a supported REST pattern)
    {ok, OfferId} = poll_offer(Config, Agent),
    {200, #{<<"interaction_id">> := IId}} = req(
        Config,
        post,
        "/api/v1/agent/offers/" ++ binary_to_list(OfferId) ++ "/accept",
        Agent,
        #{}
    ),
    {200, #{
        <<"state">> := <<"active">>,
        <<"properties">> := #{<<"sap_case">> := <<"0815">>}
    }} =
        req(
            Config,
            get,
            "/api/v1/interactions/" ++ binary_to_list(IId),
            Integrator
        ),

    {204, _} = req(
        Config,
        post,
        "/api/v1/agent/interactions/" ++ binary_to_list(IId) ++
            "/complete",
        Agent,
        #{}
    ),
    {200, #{<<"state">> := <<"completed">>}} =
        req(
            Config,
            get,
            "/api/v1/interactions/" ++ binary_to_list(IId),
            Integrator
        ),
    {204, _} = req(Config, delete, "/api/v1/agent/session", Agent),
    %% sign-out is idempotent
    {204, _} = req(Config, delete, "/api/v1/agent/session", Agent),
    ok.

%% Qualification codes over HTTP: tenant CRUD of the tree, then the
%% agent-side hard block — DELETE wrapup 409s until codes are PUT.
qualification_wrapup_flow(Config) ->
    Boss = boss_token(Config, <<"bootstrap">>),
    {200, #{<<"id">> := TenantId}} =
        req(Config, post, "/api/v1/tenants", Boss, #{<<"name">> => <<"Qual">>}),
    Admin = boss_token(Config, TenantId),
    Base = binary_to_list(<<"/api/v1/tenants/", TenantId/binary>>),

    %% tree CRUD via the generic handler
    {200, #{<<"id">> := TopicA, <<"parent_id">> := null}} =
        req(Config, post, Base ++ "/qualification-codes", Admin, #{
            <<"name">> => <<"Topic A">>
        }),
    {200, #{<<"id">> := TopicA1}} =
        req(Config, post, Base ++ "/qualification-codes", Admin, #{
            <<"name">> => <<"Topic A.1">>,
            <<"parent_id">> => TopicA
        }),
    {200, Codes} = req(Config, get, Base ++ "/qualification-codes", Admin),
    ?assertEqual(2, length(Codes)),
    {409, #{<<"error">> := <<"in_use">>}} =
        req(Config, delete, Base ++ "/qualification-codes/" ++ binary_to_list(TopicA), Admin),

    {200, #{<<"id">> := QueueId}} =
        req(Config, post, Base ++ "/queues", Admin, #{
            <<"name">> => <<"q">>,
            <<"wrapup_duration_ms">> => 60000,
            <<"qualification_required">> => true
        }),
    Agent = user_token(Config, TenantId, <<"qual-agent">>, [
        <<"agent:session:self">>,
        <<"agent:ready:self">>,
        <<"agent:offers:self">>,
        <<"agent:interactions:self">>,
        <<"agent:wrapup:self">>
    ]),
    Integrator = user_token(Config, TenantId, <<"qual-integrator">>, [
        <<"interactions:create">>,
        <<"interactions:read">>
    ]),

    {200, #{<<"agent_id">> := AgentUid}} =
        req(Config, post, "/api/v1/agent/session", Agent, #{}),
    {204, _} = req(
        Config,
        put,
        "/api/v1/agent/media/open_media/state",
        Agent,
        #{<<"state">> => <<"ready">>}
    ),
    {200, #{<<"id">> := IId}} =
        req(Config, post, "/api/v1/interactions", Integrator, #{
            <<"queue_id">> => QueueId,
            <<"media_type">> => <<"open_media">>
        }),
    {ok, OfferId} = poll_offer(Config, Agent),
    {200, #{<<"interaction_id">> := IId}} = req(
        Config,
        post,
        "/api/v1/agent/offers/" ++ binary_to_list(OfferId) ++ "/accept",
        Agent,
        #{}
    ),
    IPath = "/api/v1/agent/interactions/" ++ binary_to_list(IId),

    %% hold/resume ride along over HTTP
    {204, _} = req(Config, post, IPath ++ "/hold", Agent, #{}),
    {409, #{<<"error">> := <<"not_active">>}} =
        req(Config, post, IPath ++ "/hold", Agent, #{}),
    {204, _} = req(Config, post, IPath ++ "/resume", Agent, #{}),

    {200, #{<<"state">> := <<"wrapup">>, <<"wrapup_until">> := _}} =
        req(Config, post, IPath ++ "/complete", Agent, #{}),

    %% finalize is blocked until codes are entered
    {409, #{<<"error">> := <<"qualification_required">>}} =
        req(Config, post, IPath ++ "/wrapup/finalize", Agent, #{}),
    {422, _} =
        req(Config, put, IPath ++ "/qualifications", Agent, #{
            <<"qualification_ids">> => [<<"ghost">>]
        }),
    {204, _} =
        req(Config, put, IPath ++ "/qualifications", Agent, #{
            <<"qualification_ids">> => [TopicA1]
        }),
    {204, _} = req(Config, post, IPath ++ "/wrapup/finalize", Agent, #{}),

    {200, #{
        <<"state">> := <<"completed">>,
        <<"qualification_ids">> := [TopicA1]
    }} =
        req(
            Config,
            get,
            "/api/v1/interactions/" ++ binary_to_list(IId),
            Integrator
        ),
    {204, _} = req(Config, delete, "/api/v1/agent/session", Agent),

    %% supervisor force sign-out route: idempotent even when the target
    %% is already gone; a plain agent token lacks agent:session:any
    KickPath =
        Base ++ "/users/" ++ binary_to_list(AgentUid) ++ "/agent-session",
    {403, _} = req(Config, delete, KickPath, Agent),
    {204, _} = req(Config, delete, KickPath, Admin),
    ok.

%% ?force=true is no loophole around mandatory codes: self-force is
%% refused while unqualified required wrap-up work exists; only the
%% supervisor authority (agent:session:any) overrides the gate.
self_force_sign_out_qualification_409(Config) ->
    Boss = boss_token(Config, <<"bootstrap">>),
    {200, #{<<"id">> := TenantId}} =
        req(Config, post, "/api/v1/tenants", Boss, #{<<"name">> => <<"Force">>}),
    Admin = boss_token(Config, TenantId),
    Base = binary_to_list(<<"/api/v1/tenants/", TenantId/binary>>),
    {200, #{<<"id">> := QueueId}} =
        req(Config, post, Base ++ "/queues", Admin, #{
            <<"name">> => <<"q">>,
            <<"wrapup_duration_ms">> => 60000,
            <<"qualification_required">> => true
        }),
    Agent = user_token(Config, TenantId, <<"force-agent">>, [
        <<"agent:session:self">>,
        <<"agent:ready:self">>,
        <<"agent:offers:self">>,
        <<"agent:interactions:self">>
    ]),
    Integrator = user_token(Config, TenantId, <<"force-integrator">>, [
        <<"interactions:create">>
    ]),
    {200, #{<<"agent_id">> := AgentUid}} =
        req(Config, post, "/api/v1/agent/session", Agent, #{}),
    {204, _} = req(
        Config,
        put,
        "/api/v1/agent/media/open_media/state",
        Agent,
        #{<<"state">> => <<"ready">>}
    ),
    {200, #{<<"id">> := IId}} =
        req(Config, post, "/api/v1/interactions", Integrator, #{
            <<"queue_id">> => QueueId,
            <<"media_type">> => <<"open_media">>
        }),
    {ok, OfferId} = poll_offer(Config, Agent),
    {200, _} = req(
        Config,
        post,
        "/api/v1/agent/offers/" ++ binary_to_list(OfferId) ++ "/accept",
        Agent,
        #{}
    ),
    {200, #{<<"state">> := <<"wrapup">>}} =
        req(
            Config,
            post,
            "/api/v1/agent/interactions/" ++ binary_to_list(IId) ++ "/complete",
            Agent,
            #{}
        ),

    %% unqualified ACW blocks both plain and forced self sign-out
    {409, #{<<"error">> := <<"qualification_required">>}} =
        req(Config, delete, "/api/v1/agent/session", Agent),
    {409, #{<<"error">> := <<"qualification_required">>}} =
        req(Config, delete, "/api/v1/agent/session?force=true", Agent),

    %% the supervisor authority overrides the gate on a live session
    KickPath =
        Base ++ "/users/" ++ binary_to_list(AgentUid) ++ "/agent-session",
    {204, _} = req(Config, delete, KickPath, Admin),
    ok.

%% The read surface: tenant-wide filtered list with cursor pagination,
%% the agent's own detailed list, and the structured ready map.
read_surface_and_pagination(Config) ->
    Boss = boss_token(Config, <<"bootstrap">>),
    {200, #{<<"id">> := TenantId}} =
        req(Config, post, "/api/v1/tenants", Boss, #{<<"name">> => <<"Reads">>}),
    Admin = boss_token(Config, TenantId),
    Base = binary_to_list(<<"/api/v1/tenants/", TenantId/binary>>),
    {200, #{<<"id">> := QueueId}} =
        req(Config, post, Base ++ "/queues", Admin, #{
            <<"name">> => <<"q">>,
            <<"wrapup_duration_ms">> => 0
        }),
    {200, #{<<"id">> := ReasonId}} =
        req(Config, post, Base ++ "/not-ready-reasons", Admin, #{
            <<"name">> => <<"Lunch">>
        }),
    Integrator = user_token(Config, TenantId, <<"reads-integrator">>, [
        <<"interactions:create">>,
        <<"interactions:read">>
    ]),
    Agent = user_token(Config, TenantId, <<"reads-agent">>, [
        <<"agent:session:self">>,
        <<"agent:ready:self">>,
        <<"agent:offers:self">>,
        <<"agent:interactions:self">>
    ]),

    Ids = [
        begin
            {200, #{<<"id">> := I}} =
                req(Config, post, "/api/v1/interactions", Integrator, #{
                    <<"queue_id">> => QueueId,
                    <<"media_type">> => <<"open_media">>
                }),
            I
        end
     || _ <- [1, 2, 3]
    ],

    %% filters + validation
    {200, #{<<"items">> := All, <<"next">> := null}} =
        req(Config, get, "/api/v1/interactions?state=queued", Integrator),
    ?assertEqual(lists:sort(Ids), lists:sort([maps:get(<<"id">>, I) || I <- All])),
    {200, #{<<"items">> := []}} =
        req(Config, get, "/api/v1/interactions?state=completed", Integrator),
    {422, _} = req(Config, get, "/api/v1/interactions?state=bogus", Integrator),
    {422, _} = req(Config, get, "/api/v1/interactions?limit=0", Integrator),

    %% cursor walk: 2 + 1, newest first, no overlap
    {200, #{<<"items">> := [P1a, P1b], <<"next">> := Cursor}} =
        req(Config, get, "/api/v1/interactions?limit=2", Integrator),
    ?assert(is_binary(Cursor)),
    {200, #{<<"items">> := [P2a]}} =
        req(
            Config,
            get,
            "/api/v1/interactions?limit=2&after=" ++ binary_to_list(Cursor),
            Integrator
        ),
    PageIds = [maps:get(<<"id">>, I) || I <- [P1a, P1b, P2a]],
    ?assertEqual(lists:sort(Ids), lists:sort(PageIds)),

    %% the agent's own list rehydrates detail; ready map is structured
    {200, _} = req(Config, post, "/api/v1/agent/session", Agent, #{}),
    {204, _} = req(Config, put, "/api/v1/agent/media/open_media/state", Agent, #{
        <<"state">> => <<"not_ready">>,
        <<"reason_id">> => ReasonId
    }),
    {200, #{
        <<"ready">> := #{
            <<"open_media">> := #{
                <<"state">> := <<"not_ready">>,
                <<"reason_id">> := ReasonId
            }
        }
    }} =
        req(Config, get, "/api/v1/agent/session", Agent),
    {200, []} = req(Config, get, "/api/v1/agent/interactions", Agent),
    %% a reason on "ready" is a client bug, not something to drop silently
    {422, #{<<"error">> := <<"invalid:reason_id">>}} =
        req(Config, put, "/api/v1/agent/media/open_media/state", Agent, #{
            <<"state">> => <<"ready">>,
            <<"reason_id">> => ReasonId
        }),
    {204, _} = req(Config, put, "/api/v1/agent/media/open_media/state", Agent, #{
        <<"state">> => <<"ready">>
    }),
    {ok, OfferId} = poll_offer(Config, Agent),

    %% offers have a snapshot read surface: list + single, with the
    %% queue-computed ring deadline (default timeout -> integer)
    {200, [
        #{
            <<"offer_id">> := OfferId,
            <<"interaction_id">> := _,
            <<"queue_id">> := QueueId,
            <<"expires_at">> := ExpiresAt
        }
    ]} =
        req(Config, get, "/api/v1/agent/offers", Agent),
    ?assert(is_integer(ExpiresAt)),
    {200, #{<<"offer_id">> := OfferId}} =
        req(Config, get, "/api/v1/agent/offers/" ++ binary_to_list(OfferId), Agent),
    {404, _} = req(Config, get, "/api/v1/agent/offers/ghost", Agent),

    {200, #{<<"interaction_id">> := Mine}} =
        req(
            Config,
            post,
            "/api/v1/agent/offers/" ++ binary_to_list(OfferId) ++ "/accept",
            Agent,
            #{}
        ),
    %% a resolved offer is gone — an attempt, not a durable resource
    %% (the unlimited agent gets offered the NEXT queued interaction
    %% immediately, so the list isn't empty; the resolved id is absent)
    {200, OffersAfter} = req(Config, get, "/api/v1/agent/offers", Agent),
    ?assertNot(
        lists:any(
            fun(#{<<"offer_id">> := O}) -> O =:= OfferId end,
            OffersAfter
        )
    ),
    {404, _} = req(
        Config,
        get,
        "/api/v1/agent/offers/" ++ binary_to_list(OfferId),
        Agent
    ),

    {200, [#{<<"id">> := Mine, <<"state">> := <<"active">>, <<"queue_id">> := QueueId}]} =
        req(Config, get, "/api/v1/agent/interactions", Agent),
    %% single own-interaction view, 404 for anything not currently owned
    {200, #{<<"id">> := Mine, <<"state">> := <<"active">>}} =
        req(
            Config,
            get,
            "/api/v1/agent/interactions/" ++ binary_to_list(Mine),
            Agent
        ),
    [NotMine | _] = [I || I <- Ids, I =/= Mine],
    {404, _} = req(
        Config,
        get,
        "/api/v1/agent/interactions/" ++ binary_to_list(NotMine),
        Agent
    ),
    ok.

integrator_cancel_rules(Config) ->
    Boss = boss_token(Config, <<"bootstrap">>),
    {200, #{<<"id">> := TenantId}} =
        req(Config, post, "/api/v1/tenants", Boss, #{<<"name">> => <<"C">>}),
    Admin = boss_token(Config, TenantId),
    Base = binary_to_list(<<"/api/v1/tenants/", TenantId/binary>>),
    MediaId = <<"open_media">>,
    {200, #{<<"id">> := QueueId}} =
        req(Config, post, Base ++ "/queues", Admin, #{<<"name">> => <<"q">>}),
    Integrator = user_token(
        Config,
        TenantId,
        <<"c-int">>,
        [
            <<"interactions:create">>,
            <<"interactions:cancel">>,
            <<"interactions:read">>
        ]
    ),

    {200, #{<<"id">> := IId}} =
        req(
            Config,
            post,
            "/api/v1/interactions",
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => MediaId}
        ),
    Path = "/api/v1/interactions/" ++ binary_to_list(IId),
    %% cancel is a state transition, not a resource removal: POST verb,
    %% and the row remains readable as `cancelled`
    {204, _} = req(Config, post, Path ++ "/cancel", Integrator, #{}),
    {200, #{<<"state">> := <<"cancelled">>}} = req(Config, get, Path, Integrator),
    {409, #{<<"error">> := <<"not_cancellable">>}} =
        req(Config, post, Path ++ "/cancel", Integrator, #{}),
    %% the old DELETE is gone
    {405, _} = req(Config, delete, Path, Integrator),

    %% unknown queue -> 404, closed queue -> 409
    {404, _} = req(
        Config,
        post,
        "/api/v1/interactions",
        Integrator,
        #{
            <<"queue_id">> => <<"nope">>,
            <<"media_type">> => MediaId
        }
    ),
    {200, _} = req(
        Config,
        put,
        Base ++ "/queues/" ++ binary_to_list(QueueId),
        Admin,
        #{<<"status">> => <<"closed">>}
    ),
    {409, #{<<"error">> := <<"queue_closed">>}} =
        req(
            Config,
            post,
            "/api/v1/interactions",
            Integrator,
            #{<<"queue_id">> => QueueId, <<"media_type">> => MediaId}
        ),
    ok.

forbidden_without_permission(Config) ->
    Boss = boss_token(Config, <<"bootstrap">>),
    {200, #{<<"id">> := TenantId}} =
        req(Config, post, "/api/v1/tenants", Boss, #{<<"name">> => <<"F">>}),
    Nobody = user_token(Config, TenantId, <<"nobody">>, []),
    Base = binary_to_list(<<"/api/v1/tenants/", TenantId/binary>>),
    {403, _} = req(
        Config,
        post,
        Base ++ "/queues",
        Nobody,
        #{<<"name">> => <<"q">>}
    ),
    {403, _} = req(Config, get, Base ++ "/users", Nobody),
    {403, _} = req(
        Config,
        post,
        "/api/v1/interactions",
        Nobody,
        #{<<"queue_id">> => <<"q">>, <<"media_type">> => <<"m">>}
    ),
    {403, _} = req(Config, post, "/api/v1/agent/session", Nobody, #{}),
    {403, _} = req(Config, put, "/api/v1/presence", Nobody, #{<<"state">> => <<"busy">>}),
    ok.

%% ---- helpers ----

boss_token(Config, TenantId) ->
    Keypair = proplists:get_value(keypair, Config),
    cx_auth_test:token(Keypair, #{
        <<"sub">> => <<"boss">>,
        <<"urn:zitadel:iam:org:id">> => TenantId
    }).

%% Creates a user with a role carrying Perms (via a boss token), then
%% mints a token for that user's subject.
user_token(Config, TenantId, Subject, Perms) ->
    Admin = boss_token(Config, TenantId),
    Base = binary_to_list(<<"/api/v1/tenants/", TenantId/binary>>),
    {200, #{<<"id">> := RoleId}} =
        req(
            Config,
            post,
            Base ++ "/roles",
            Admin,
            #{
                <<"name">> => <<"role-", Subject/binary>>,
                <<"permissions">> => Perms
            }
        ),
    {200, #{<<"id">> := _}} =
        req(
            Config,
            post,
            Base ++ "/users",
            Admin,
            #{
                <<"name">> => Subject,
                <<"email">> => <<Subject/binary, "@x">>,
                <<"subject">> => Subject,
                <<"role_ids">> => [RoleId]
            }
        ),
    Keypair = proplists:get_value(keypair, Config),
    cx_auth_test:token(Keypair, #{
        <<"sub">> => Subject,
        <<"urn:zitadel:iam:org:id">> => TenantId
    }).

poll_offer(Config, Agent) ->
    poll_offer(Config, Agent, 100).

poll_offer(_Config, _Agent, 0) ->
    {error, no_offer};
poll_offer(Config, Agent, N) ->
    case req(Config, get, "/api/v1/agent/session", Agent) of
        {200, #{<<"pending_offers">> := [#{<<"offer_id">> := OfferId} | _]}} ->
            {ok, OfferId};
        {200, _} ->
            timer:sleep(20),
            poll_offer(Config, Agent, N - 1)
    end.

req(Config, Method, Path, Token) ->
    req(Config, Method, Path, Token, none).

req(Config, Method, Path, Token, Body) ->
    req(Config, Method, Path, Token, Body, []).

req(Config, Method, Path, Token, Body, _Opts) ->
    Port = proplists:get_value(port, Config),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
    Headers =
        case Token of
            none -> [];
            _ -> [{"authorization", "Bearer " ++ binary_to_list(Token)}]
        end,
    Request =
        case Body of
            none -> {Url, Headers};
            _ -> {Url, Headers, "application/json", cx_json:encode(Body)}
        end,
    {ok, {{_, Status, _}, _, RespBody}} =
        httpc:request(
            Method,
            Request,
            [{timeout, 15000}],
            [{body_format, binary}]
        ),
    Decoded =
        case cx_json:decode(RespBody) of
            {ok, Map} -> Map;
            {error, _} -> RespBody
        end,
    {Status, Decoded}.

presence_roundtrip(Config) ->
    Boss = boss_token(Config, <<"bootstrap">>),
    {200, #{<<"id">> := TenantId}} =
        req(Config, post, "/api/v1/tenants", Boss, #{<<"name">> => <<"P">>}),
    User = user_token(Config, TenantId, <<"presence-user">>, [<<"presence:set:self">>]),
    {200, #{
        <<"state">> := <<"offline">>,
        <<"manual_state">> := <<"busy">>,
        <<"message">> := <<"In Spain for two weeks">>
    }} =
        req(Config, put, "/api/v1/presence", User, #{
            <<"state">> => <<"busy">>,
            <<"message">> => <<"In Spain for two weeks">>
        }),
    {200, #{<<"manual_state">> := <<"busy">>, <<"device_count">> := 0}} =
        req(Config, get, "/api/v1/presence", User),
    {422, #{<<"error">> := <<"invalid:state">>}} =
        req(Config, put, "/api/v1/presence", User, #{<<"state">> => <<"invisible">>}),
    {200, Entries} = req(Config, get, "/api/v1/presence/directory", User),
    ?assert(
        lists:any(
            fun(#{<<"message">> := M}) -> M =:= <<"In Spain for two weeks">> end,
            Entries
        )
    ),
    ok.
