-module(cx_handler_logout).

%% GET/POST /logout — RP-initiated logout (advertised as end_session_endpoint).
%% Ends the provider session bound to the cx_session cookie: revokes every
%% refresh token minted under it, destroys the session, and clears the cookie.
%% Cookie-based (no Bearer), so it is exempt from cx_rest_auth_middleware.
%% Idempotent — no cookie, or an already-dead session, still returns 204.
%%
%% No post_logout_redirect_uri: honoring an unregistered redirect target is an
%% open redirect, and cx has no registered post-logout URI set, so v1 returns
%% 204 and lets the client navigate. (Front/back-channel logout is deferred.)

-export([init/2]).

init(Req0, Opts) ->
    Req =
        case cowboy_req:method(Req0) of
            Method when Method =:= <<"GET">>; Method =:= <<"POST">> -> handle(Req0);
            _ -> cowboy_req:reply(405, #{<<"allow">> => <<"GET, POST">>}, <<>>, Req0)
        end,
    {ok, Req, Opts}.

handle(Req0) ->
    ok = end_session(Req0),
    Req1 = cx_session_cookie:clear(Req0),
    cowboy_req:reply(204, #{}, <<>>, Req1).

end_session(Req) ->
    case lists:keyfind(<<"cx_session">>, 1, cowboy_req:parse_cookies(Req)) of
        {_, SessionId} ->
            %% Provider session is the parent of the refresh tokens minted under
            %% it; revoke the family, then destroy the session. Both idempotent.
            _ = cx_refresh_token:revoke_by_session(SessionId),
            cx_provider_session:destroy(SessionId);
        false ->
            ok
    end.
