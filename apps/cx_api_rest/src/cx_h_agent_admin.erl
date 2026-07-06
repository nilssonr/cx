-module(cx_h_agent_admin).

%% Supervisor operations on OTHER agents' sign-in sessions — gated by
%% agent:session:any, never part of the agent's own surface.
%%
%% DELETE /api/v1/tenants/:tid/users/:id/agent-session
%%   force sign-out: engaged work requeues at original position, ACW
%%   finalizes, pending offers are handed back. Idempotent.

-export([init/2]).

init(Req0, Opts = #{ctx := Ctx0}) ->
    Result =
        case
            {
                cowboy_req:method(Req0),
                cowboy_req:binding(tid, Req0),
                cowboy_req:binding(id, Req0)
            }
        of
            {<<"DELETE">>, Tid, UserId} when is_binary(Tid), is_binary(UserId) ->
                case cx_h:scope_tenant(Ctx0, Tid) of
                    {ok, Ctx} -> cx_router:force_stop_session(Ctx, UserId);
                    Error -> Error
                end;
            {<<"DELETE">>, _, _} ->
                {error, not_found};
            _ ->
                {error, method_not_allowed}
        end,
    {ok, cx_h:reply(Result, Req0), Opts}.
