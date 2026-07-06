-module(cx_handler_agent_interactions).

%% Operations on interactions the agent owns; the op comes from the
%% route (cx_rest_routes), the interaction from the :interaction_id
%% binding, the identity from the token.
%%
%% GET  /api/v1/agent/interactions
%%        the agent's own interactions, full detail (rehydration)
%% GET  /api/v1/agent/interactions/:interaction_id
%%        one owned interaction (any phase, wrap-up included)
%% POST /api/v1/agent/interactions/:interaction_id/complete
%% POST /api/v1/agent/interactions/:interaction_id/hold
%% POST /api/v1/agent/interactions/:interaction_id/resume
%% PUT  /api/v1/agent/interactions/:interaction_id/qualifications
%%        {"qualification_ids": [...]} — replaces the current set
%% POST /api/v1/agent/interactions/:interaction_id/wrapup/extend
%%        {"extend_ms": N}
%% POST /api/v1/agent/interactions/:interaction_id/wrapup/finalize
%%        (end after-call work now)

-export([init/2]).

init(Req0, Opts = #{context := Context, operation := Operation}) ->
    InteractionId = cowboy_req:binding(interaction_id, Req0),
    {Result, Req1} =
        case {cowboy_req:method(Req0), Operation} of
            {<<"GET">>, list} ->
                {cx_router:agent_interactions(Context), Req0};
            {<<"GET">>, get} ->
                {cx_router:agent_interaction(Context, InteractionId), Req0};
            {<<"POST">>, complete} ->
                {cx_router:complete(Context, InteractionId), Req0};
            {<<"POST">>, hold} ->
                {cx_router:hold(Context, InteractionId), Req0};
            {<<"POST">>, resume} ->
                {cx_router:resume(Context, InteractionId), Req0};
            {<<"PUT">>, qualifications} ->
                cx_handler:with_body(Req0, fun(Params) ->
                    cx_router:qualify(Context, InteractionId, Params)
                end);
            {<<"POST">>, wrapup_extend} ->
                cx_handler:with_body(Req0, fun(Params) ->
                    cx_router:extend_wrapup(
                        Context,
                        InteractionId,
                        maps:get(<<"extend_ms">>, Params, undefined)
                    )
                end);
            {<<"POST">>, wrapup_finalize} ->
                {cx_router:finalize_wrapup(Context, InteractionId), Req0};
            _ ->
                {{error, method_not_allowed}, Req0}
        end,
    {ok, cx_handler:reply(Result, Req1), Opts}.
