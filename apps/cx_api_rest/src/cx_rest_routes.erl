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
%% before "/api/v1/tenants[/:tid]".
routes() ->
    [
        {"/healthz", cx_h_health, #{}},

        %% push transport — auth is in-band (first frame), see cx_h_socket
        {"/api/v1/socket", cx_h_socket, #{}},

        %% collaboration presence — identity from the token
        {"/api/v1/presence/directory", cx_h_presence_directory, #{}},
        {"/api/v1/presence", cx_h_presence, #{}},

        %% admin CRUD — one generic handler, parameterized by entity module
        {"/api/v1/tenants/:tid/users/:id/agent-session", cx_h_agent_admin, #{}},
        {"/api/v1/tenants/:tid/users[/:id]", cx_h_crud, #{module => cx_user}},
        {"/api/v1/tenants/:tid/roles[/:id]", cx_h_crud, #{module => cx_role}},
        {"/api/v1/tenants/:tid/skills[/:id]", cx_h_crud, #{module => cx_skill}},
        {"/api/v1/tenants/:tid/queues[/:id]", cx_h_crud, #{module => cx_queue}},
        {"/api/v1/tenants/:tid/routing-profiles[/:id]", cx_h_crud, #{module => cx_routing_profile}},
        {"/api/v1/tenants/:tid/not-ready-reasons[/:id]", cx_h_crud, #{
            module => cx_not_ready_reason
        }},
        {"/api/v1/tenants/:tid/qualification-codes[/:id]", cx_h_crud, #{
            module => cx_qualification_code
        }},
        {"/api/v1/tenants[/:tid]", cx_h_tenants, #{}},

        %% agent operations — identity comes from the token, never the path
        {"/api/v1/agent/session", cx_h_agent_session, #{}},
        {"/api/v1/agent/media/:media_type/state", cx_h_agent_ready, #{}},
        {"/api/v1/agent/offers", cx_h_agent_offers, #{op => list}},
        {"/api/v1/agent/offers/:offer_id", cx_h_agent_offers, #{op => get}},
        {"/api/v1/agent/offers/:offer_id/accept", cx_h_agent_offers, #{op => accepted}},
        {"/api/v1/agent/offers/:offer_id/reject", cx_h_agent_offers, #{op => rejected}},
        {"/api/v1/agent/interactions", cx_h_agent_interactions, #{op => list}},
        {"/api/v1/agent/interactions/:interaction_id", cx_h_agent_interactions, #{
            op => get
        }},
        {"/api/v1/agent/interactions/:interaction_id/complete", cx_h_agent_interactions, #{
            op => complete
        }},
        {"/api/v1/agent/interactions/:interaction_id/hold", cx_h_agent_interactions, #{
            op => hold
        }},
        {"/api/v1/agent/interactions/:interaction_id/resume", cx_h_agent_interactions, #{
            op => resume
        }},
        {"/api/v1/agent/interactions/:interaction_id/qualifications", cx_h_agent_interactions, #{
            op => qualifications
        }},
        {"/api/v1/agent/interactions/:interaction_id/wrapup/extend", cx_h_agent_interactions, #{
            op => wrapup_extend
        }},
        {"/api/v1/agent/interactions/:interaction_id/wrapup/finalize", cx_h_agent_interactions, #{
            op => wrapup_finalize
        }},

        %% integrator surface — Open Media rides on this
        {"/api/v1/interactions/:id/cancel", cx_h_interactions, #{op => cancel}},
        {"/api/v1/interactions[/:id]", cx_h_interactions, #{}}
    ].
