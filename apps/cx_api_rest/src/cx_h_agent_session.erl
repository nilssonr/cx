-module(cx_h_agent_session).

%% The agent's SIGN-IN session (the per-agent router process) — not to
%% be confused with the customer session, which is the interaction.
%%
%% POST   /api/v1/agent/session              sign in (idempotent: an
%%                                           existing session returns
%%                                           200 + its state, like GET)
%% GET    /api/v1/agent/session              current state
%% DELETE /api/v1/agent/session[?force=true] sign out (idempotent);
%%                                           force requeues engaged work
%%                                           and finalizes ACW

-export([init/2]).

init(Req0, Opts = #{ctx := Ctx}) ->
    Result =
        case cowboy_req:method(Req0) of
            <<"POST">> -> cx_router:start_session(Ctx);
            <<"GET">> -> cx_router:get_session(Ctx);
            <<"DELETE">> -> cx_router:stop_session(Ctx, is_force(Req0));
            _ -> {error, method_not_allowed}
        end,
    {ok, cx_h:reply(Result, Req0), Opts}.

is_force(Req) ->
    proplists:get_value(<<"force">>, cowboy_req:parse_qs(Req)) =:= <<"true">>.
