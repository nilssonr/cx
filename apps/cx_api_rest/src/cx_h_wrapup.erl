-module(cx_h_wrapup).

%% POST /api/v1/agent/wrapup/extend {"extend_ms": N}
%% DELETE /api/v1/agent/wrapup

-export([init/2]).

init(Req0, Opts = #{ctx := Ctx, op := Op}) ->
    {Result, Req1} = case {cowboy_req:method(Req0), Op} of
        {<<"POST">>, extend} ->
            cx_h:with_body(Req0, fun(Params) ->
                cx_router:extend_wrapup(Ctx,
                    maps:get(<<"extend_ms">>, Params, undefined))
            end);
        {<<"DELETE">>, cancel} ->
            {cx_router:cancel_wrapup(Ctx), Req0};
        _ ->
            {{error, method_not_allowed}, Req0}
    end,
    {ok, cx_h:reply(Result, Req1), Opts}.
