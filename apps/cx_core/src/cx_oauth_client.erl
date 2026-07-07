-module(cx_oauth_client).

%% OAuth clients resolve from two places, checked in order:
%%   1. Internal applications (the SPA, the mobile app) declared in config
%%      (cx_auth first_party_clients). These are deployment constants — their
%%      client_id and redirect URIs are shared with the frontend build — so
%%      config is their source of truth, read live (no drift, no seeding).
%%      They are always PUBLIC: config never carries a secret.
%%   2. Everything else (third-party integrator clients) lives in the
%%      cx_oauth_client Mnesia table, created via store/1, and is confidential
%%      with a SHA-256 of its secret.
%% A config-declared client_id shadows any Mnesia row of the same id.

-include("cx_core.hrl").

-export([fetch/1, authenticate/2, store/1]).

%% Resolve a client: config-declared internal app first, then the Mnesia table.
-spec fetch(binary()) -> {ok, #cx_oauth_client{}} | {error, not_found}.
fetch(ClientId) ->
    case first_party(ClientId) of
        {ok, Client} -> {ok, Client};
        none -> cx_store:read(cx_oauth_client, ClientId)
    end.

%% Resolve + authenticate. A confidential client must present the correct
%% secret (constant-time compare); a public client must present none.
-spec authenticate(binary(), binary() | undefined) ->
    {ok, #cx_oauth_client{}} | {error, invalid_client}.
authenticate(ClientId, Secret) ->
    case fetch(ClientId) of
        {ok, Client = #cx_oauth_client{status = active}} -> check_secret(Client, Secret);
        {ok, #cx_oauth_client{}} -> {error, invalid_client};
        {error, not_found} -> {error, invalid_client}
    end.

%% Write a client to Mnesia — the registration/admin-API path for third-party
%% clients (internal apps live in config, not here). Secret is hashed.
-spec store(map()) -> ok.
store(#{client_id := ClientId} = Spec) when is_binary(ClientId) ->
    Now = cx_time:now_ms(),
    ok = cx_store:tx(fun() -> mnesia:write(from_spec(ClientId, Spec, Now)) end).

%% ---- internals ----

%% Resolve an internal application from config. Forced public with no secret:
%% config is the wrong place for a credential, and the SPA/mobile cannot keep
%% one anyway.
first_party(ClientId) ->
    Specs = cx_config:get(cx_auth, first_party_clients, []),
    case [S || S <- Specs, is_map(S), maps:get(client_id, S, undefined) =:= ClientId] of
        [Spec | _] -> {ok, config_client(ClientId, Spec)};
        [] -> none
    end.

config_client(ClientId, Spec) ->
    #cx_oauth_client{
        client_id = ClientId,
        tenant_id = undefined,
        name = maps:get(name, Spec, ClientId),
        client_type = public,
        grant_types = maps:get(grant_types, Spec, []),
        redirect_uris = maps:get(redirect_uris, Spec, []),
        scopes = maps:get(scopes, Spec, []),
        secret_hash = undefined,
        status = active,
        created_at = 0,
        updated_at = 0
    }.

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
        client_type = maps:get(type, Spec, confidential),
        grant_types = maps:get(grant_types, Spec, []),
        redirect_uris = maps:get(redirect_uris, Spec, []),
        scopes = maps:get(scopes, Spec, []),
        secret_hash = spec_secret(Spec),
        status = active,
        created_at = Now,
        updated_at = Now
    }.

spec_secret(#{secret := Secret}) when is_binary(Secret) -> hash_secret(Secret);
spec_secret(_) -> undefined.

hash_secret(Secret) ->
    crypto:hash(sha256, Secret).
