-module(cx_h_agent_ready).

%% PUT /api/v1/agent/media/:media_type/state
%%   {"state": "ready"} | {"state": "not_ready", "reason_id": "..."}

-export([init/2]).

init(Req0, Opts = #{ctx := Ctx}) ->
    Media = cowboy_req:binding(media_type, Req0),
    {Result, Req1} =
        case cowboy_req:method(Req0) of
            <<"PUT">> ->
                cx_h:with_body(Req0, fun(Params) ->
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
    {ok, cx_h:reply(Result, Req1), Opts}.

parse_state(#{<<"state">> := <<"ready">>}) ->
    {ok, ready};
parse_state(#{<<"state">> := <<"not_ready">>} = Params) ->
    case maps:get(<<"reason_id">>, Params, undefined) of
        undefined -> {ok, {not_ready, undefined}};
        ReasonId when is_binary(ReasonId) -> {ok, {not_ready, ReasonId}};
        _ -> {error, {invalid, <<"reason_id">>}}
    end;
parse_state(_) ->
    {error, {invalid, <<"state">>}}.
