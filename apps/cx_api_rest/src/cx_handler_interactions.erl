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

init(Req0, Opts = #{context := Context}) ->
    Operation = maps:get(operation, Opts, undefined),
    {Result, Req1} = dispatch(
        cowboy_req:method(Req0),
        Operation,
        cowboy_req:binding(id, Req0),
        Context,
        Req0
    ),
    {ok, cx_handler:reply(Result, Req1), Opts}.

dispatch(<<"POST">>, undefined, undefined, Context, Req) ->
    cx_handler:with_body(Req, fun(Params) ->
        cx_router:create_interaction(Context, Params)
    end);
dispatch(<<"GET">>, undefined, undefined, Context, Req) ->
    Filters = maps:from_list(cowboy_req:parse_qs(Req)),
    {cx_router:list_interactions(Context, Filters), Req};
dispatch(<<"GET">>, undefined, Id, Context, Req) when is_binary(Id) ->
    {cx_router:get_interaction(Context, Id), Req};
dispatch(<<"POST">>, cancel, Id, Context, Req) when is_binary(Id) ->
    {cx_router:cancel_interaction(Context, Id), Req};
dispatch(_, _, _, _, Req) ->
    {{error, method_not_allowed}, Req}.
