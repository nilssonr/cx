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

-export([dispatch/0]).

dispatch() ->
    cowboy_router:compile([{'_', routes()}]).

%% Order matters: cowboy takes the first match, so sub-resources go
%% before "/api/v1/tenants[/:tenant_id]".
routes() ->
    [
        {"/healthz", cx_handler_health, #{}},

        %% push transport — auth is in-band (first frame), see cx_handler_socket
        {"/api/v1/socket", cx_handler_socket, #{}},

        %% collaboration presence — identity from the token
        {"/api/v1/presence/directory", cx_handler_presence_directory, #{}},
        {"/api/v1/presence", cx_handler_presence, #{}},

        %% admin CRUD — one generic handler, parameterized by entity module
        {"/api/v1/tenants/:tenant_id/users/:id/agent-session", cx_handler_agent_admin, #{}},
        {"/api/v1/tenants/:tenant_id/users[/:id]", cx_handler_crud, #{module => cx_user}},
        {"/api/v1/tenants/:tenant_id/roles[/:id]", cx_handler_crud, #{module => cx_role}},
        {"/api/v1/tenants/:tenant_id/skills[/:id]", cx_handler_crud, #{module => cx_skill}},
        {"/api/v1/tenants/:tenant_id/queues[/:id]", cx_handler_crud, #{module => cx_queue}},
        {"/api/v1/tenants/:tenant_id/routing-profiles[/:id]", cx_handler_crud, #{
            module => cx_routing_profile
        }},
        {"/api/v1/tenants/:tenant_id/not-ready-reasons[/:id]", cx_handler_crud, #{
            module => cx_not_ready_reason
        }},
        {"/api/v1/tenants/:tenant_id/qualification-codes[/:id]", cx_handler_crud, #{
            module => cx_qualification_code
        }},
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
