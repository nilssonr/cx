-module(cx_h_offer).

%% POST /api/v1/agent/offers/:offer_id/accept | /reject

-export([init/2]).

init(Req0, Opts = #{ctx := Ctx, op := Op}) ->
    OfferId = cowboy_req:binding(offer_id, Req0),
    Result =
        case cowboy_req:method(Req0) of
            <<"POST">> when Op =:= accepted -> cx_router:accept_offer(Ctx, OfferId);
            <<"POST">> when Op =:= rejected -> cx_router:reject_offer(Ctx, OfferId);
            _ -> {error, method_not_allowed}
        end,
    {ok, cx_h:reply(Result, Req0), Opts}.
