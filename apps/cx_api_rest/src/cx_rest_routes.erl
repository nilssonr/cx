-module(cx_rest_routes).

%% Verb rule (hold every new route to it):
%%   DELETE  only where a durable resource ceases to exist (CRUD
%%           entities, the agent session). A DELETE whose target stays
%%           GETtable is a lie.
%%   POST /:id/<verb>  for every domain state transition (accept,
%%           reject, cancel, complete, hold, resume, wrapup ops).
%%   PUT     replaces a named sub-resource value in full (media state,
%%           qualifications, presence).
%%   GET     snapshot reads wherever a client might rehydrate.

-export([dispatch/0, routes/0]).

dispatch() ->
    cowboy_router:compile([{'_', docs_routes() ++ routes()}]).

%% API reference: the OpenAPI document plus a static Scalar UI. Omitted
%% entirely when expose_openapi is false — the spec reveals the endpoint and
%% permission topology, so closed deployments drop it (absent route -> 404).
%% These are auth-exempt (see cx_rest_auth_middleware); the API calls the UI
%% fires still carry a Bearer token and traverse auth normally.
docs_routes() ->
    case cx_config:get(cx_api_rest, expose_openapi, true) of
        true ->
            [
                {"/api/v1/openapi.yaml", cowboy_static,
                    {priv_file, cx_api_rest, "openapi.yaml", [
                        {mimetypes, {<<"application">>, <<"yaml">>, []}}
                    ]}},
                {"/api/v1/docs", cowboy_static, {priv_file, cx_api_rest, "docs/index.html"}},
                {"/api/v1/docs/[...]", cowboy_static, {priv_dir, cx_api_rest, "docs"}}
            ];
        _ ->
            []
    end.

%% Order matters: cowboy takes the first match, so more specific paths
%% (e.g. "/users/:id/agent-session") go before "/users[/:id]".
routes() ->
    [
        {"/healthz", cx_handler_health, #{}},

        %% OpenID Provider metadata — public/auth-exempt (cx_rest_auth_middleware)
        {"/.well-known/openid-configuration", cx_handler_oidc_metadata, #{}},
        {"/.well-known/jwks.json", cx_handler_jwks, #{}},

        %% OAuth authorization endpoint — hosted login + tenant picker (HTML)
        {"/authorize", cx_handler_authorize, #{}},
        %% OAuth token endpoint — form-encoded, authenticates its own client
        {"/token", cx_handler_token, #{}},

        %% push transport — auth is in-band (first frame), see cx_handler_socket
        {"/api/v1/socket", cx_handler_socket, #{}},

        %% collaboration presence — identity from the token
        {"/api/v1/presence/directory", cx_handler_presence_directory, #{}},
        {"/api/v1/presence", cx_handler_presence, #{}},

        %% admin CRUD — one generic handler per entity. Tenant comes from the
        %% token; a platform admin (tenants:admin) targets another tenant via
        %% the X-Tenant-Id header (see cx_handler:scope_tenant_header/2).
        {"/api/v1/users/:id/agent-session", cx_handler_agent_admin, #{}},
        {"/api/v1/users[/:id]", cx_handler_crud, #{module => cx_user}},
        {"/api/v1/roles[/:id]", cx_handler_crud, #{module => cx_role}},
        {"/api/v1/skills[/:id]", cx_handler_crud, #{module => cx_skill}},
        {"/api/v1/queues[/:id]", cx_handler_crud, #{module => cx_queue}},
        {"/api/v1/routing-profiles[/:id]", cx_handler_crud, #{module => cx_routing_profile}},
        {"/api/v1/not-ready-reasons[/:id]", cx_handler_crud, #{module => cx_not_ready_reason}},
        {"/api/v1/qualification-codes[/:id]", cx_handler_crud, #{module => cx_qualification_code}},

        %% platform tenant administration — :tenant_id here is the resource id
        {"/api/v1/tenants[/:tenant_id]", cx_handler_tenants, #{}},

        %% agent operations — identity comes from the token, never the path
        {"/api/v1/agent/session", cx_handler_agent_session, #{}},
        {"/api/v1/agent/media/:media_type/state", cx_handler_agent_ready, #{}},
        {"/api/v1/agent/offers", cx_handler_agent_offers, #{operation => list}},
        {"/api/v1/agent/offers/:offer_id", cx_handler_agent_offers, #{operation => get}},
        {"/api/v1/agent/offers/:offer_id/accept", cx_handler_agent_offers, #{operation => accepted}},
        {"/api/v1/agent/offers/:offer_id/reject", cx_handler_agent_offers, #{operation => rejected}},
        {"/api/v1/agent/interactions", cx_handler_agent_interactions, #{operation => list}},
        {"/api/v1/agent/interactions/:interaction_id", cx_handler_agent_interactions, #{
            operation => get
        }},
        {"/api/v1/agent/interactions/:interaction_id/complete", cx_handler_agent_interactions, #{
            operation => complete
        }},
        {"/api/v1/agent/interactions/:interaction_id/hold", cx_handler_agent_interactions, #{
            operation => hold
        }},
        {"/api/v1/agent/interactions/:interaction_id/resume", cx_handler_agent_interactions, #{
            operation => resume
        }},
        {"/api/v1/agent/interactions/:interaction_id/qualifications", cx_handler_agent_interactions,
            #{
                operation => qualifications
            }},
        {"/api/v1/agent/interactions/:interaction_id/wrapup/extend", cx_handler_agent_interactions,
            #{
                operation => wrapup_extend
            }},
        {"/api/v1/agent/interactions/:interaction_id/wrapup/finalize",
            cx_handler_agent_interactions, #{
                operation => wrapup_finalize
            }},

        %% integrator surface — Open Media rides on this
        {"/api/v1/interactions/:id/cancel", cx_handler_interactions, #{operation => cancel}},
        {"/api/v1/interactions[/:id]", cx_handler_interactions, #{}}
    ].
