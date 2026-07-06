-module(cx_handler_presence).

%% PUT /api/v1/presence  {"state": "busy"|"automatic"|..., "message": ..., "until": ms}
%% GET /api/v1/presence

-export([init/2]).

init(Req0, Opts = #{context := Context}) ->
    {Result, Req1} =
        case cowboy_req:method(Req0) of
            <<"GET">> ->
                {cx_presence:get_own(Context), Req0};
            <<"PUT">> ->
                cx_handler:with_body(Req0, fun(Params) ->
                    cx_presence:set_own(Context, Params)
                end);
            _ ->
                {{error, method_not_allowed}, Req0}
        end,
    {ok, cx_handler:reply(Result, Req1), Opts}.
