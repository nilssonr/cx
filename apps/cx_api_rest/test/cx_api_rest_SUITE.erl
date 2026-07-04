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
    integrator_cancel_rules/1,
    forbidden_without_permission/1
]).

all() ->
    [
        health_no_auth,
        unauthorized_paths,
        admin_crud_roundtrip,
        cross_tenant_forbidden,
        agent_open_media_flow,
        integrator_cancel_rules,
        forbidden_without_permission
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
    ok.

admin_crud_roundtrip(Config) ->
    Boss = boss_token(Config, <<"bootstrap">>),
    %% bootstrap: create the tenant itself
    {200, #{<<"id">> := Tid}} =
        req(Config, post, "/api/v1/tenants", Boss, #{<<"name">> => <<"Acme">>}),
    Admin = boss_token(Config, Tid),
    Base = binary_to_list(<<"/api/v1/tenants/", Tid/binary>>),

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
    %% media type, queue, profile, reason
    {200, #{<<"id">> := MediaId}} =
        req(
            Config,
            post,
            Base ++ "/media-types",
            Admin,
            #{<<"name">> => <<"open_media">>}
        ),
    {200, #{<<"id">> := QueueId}} =
        req(
            Config,
            post,
            Base ++ "/queues",
            Admin,
            #{
                <<"name">> => <<"Building permits">>,
                <<"skill_reqs">> => [
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
    {200, #{<<"id">> := _UserId}} =
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
                <<"skills">> => #{SkillId => 2},
                <<"routing_profile_id">> => ProfileId
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
    {200, #{<<"id">> := Tid}} =
        req(Config, post, "/api/v1/tenants", Boss, #{<<"name">> => <<"Flow">>}),
    Admin = boss_token(Config, Tid),
    Base = binary_to_list(<<"/api/v1/tenants/", Tid/binary>>),

    {200, #{<<"id">> := MediaId}} =
        req(
            Config,
            post,
            Base ++ "/media-types",
            Admin,
            #{<<"name">> => <<"open_media">>}
        ),
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
        Tid,
        <<"flow-agent">>,
        [
            <<"agent:session:self">>,
            <<"agent:ready:self">>,
            <<"agent:offers:self">>,
            <<"agent:wrapup:self">>
        ]
    ),
    Integrator = user_token(
        Config,
        Tid,
        <<"flow-integrator">>,
        [
            <<"interactions:create">>,
            <<"interactions:cancel">>,
            <<"interactions:read">>
        ]
    ),

    %% agent signs in and goes ready for open media
    {200, #{<<"agent_id">> := _}} =
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
                <<"media_type_id">> => MediaId,
                <<"properties">> => #{<<"sap_case">> => <<"0815">>}
            }
        ),

    %% the offer shows up on the agent session (event push is a later
    %% milestone; REST clients poll the session)
    {ok, OfferId} = poll_offer(Config, Agent),
    {204, _} = req(
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
    ok.

integrator_cancel_rules(Config) ->
    Boss = boss_token(Config, <<"bootstrap">>),
    {200, #{<<"id">> := Tid}} =
        req(Config, post, "/api/v1/tenants", Boss, #{<<"name">> => <<"C">>}),
    Admin = boss_token(Config, Tid),
    Base = binary_to_list(<<"/api/v1/tenants/", Tid/binary>>),
    {200, #{<<"id">> := MediaId}} =
        req(
            Config,
            post,
            Base ++ "/media-types",
            Admin,
            #{<<"name">> => <<"open_media">>}
        ),
    {200, #{<<"id">> := QueueId}} =
        req(Config, post, Base ++ "/queues", Admin, #{<<"name">> => <<"q">>}),
    Integrator = user_token(
        Config,
        Tid,
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
            #{<<"queue_id">> => QueueId, <<"media_type_id">> => MediaId}
        ),
    Path = "/api/v1/interactions/" ++ binary_to_list(IId),
    {204, _} = req(Config, delete, Path, Integrator),
    {200, #{<<"state">> := <<"cancelled">>}} = req(Config, get, Path, Integrator),
    {409, #{<<"error">> := <<"not_cancellable">>}} =
        req(Config, delete, Path, Integrator),

    %% unknown queue -> 404, closed queue -> 409
    {404, _} = req(
        Config,
        post,
        "/api/v1/interactions",
        Integrator,
        #{
            <<"queue_id">> => <<"nope">>,
            <<"media_type_id">> => MediaId
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
            #{<<"queue_id">> => QueueId, <<"media_type_id">> => MediaId}
        ),
    ok.

forbidden_without_permission(Config) ->
    Boss = boss_token(Config, <<"bootstrap">>),
    {200, #{<<"id">> := Tid}} =
        req(Config, post, "/api/v1/tenants", Boss, #{<<"name">> => <<"F">>}),
    Nobody = user_token(Config, Tid, <<"nobody">>, []),
    Base = binary_to_list(<<"/api/v1/tenants/", Tid/binary>>),
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
        #{<<"queue_id">> => <<"q">>, <<"media_type_id">> => <<"m">>}
    ),
    {403, _} = req(Config, post, "/api/v1/agent/session", Nobody, #{}),
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
        {200, #{<<"pending_offers">> := [OfferId | _]}} ->
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
