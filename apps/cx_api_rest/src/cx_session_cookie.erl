-module(cx_session_cookie).

%% The provider-session browser cookie (cx_session) and the attributes shared
%% by the login flow's cookies. One source of truth so /authorize (which sets
%% the cookie on login) and /logout (which clears it) cannot drift apart.
%% Secure, HttpOnly, SameSite=Lax, path=/. Remember-me adds a Max-Age
%% (persistent cookie); otherwise it is a session cookie. The allow_insecure_jwks
%% dev flag (plain-http localhost) relaxes Secure so cookies work in dev/test.

-export([set/3, clear/1, opts/1]).

-define(NAME, <<"cx_session">>).
-define(DEFAULT_REMEMBER_TTL_S, 2592000).

%% Set the session cookie. Remember-me makes it persistent (Max-Age), otherwise
%% it is a session cookie that dies with the browser.
-spec set(binary(), boolean(), cowboy_req:req()) -> cowboy_req:req().
set(SessionId, Remember, Req) ->
    MaxAge =
        case Remember of
            true -> cx_config:get(cx_auth, session_remember_ttl_s, ?DEFAULT_REMEMBER_TTL_S);
            false -> undefined
        end,
    cowboy_req:set_resp_cookie(?NAME, SessionId, Req, opts(MaxAge)).

%% Expire the session cookie (Max-Age 0) with the SAME attributes it was set
%% with, so the browser matches and deletes it.
-spec clear(cowboy_req:req()) -> cowboy_req:req().
clear(Req) ->
    cowboy_req:set_resp_cookie(?NAME, <<>>, Req, (opts(undefined))#{max_age => 0}).

%% Shared cookie attributes; `undefined` MaxAge yields a session cookie. Also
%% used for the login flow's CSRF cookie (same Secure/SameSite/path policy).
opts(MaxAge) ->
    Base = #{http_only => true, secure => secure(), same_site => lax, path => <<"/">>},
    case MaxAge of
        undefined -> Base;
        Seconds -> Base#{max_age => Seconds}
    end.

secure() ->
    cx_config:get(cx_auth, allow_insecure_jwks, false) =/= true.
