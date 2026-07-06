-module(cx_handler_agent_ready).

%% PUT /api/v1/agent/media/:media_type/state
%%   {"state": "ready"} | {"state": "not_ready", "reason_id": "..."}

-export([init/2]).

init(Req0, Opts = #{ctx := Ctx}) ->
    Media = cowboy_req:binding(media_type, Req0),
    {Result, Req1} =
        case cowboy_req:method(Req0) of
            <<"PUT">> ->
                cx_handler:with_body(Req0, fun(Params) ->
                    case parse_state(Params) of
                        {ok, ReadyState} ->
                            cx_router:set_ready(Ctx, Media, ReadyState);
                        Error ->
                            Error
                    end
                end);
            _ ->
                {{error, method_not_allowed}, Req0}
        end,
    {ok, cx_handler:reply(Result, Req1), Opts}.

%% null == absent everywhere: the server itself serializes ready as
%% {"state":"ready","reason_id":null}, so PUTting a GET body back must
%% round-trip. A NON-null reason on "ready" stays a client bug —
%% rejected rather than dropped.
parse_state(#{<<"state">> := <<"ready">>, <<"reason_id">> := null}) ->
    {ok, ready};
parse_state(#{<<"state">> := <<"ready">>, <<"reason_id">> := _}) ->
    {error, {invalid, <<"reason_id">>}};
parse_state(#{<<"state">> := <<"ready">>}) ->
    {ok, ready};
parse_state(#{<<"state">> := <<"not_ready">>} = Params) ->
    case maps:get(<<"reason_id">>, Params, undefined) of
        undefined -> {ok, {not_ready, undefined}};
        null -> {ok, {not_ready, undefined}};
        ReasonId when is_binary(ReasonId) -> {ok, {not_ready, ReasonId}};
        _ -> {error, {invalid, <<"reason_id">>}}
    end;
parse_state(_) ->
    {error, {invalid, <<"state">>}}.
