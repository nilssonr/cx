-module(cx_rest_routes).

-export([dispatch/0]).

dispatch() ->
    cowboy_router:compile([{'_', routes()}]).

%% Order matters: cowboy takes the first match, so sub-resources go
%% before "/api/v1/tenants[/:tid]".
routes() ->
    [
        {"/healthz", cx_h_health, #{}},

        %% admin CRUD — one generic handler, parameterized by entity module
        {"/api/v1/tenants/:tid/users[/:id]", cx_h_crud, #{module => cx_user}},
        {"/api/v1/tenants/:tid/roles[/:id]", cx_h_crud, #{module => cx_role}},
        {"/api/v1/tenants/:tid/skills[/:id]", cx_h_crud, #{module => cx_skill}},
        {"/api/v1/tenants/:tid/media-types[/:id]", cx_h_crud, #{module => cx_media_type}},
        {"/api/v1/tenants/:tid/queues[/:id]", cx_h_crud, #{module => cx_queue}},
        {"/api/v1/tenants/:tid/routing-profiles[/:id]", cx_h_crud, #{module => cx_routing_profile}},
        {"/api/v1/tenants/:tid/not-ready-reasons[/:id]", cx_h_crud, #{module => cx_nr_reason}},
        {"/api/v1/tenants[/:tid]", cx_h_tenants, #{}},

        %% agent operations — identity comes from the token, never the path
        {"/api/v1/agent/session", cx_h_agent_session, #{}},
        {"/api/v1/agent/media/:media_id/state", cx_h_agent_ready, #{}},
        {"/api/v1/agent/offers/:offer_id/accept", cx_h_offer, #{op => accepted}},
        {"/api/v1/agent/offers/:offer_id/reject", cx_h_offer, #{op => rejected}},
        {"/api/v1/agent/interactions/:id/complete", cx_h_agent_interaction, #{}},
        {"/api/v1/agent/wrapup/extend", cx_h_wrapup, #{op => extend}},
        {"/api/v1/agent/wrapup", cx_h_wrapup, #{op => cancel}},

        %% integrator surface — Open Media rides on this
        {"/api/v1/interactions[/:id]", cx_h_interactions, #{}}
    ].
