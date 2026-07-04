-module(cx_h_tenants).

%% Tenant admin is platform-level; cx_tenant enforces tenants:admin
%% itself (own-tenant GET excepted), so no path/ctx rescoping here.

-export([init/2]).

init(Req0, Opts = #{ctx := Ctx}) ->
    {Result, Req1} = dispatch(
        cowboy_req:method(Req0),
        cowboy_req:binding(tid, Req0),
        Ctx,
        Req0
    ),
    {ok, cx_h:reply(Result, Req1), Opts}.

dispatch(<<"GET">>, undefined, Ctx, Req) ->
    {cx_tenant:list(Ctx), Req};
dispatch(<<"GET">>, Tid, Ctx, Req) ->
    {cx_tenant:get(Ctx, Tid), Req};
dispatch(<<"POST">>, undefined, Ctx, Req) ->
    cx_h:with_body(Req, fun(Params) -> cx_tenant:create(Ctx, Params) end);
dispatch(<<"PUT">>, Tid, Ctx, Req) when Tid =/= undefined ->
    cx_h:with_body(Req, fun(Params) -> cx_tenant:update(Ctx, Tid, Params) end);
dispatch(<<"DELETE">>, Tid, Ctx, Req) when Tid =/= undefined ->
    {cx_tenant:delete(Ctx, Tid), Req};
dispatch(_, _, _, Req) ->
    {{error, method_not_allowed}, Req}.
