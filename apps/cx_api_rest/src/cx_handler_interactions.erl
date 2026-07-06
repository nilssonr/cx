-module(cx_handler_interactions).

%% Integrator surface:
%%   POST /api/v1/interactions            {"queue_id", "media_type", "properties"}
%%   GET  /api/v1/interactions            ?queue_id=&state=&media_type=&agent_id=
%%                                        &limit=&after=   (cursor pagination)
%%   GET  /api/v1/interactions/:id
%%   POST /api/v1/interactions/:id/cancel (only while queued — a state
%%                                        transition, so a POST verb: the
%%                                        row lives on as `cancelled`)

-export([init/2]).

init(Req0, Opts = #{ctx := Ctx}) ->
    Op = maps:get(op, Opts, undefined),
    {Result, Req1} = dispatch(
        cowboy_req:method(Req0),
        Op,
        cowboy_req:binding(id, Req0),
        Ctx,
        Req0
    ),
    {ok, cx_handler:reply(Result, Req1), Opts}.

dispatch(<<"POST">>, undefined, undefined, Ctx, Req) ->
    cx_handler:with_body(Req, fun(Params) ->
        cx_router:create_interaction(Ctx, Params)
    end);
dispatch(<<"GET">>, undefined, undefined, Ctx, Req) ->
    Filters = maps:from_list(cowboy_req:parse_qs(Req)),
    {cx_router:list_interactions(Ctx, Filters), Req};
dispatch(<<"GET">>, undefined, Id, Ctx, Req) when is_binary(Id) ->
    {cx_router:get_interaction(Ctx, Id), Req};
dispatch(<<"POST">>, cancel, Id, Ctx, Req) when is_binary(Id) ->
    {cx_router:cancel_interaction(Ctx, Id), Req};
dispatch(_, _, _, _, Req) ->
    {{error, method_not_allowed}, Req}.
