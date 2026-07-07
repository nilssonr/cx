-module(cx_oauth_client).

%% OAuth clients. client_id is globally unique. Confidential clients present a
%% secret, verified constant-time against a stored SHA-256 (secrets are
%% high-entropy, so a fast hash is sufficient — PBKDF2 is for human
%% passwords). Public clients (the SPA and mobile app) have no secret and
%% rely on PKCE.

-include("cx_core.hrl").

-export([fetch/1, authenticate/2, ensure_seed/1, hash_secret/1]).

-spec fetch(binary()) -> {ok, #cx_oauth_client{}} | {error, not_found}.
fetch(ClientId) ->
    cx_store:read(cx_oauth_client, ClientId).

%% Resolve + authenticate a client. A confidential client must present the
%% correct secret; a public client must present none.
-spec authenticate(binary(), binary() | undefined) ->
    {ok, #cx_oauth_client{}} | {error, invalid_client}.
authenticate(ClientId, Secret) ->
    case fetch(ClientId) of
        {ok, Client = #cx_oauth_client{status = active}} -> check_secret(Client, Secret);
        {ok, #cx_oauth_client{}} -> {error, invalid_client};
        {error, not_found} -> {error, invalid_client}
    end.

-spec hash_secret(binary()) -> binary().
hash_secret(Secret) ->
    crypto:hash(sha256, Secret).

%% Seed a first-party client at boot if absent (idempotent), from a config
%% map: #{client_id, type, grant_types, redirect_uris, scopes, tenant_id?,
%% secret?}.
-spec ensure_seed(map()) -> ok.
ensure_seed(#{client_id := ClientId} = Spec) when is_binary(ClientId) ->
    Now = cx_time:now_ms(),
    _ = cx_store:tx(fun() ->
        case mnesia:read(cx_oauth_client, ClientId) of
            [] -> mnesia:write(from_spec(ClientId, Spec, Now));
            [_] -> ok
        end
    end),
    ok;
ensure_seed(_) ->
    ok.

%% ---- internals ----

check_secret(Client = #cx_oauth_client{client_type = public, secret_hash = undefined}, _Secret) ->
    {ok, Client};
check_secret(
    Client = #cx_oauth_client{client_type = confidential, secret_hash = Hash}, Secret
) when is_binary(Hash), is_binary(Secret) ->
    case crypto:hash_equals(hash_secret(Secret), Hash) of
        true -> {ok, Client};
        false -> {error, invalid_client}
    end;
check_secret(_Client, _Secret) ->
    {error, invalid_client}.

from_spec(ClientId, Spec, Now) ->
    #cx_oauth_client{
        client_id = ClientId,
        tenant_id = maps:get(tenant_id, Spec, undefined),
        name = maps:get(name, Spec, ClientId),
        client_type = maps:get(type, Spec, public),
        grant_types = maps:get(grant_types, Spec, []),
        redirect_uris = maps:get(redirect_uris, Spec, []),
        scopes = maps:get(scopes, Spec, []),
        secret_hash = seed_secret(Spec),
        status = active,
        created_at = Now,
        updated_at = Now
    }.

seed_secret(#{secret := Secret}) when is_binary(Secret) -> hash_secret(Secret);
seed_secret(_) -> undefined.
