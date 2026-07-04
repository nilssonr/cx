-module(cx_h_agent_interaction).

%% POST /api/v1/agent/interactions/:id/complete

-export([init/2]).

init(Req0, Opts = #{ctx := Ctx}) ->
    IId = cowboy_req:binding(id, Req0),
    Result = case cowboy_req:method(Req0) of
        <<"POST">> -> cx_router:complete(Ctx, IId);
        _ -> {error, method_not_allowed}
    end,
    {ok, cx_h:reply(Result, Req0), Opts}.
