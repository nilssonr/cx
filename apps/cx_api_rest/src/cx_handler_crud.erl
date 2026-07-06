-module(cx_handler_crud).

%% Generic admin CRUD handler: every tenant-scoped entity module exposes
%% the same create/get/list/update/delete(Ctx, ...) shape, so one handler
%% serves them all, parameterized with #{module => cx_queue} from the
%% route table.

-export([init/2]).

init(Req0, Opts = #{ctx := Ctx0, module := Mod}) ->
    {Result, Req1} =
        case {cowboy_req:binding(tid, Req0), cowboy_req:binding(id, Req0)} of
            {Tid, Id} when is_binary(Tid), is_binary(Id) orelse Id =:= undefined ->
                case cx_handler:scope_tenant(Ctx0, Tid) of
                    {ok, Ctx} ->
                        dispatch(cowboy_req:method(Req0), Id, Mod, Ctx, Req0);
                    {error, forbidden} ->
                        {{error, forbidden}, Req0}
                end;
            _ ->
                {{error, not_found}, Req0}
        end,
    {ok, cx_handler:reply(Result, Req1), Opts}.

dispatch(<<"GET">>, undefined, Mod, Ctx, Req) ->
    {Mod:list(Ctx), Req};
dispatch(<<"GET">>, Id, Mod, Ctx, Req) ->
    {Mod:get(Ctx, Id), Req};
dispatch(<<"POST">>, undefined, Mod, Ctx, Req) ->
    cx_handler:with_body(Req, fun(Params) -> Mod:create(Ctx, Params) end);
dispatch(<<"PUT">>, Id, Mod, Ctx, Req) when Id =/= undefined ->
    cx_handler:with_body(Req, fun(Params) -> Mod:update(Ctx, Id, Params) end);
dispatch(<<"DELETE">>, Id, Mod, Ctx, Req) when Id =/= undefined ->
    {Mod:delete(Ctx, Id), Req};
dispatch(_, _, _, _, Req) ->
    {{error, method_not_allowed}, Req}.
