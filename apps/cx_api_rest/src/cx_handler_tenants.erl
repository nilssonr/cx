-module(cx_handler_tenants).

%% Tenant admin is platform-level; cx_tenant enforces tenants:admin
%% itself (own-tenant GET excepted), so no path/context rescoping here.

-export([init/2]).

init(Req0, Opts = #{context := Ctx}) ->
    {Result, Req1} = dispatch(
        cowboy_req:method(Req0),
        cowboy_req:binding(tenant_id, Req0),
        Ctx,
        Req0
    ),
    {ok, cx_handler:reply(Result, Req1), Opts}.

dispatch(<<"GET">>, undefined, Ctx, Req) ->
    {cx_tenant:list(Ctx), Req};
dispatch(<<"GET">>, TenantId, Ctx, Req) ->
    {cx_tenant:get(Ctx, TenantId), Req};
dispatch(<<"POST">>, undefined, Ctx, Req) ->
    cx_handler:with_body(Req, fun(Params) -> cx_tenant:create(Ctx, Params) end);
dispatch(<<"PUT">>, TenantId, Ctx, Req) when TenantId =/= undefined ->
    cx_handler:with_body(Req, fun(Params) -> cx_tenant:update(Ctx, TenantId, Params) end);
dispatch(<<"DELETE">>, TenantId, Ctx, Req) when TenantId =/= undefined ->
    {cx_tenant:delete(Ctx, TenantId), Req};
dispatch(_, _, _, Req) ->
    {{error, method_not_allowed}, Req}.
