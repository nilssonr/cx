-module(cx_handler_agent_admin).

%% Supervisor operations on OTHER agents' sign-in sessions — gated by
%% agent:session:any, never part of the agent's own surface.
%%
%% DELETE /api/v1/tenants/:tenant_id/users/:id/agent-session
%%   force sign-out: engaged work requeues at original position, ACW
%%   finalizes, pending offers are handed back. Idempotent.

-export([init/2]).

init(Req0, Opts = #{context := Context0}) ->
    Result =
        case
            {
                cowboy_req:method(Req0),
                cowboy_req:binding(tenant_id, Req0),
                cowboy_req:binding(id, Req0)
            }
        of
            {<<"DELETE">>, TenantId, UserId} when is_binary(TenantId), is_binary(UserId) ->
                case cx_handler:scope_tenant(Context0, TenantId) of
                    {ok, Context} -> cx_router:force_stop_session(Context, UserId);
                    Error -> Error
                end;
            {<<"DELETE">>, _, _} ->
                {error, not_found};
            _ ->
                {error, method_not_allowed}
        end,
    {ok, cx_handler:reply(Result, Req0), Opts}.
