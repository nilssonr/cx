-module(cx_h_agent_session).

-export([init/2]).

init(Req0, Opts = #{ctx := Ctx}) ->
    Result =
        case cowboy_req:method(Req0) of
            <<"POST">> -> cx_router:start_session(Ctx);
            <<"GET">> -> cx_router:get_session(Ctx);
            <<"DELETE">> -> cx_router:stop_session(Ctx);
            _ -> {error, method_not_allowed}
        end,
    {ok, cx_h:reply(Result, Req0), Opts}.
