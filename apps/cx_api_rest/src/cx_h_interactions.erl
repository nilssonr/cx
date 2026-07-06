-module(cx_h_interactions).

%% Integrator surface:
%%   POST   /api/v1/interactions      {"queue_id", "media_type", "properties"}
%%   GET    /api/v1/interactions      ?queue_id=&state=&media_type=&agent_id=
%%                                    &limit=&after=   (cursor pagination)
%%   GET    /api/v1/interactions/:id
%%   DELETE /api/v1/interactions/:id  (cancel — only while queued)

-export([init/2]).

init(Req0, Opts = #{ctx := Ctx}) ->
    {Result, Req1} = dispatch(
        cowboy_req:method(Req0),
        cowboy_req:binding(id, Req0),
        Ctx,
        Req0
    ),
    {ok, cx_h:reply(Result, Req1), Opts}.

dispatch(<<"POST">>, undefined, Ctx, Req) ->
    cx_h:with_body(Req, fun(Params) ->
        cx_router:create_interaction(Ctx, Params)
    end);
dispatch(<<"GET">>, undefined, Ctx, Req) ->
    Filters = maps:from_list(cowboy_req:parse_qs(Req)),
    {cx_router:list_interactions(Ctx, Filters), Req};
dispatch(<<"GET">>, Id, Ctx, Req) when Id =/= undefined ->
    {cx_router:get_interaction(Ctx, Id), Req};
dispatch(<<"DELETE">>, Id, Ctx, Req) when Id =/= undefined ->
    {cx_router:cancel_interaction(Ctx, Id), Req};
dispatch(_, _, _, Req) ->
    {{error, method_not_allowed}, Req}.
