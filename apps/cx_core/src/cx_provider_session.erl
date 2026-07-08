-module(cx_provider_session).

%% The OpenID-Provider login session: the person's authenticated session,
%% held server-side and referenced by an opaque cookie. Person-level and
%% tenant-agnostic — the tenant is chosen per authorization, never stored
%% here. Expiry is both idle (bumped on activity) and absolute (remember-me
%% extends it); it is checked on read, and cx_session_gc sweeps dead rows.

-include("cx_core.hrl").

-export([create/2, fetch/1, touch/1, destroy/1, destroy_for_subject/1]).

-define(DEFAULT_IDLE_TTL_S, 3600).
-define(DEFAULT_ABSOLUTE_TTL_S, 36000).
-define(DEFAULT_REMEMBER_TTL_S, 2592000).

%% Establish a session for a person; returns the opaque id (the cookie value)
%% and the row.
-spec create(binary(), boolean()) -> {binary(), #cx_provider_session{}}.
create(Subject, RememberMe) when is_binary(Subject), is_boolean(RememberMe) ->
    Id = new_id(),
    Now = cx_time:now_ms(),
    Rec = #cx_provider_session{
        id = Id,
        subject = Subject,
        remember_me = RememberMe,
        authenticated_at = Now,
        idle_expires_at = Now + idle_ttl_ms(),
        absolute_expires_at = Now + absolute_ttl_ms(RememberMe),
        created_at = Now
    },
    ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
    {Id, Rec}.

%% A live session, or not_found / expired (past the idle or absolute window).
-spec fetch(binary()) -> {ok, #cx_provider_session{}} | {error, not_found | expired}.
fetch(Id) ->
    case cx_store:read(cx_provider_session, Id) of
        {ok, Rec} -> check_live(Rec);
        {error, not_found} -> {error, not_found}
    end.

%% Bump the idle window on activity.
-spec touch(#cx_provider_session{}) -> ok.
touch(Rec) ->
    Updated = Rec#cx_provider_session{idle_expires_at = cx_time:now_ms() + idle_ttl_ms()},
    ok = cx_store:tx(fun() -> mnesia:write(Updated) end).

-spec destroy(binary()) -> ok.
destroy(Id) ->
    ok = cx_store:tx(fun() -> mnesia:delete({cx_provider_session, Id}) end).

%% Logout-everywhere / admin kill: every session this person holds.
-spec destroy_for_subject(binary()) -> ok.
destroy_for_subject(Subject) ->
    Rows = cx_store:dirty_index_read(cx_provider_session, Subject, #cx_provider_session.subject),
    ok = cx_store:tx(fun() ->
        lists:foreach(
            fun(R) -> mnesia:delete({cx_provider_session, R#cx_provider_session.id}) end, Rows
        )
    end).

%% ---- internals ----

check_live(Rec) ->
    Now = cx_time:now_ms(),
    Expired =
        Now >= Rec#cx_provider_session.absolute_expires_at orelse
            Now >= Rec#cx_provider_session.idle_expires_at,
    case Expired of
        true -> {error, expired};
        false -> {ok, Rec}
    end.

new_id() ->
    base64:encode(crypto:strong_rand_bytes(32), #{mode => urlsafe, padding => false}).

idle_ttl_ms() ->
    cx_config:get(cx_auth, session_idle_ttl_s, ?DEFAULT_IDLE_TTL_S) * 1000.

absolute_ttl_ms(true) ->
    cx_config:get(cx_auth, session_remember_ttl_s, ?DEFAULT_REMEMBER_TTL_S) * 1000;
absolute_ttl_ms(false) ->
    cx_config:get(cx_auth, session_absolute_ttl_s, ?DEFAULT_ABSOLUTE_TTL_S) * 1000.
