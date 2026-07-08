-module(cx_handler_agent_admin).

%% Supervisor operations on OTHER agents' sign-in sessions — gated by
%% agent:session:any, never part of the agent's own surface.
%%
%% DELETE /api/v1/users/:id/agent-session
%%   force sign-out: engaged work requeues at original position, ACW
%%   finalizes, pending offers are handed back. Idempotent. Tenant is the
%%   token tenant (a platform admin targeting another tenant carries a signed
%%   act_as_tenant claim, honored at authentication).

-export([init/2]).

init(Req0, Opts = #{context := Context}) ->
    Result =
        case {cowboy_req:method(Req0), cowboy_req:binding(id, Req0)} of
            {<<"DELETE">>, UserId} when is_binary(UserId) ->
                cx_router:force_stop_session(Context, UserId);
            {<<"DELETE">>, _} ->
                {error, not_found};
            _ ->
                {error, method_not_allowed}
        end,
    {ok, cx_handler:reply(Result, Req0), Opts}.
