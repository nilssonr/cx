-module(cx_h_agent_offers).

%% The agent's pending (ringing) offers. GETs are the REST snapshot /
%% rehydration path — the WebSocket events remain the push path. A
%% resolved offer is gone (404): an offer is an attempt with its own
%% identity, not a durable resource.
%%
%% GET  /api/v1/agent/offers
%% GET  /api/v1/agent/offers/:offer_id
%% POST /api/v1/agent/offers/:offer_id/accept   -> 200 {"interaction_id"}
%% POST /api/v1/agent/offers/:offer_id/reject

-export([init/2]).

init(Req0, Opts = #{ctx := Ctx, op := Op}) ->
    OfferId = cowboy_req:binding(offer_id, Req0),
    Result =
        case {cowboy_req:method(Req0), Op} of
            {<<"GET">>, list} -> cx_router:list_offers(Ctx);
            {<<"GET">>, get} -> cx_router:get_offer(Ctx, OfferId);
            {<<"POST">>, accepted} -> cx_router:accept_offer(Ctx, OfferId);
            {<<"POST">>, rejected} -> cx_router:reject_offer(Ctx, OfferId);
            _ -> {error, method_not_allowed}
        end,
    {ok, cx_h:reply(Result, Req0), Opts}.
