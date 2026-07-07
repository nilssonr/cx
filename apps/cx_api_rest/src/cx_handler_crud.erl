-module(cx_handler_crud).

%% Generic admin CRUD handler: every tenant-scoped entity module exposes
%% the same create/get/list/update/delete(Context, ...) shape, so one handler
%% serves them all, parameterized with #{module => cx_queue} from the
%% route table. Tenant comes from the token (or the X-Tenant-Id header for
%% cross-tenant platform admins); the :id binding selects the resource.

-export([init/2]).

init(Req0, Opts = #{context := Context0, module := Mod}) ->
    {Result, Req1} =
        case cx_handler:scope_tenant_header(Context0, Req0) of
            {ok, Context} ->
                Id = cowboy_req:binding(id, Req0),
                dispatch(cowboy_req:method(Req0), Id, Mod, Context, Req0);
            {error, forbidden} ->
                {{error, forbidden}, Req0}
        end,
    {ok, cx_handler:reply(Result, Req1), Opts}.

dispatch(<<"GET">>, undefined, Mod, Context, Req) ->
    {Mod:list(Context), Req};
dispatch(<<"GET">>, Id, Mod, Context, Req) ->
    {Mod:get(Context, Id), Req};
dispatch(<<"POST">>, undefined, Mod, Context, Req) ->
    cx_handler:with_body(Req, fun(Params) -> Mod:create(Context, Params) end);
dispatch(<<"PUT">>, Id, Mod, Context, Req) when Id =/= undefined ->
    cx_handler:with_body(Req, fun(Params) -> Mod:update(Context, Id, Params) end);
dispatch(<<"DELETE">>, Id, Mod, Context, Req) when Id =/= undefined ->
    {Mod:delete(Context, Id), Req};
dispatch(_, _, _, _, Req) ->
    {{error, method_not_allowed}, Req}.
