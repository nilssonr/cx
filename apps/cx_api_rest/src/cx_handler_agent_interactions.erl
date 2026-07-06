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

init(Req0, Opts = #{context := Ctx, operation := Op}) ->
    InteractionId = cowboy_req:binding(interaction_id, Req0),
    {Result, Req1} =
        case {cowboy_req:method(Req0), Op} of
            {<<"GET">>, list} ->
                {cx_router:agent_interactions(Ctx), Req0};
            {<<"GET">>, get} ->
                {cx_router:agent_interaction(Ctx, InteractionId), Req0};
            {<<"POST">>, complete} ->
                {cx_router:complete(Ctx, InteractionId), Req0};
            {<<"POST">>, hold} ->
                {cx_router:hold(Ctx, InteractionId), Req0};
            {<<"POST">>, resume} ->
                {cx_router:resume(Ctx, InteractionId), Req0};
            {<<"PUT">>, qualifications} ->
                cx_handler:with_body(Req0, fun(Params) ->
                    cx_router:qualify(Ctx, InteractionId, Params)
                end);
            {<<"POST">>, wrapup_extend} ->
                cx_handler:with_body(Req0, fun(Params) ->
                    cx_router:extend_wrapup(
                        Ctx,
                        InteractionId,
                        maps:get(<<"extend_ms">>, Params, undefined)
                    )
                end);
            {<<"POST">>, wrapup_finalize} ->
                {cx_router:finalize_wrapup(Ctx, InteractionId), Req0};
            _ ->
                {{error, method_not_allowed}, Req0}
        end,
    {ok, cx_handler:reply(Result, Req1), Opts}.
