-module(cx_refresh_token).

%% Stored, rotating refresh tokens. The client holds an opaque random handle;
%% we store only its SHA-256 (token_id), so a database leak yields no usable
%% tokens. Every use rotates: the old row records rotated_to and a new handle
%% is issued. Presenting an already-rotated or revoked handle is a theft
%% signal — the whole token family is revoked (RFC 9700 §4.14.2).

-include("cx_core.hrl").

-export([issue/1, redeem/1, rotate/2, revoke_family/1, find/1, revoke/1, revoke_by_session/1]).

-define(DEFAULT_TTL_S, 2592000).
-define(DEFAULT_IDLE_TTL_S, 1209600).

%% Mint + persist a refresh token; returns the plaintext handle (given to the
%% client) and the stored row. Args: #{subject, tenant_id, client_id,
%% session_id?, scope?}.
-spec issue(map()) -> {binary(), #cx_refresh_token{}}.
issue(Args) ->
    {Handle, Rec} = mint(Args),
    ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
    {Handle, Rec}.

%% Classify a presented handle: valid, a theft signal (reuse of a
%% revoked/rotated token), or expired.
-spec redeem(binary()) ->
    {ok, #cx_refresh_token{}}
    | {error, {reuse, #cx_refresh_token{}} | invalid | expired}.
redeem(Handle) ->
    case cx_store:read(cx_refresh_token, token_id(Handle)) of
        {ok, Rec} -> classify(Rec);
        {error, not_found} -> {error, invalid}
    end.

%% Rotate: mark the old row as superseded and issue a fresh token carrying the
%% same grant (scope may narrow). One transaction.
-spec rotate(#cx_refresh_token{}, map()) -> {binary(), #cx_refresh_token{}}.
rotate(Old, Args) ->
    {Handle, New} = mint(carry(Old, Args)),
    ok = cx_store:tx(fun() ->
        mnesia:write(Old#cx_refresh_token{rotated_to = New#cx_refresh_token.token_id}),
        mnesia:write(New)
    end),
    {Handle, New}.

%% Revoke every token in the family — the whole provider session if the token
%% carries one, otherwise every refresh token this subject holds for this
%% client.
-spec revoke_family(#cx_refresh_token{}) -> ok.
revoke_family(#cx_refresh_token{session_id = SessionId}) when is_binary(SessionId) ->
    revoke(cx_store:dirty_index_read(cx_refresh_token, SessionId, #cx_refresh_token.session_id));
revoke_family(#cx_refresh_token{subject = Subject, client_id = ClientId}) ->
    Rows = cx_store:dirty_index_read(cx_refresh_token, Subject, #cx_refresh_token.subject),
    revoke([R || R = #cx_refresh_token{client_id = C} <- Rows, C =:= ClientId]).

%% Look up the stored row for a handle WITHOUT redeem/1's liveness check.
%% Callers that must act on already-revoked/rotated/expired rows — RFC 7009
%% revocation (idempotent) and RFC 7662 introspection — need the raw row.
-spec find(binary()) -> {ok, #cx_refresh_token{}} | {error, not_found}.
find(Handle) ->
    case cx_store:read(cx_refresh_token, token_id(Handle)) of
        {ok, #cx_refresh_token{} = Rec} -> {ok, Rec};
        {error, not_found} -> {error, not_found}
    end.

%% Revoke one row or a list of rows. Idempotent — re-marking an already-revoked
%% row is a no-op write, so revoking a dead token still succeeds (RFC 7009).
-spec revoke(#cx_refresh_token{} | [#cx_refresh_token{}]) -> ok.
revoke(#cx_refresh_token{} = Rec) ->
    revoke([Rec]);
revoke(Rows) when is_list(Rows) ->
    ok = cx_store:tx(fun() ->
        lists:foreach(fun(R) -> mnesia:write(R#cx_refresh_token{revoked = true}) end, Rows)
    end),
    ok.

%% Revoke every refresh token minted under a provider session (logout / kill).
-spec revoke_by_session(binary()) -> ok.
revoke_by_session(SessionId) ->
    revoke(cx_store:dirty_index_read(cx_refresh_token, SessionId, #cx_refresh_token.session_id)).

%% ---- internals ----

mint(Args) ->
    Handle = new_handle(),
    Now = cx_time:now_ms(),
    Rec = #cx_refresh_token{
        token_id = token_id(Handle),
        subject = maps:get(subject, Args),
        tenant_id = maps:get(tenant_id, Args),
        client_id = maps:get(client_id, Args),
        session_id = maps:get(session_id, Args, undefined),
        scope = maps:get(scope, Args, []),
        rotated_to = undefined,
        revoked = false,
        idle_expires_at = Now + idle_ttl_ms(),
        expires_at = Now + ttl_ms(),
        created_at = Now
    },
    {Handle, Rec}.

carry(Old, Args) ->
    #{
        subject => Old#cx_refresh_token.subject,
        tenant_id => Old#cx_refresh_token.tenant_id,
        client_id => Old#cx_refresh_token.client_id,
        session_id => Old#cx_refresh_token.session_id,
        scope => maps:get(scope, Args, Old#cx_refresh_token.scope)
    }.

classify(#cx_refresh_token{revoked = true} = Rec) ->
    {error, {reuse, Rec}};
classify(#cx_refresh_token{rotated_to = RotatedTo} = Rec) when RotatedTo =/= undefined ->
    {error, {reuse, Rec}};
classify(Rec) ->
    Now = cx_time:now_ms(),
    case Now >= Rec#cx_refresh_token.expires_at orelse idle_expired(Rec, Now) of
        true -> {error, expired};
        false -> {ok, Rec}
    end.

idle_expired(#cx_refresh_token{idle_expires_at = undefined}, _Now) -> false;
idle_expired(#cx_refresh_token{idle_expires_at = Idle}, Now) -> Now >= Idle.

new_handle() ->
    base64:encode(crypto:strong_rand_bytes(32), #{mode => urlsafe, padding => false}).

token_id(Handle) ->
    base64:encode(crypto:hash(sha256, Handle), #{mode => urlsafe, padding => false}).

ttl_ms() ->
    cx_config:get(cx_auth, token_refresh_ttl_s, ?DEFAULT_TTL_S) * 1000.

idle_ttl_ms() ->
    cx_config:get(cx_auth, token_refresh_idle_ttl_s, ?DEFAULT_IDLE_TTL_S) * 1000.
