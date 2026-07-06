-module(cx_handler_tenants).

%% Tenant admin is platform-level; cx_tenant enforces tenants:admin
%% itself (own-tenant GET excepted), so no path/context rescoping here.

-export([init/2]).

init(Req0, Opts = #{context := Context}) ->
    {Result, Req1} = dispatch(
        cowboy_req:method(Req0),
        cowboy_req:binding(tenant_id, Req0),
        Context,
        Req0
    ),
    {ok, cx_handler:reply(Result, Req1), Opts}.

dispatch(<<"GET">>, undefined, Context, Req) ->
    {cx_tenant:list(Context), Req};
dispatch(<<"GET">>, TenantId, Context, Req) ->
    {cx_tenant:get(Context, TenantId), Req};
dispatch(<<"POST">>, undefined, Context, Req) ->
    cx_handler:with_body(Req, fun(Params) -> cx_tenant:create(Context, Params) end);
dispatch(<<"PUT">>, TenantId, Context, Req) when TenantId =/= undefined ->
    cx_handler:with_body(Req, fun(Params) -> cx_tenant:update(Context, TenantId, Params) end);
dispatch(<<"DELETE">>, TenantId, Context, Req) when TenantId =/= undefined ->
    {cx_tenant:delete(Context, TenantId), Req};
dispatch(_, _, _, Req) ->
    {{error, method_not_allowed}, Req}.
