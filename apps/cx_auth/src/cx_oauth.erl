-module(cx_oauth).

%% The OAuth 2.0 token grants. Pre-auth (no #auth_context{}) — like
%% cx_identity:verify_credential, this is the seam that ESTABLISHES tokens.
%% Given the parsed request parameters (binary keys, plus resolved client_id/
%% client_secret), it authenticates the client, runs the grant, and mints via
%% cx_token (access + ID) and cx_refresh_token (opaque handle). Errors are the
%% RFC 6749 §5.2 codes; the transport maps them to HTTP + JSON.

-include_lib("cx_core/include/cx_core.hrl").

-export([token/1]).

-export_type([error/0]).

-type error() ::
    invalid_request
    | invalid_client
    | invalid_grant
    | unauthorized_client
    | unsupported_grant_type
    | invalid_scope.

-define(DEFAULT_ACCESS_TTL_S, 600).

-spec token(map()) -> {ok, map()} | {error, error()}.
token(Params) ->
    case maps:get(<<"grant_type">>, Params, undefined) of
        <<"authorization_code">> -> authorization_code(Params);
        <<"refresh_token">> -> refresh_token(Params);
        <<"client_credentials">> -> client_credentials(Params);
        undefined -> {error, invalid_request};
        _ -> {error, unsupported_grant_type}
    end.

%% ---- authorization_code ----

authorization_code(Params) ->
    maybe
        {ok, Client} ?= authenticate_client(Params),
        {ok, Code} ?= require(Params, <<"code">>),
        {ok, Verifier} ?= require(Params, <<"code_verifier">>),
        {ok, RedirectUri} ?= require(Params, <<"redirect_uri">>),
        {ok, Auth} ?= consume_code(Code),
        ok ?= check_code(Auth, Client, RedirectUri, Verifier),
        {ok, authorization_code_response(Auth, Client)}
    end.

consume_code(Code) ->
    case cx_authorization_code:consume(Code) of
        {ok, Auth} -> {ok, Auth};
        {error, _} -> {error, invalid_grant}
    end.

check_code(Auth, #cx_oauth_client{client_id = ClientId}, RedirectUri, Verifier) ->
    Ok =
        Auth#cx_authorization_code.client_id =:= ClientId andalso
            Auth#cx_authorization_code.redirect_uri =:= RedirectUri andalso
            verify_pkce(Auth, Verifier),
    case Ok of
        true -> ok;
        false -> {error, invalid_grant}
    end.

verify_pkce(
    #cx_authorization_code{code_challenge_method = <<"S256">>, code_challenge = Challenge}, Verifier
) ->
    crypto:hash_equals(pkce_s256(Verifier), Challenge);
verify_pkce(_Auth, _Verifier) ->
    false.

pkce_s256(Verifier) ->
    base64:encode(crypto:hash(sha256, Verifier), #{mode => urlsafe, padding => false}).

authorization_code_response(Auth, #cx_oauth_client{client_id = ClientId}) ->
    Subject = Auth#cx_authorization_code.subject,
    TenantId = Auth#cx_authorization_code.tenant_id,
    Scope = Auth#cx_authorization_code.scope,
    Access = cx_token:access_token(#{
        subject => Subject,
        tenant_id => TenantId,
        client_id => ClientId,
        scope => join(Scope),
        act_as_tenant => Auth#cx_authorization_code.act_as_tenant
    }),
    {Refresh, _} = cx_refresh_token:issue(#{
        subject => Subject,
        tenant_id => TenantId,
        client_id => ClientId,
        scope => Scope,
        session_id => Auth#cx_authorization_code.session_id
    }),
    Base = (response(Access, Scope))#{<<"refresh_token">> => Refresh},
    with_id_token(Base, Scope, Subject, ClientId, Auth#cx_authorization_code.nonce).

with_id_token(Base, Scope, Subject, ClientId, Nonce) ->
    case lists:member(<<"openid">>, Scope) of
        true ->
            Id = cx_token:id_token(#{subject => Subject, client_id => ClientId, nonce => Nonce}),
            Base#{<<"id_token">> => Id};
        false ->
            Base
    end.

%% ---- refresh_token ----

refresh_token(Params) ->
    maybe
        {ok, Client} ?= authenticate_client(Params),
        {ok, Handle} ?= require(Params, <<"refresh_token">>),
        {ok, Token} ?= redeem(Handle),
        ok ?= same_client(Token, Client),
        {ok, Scope} ?= narrow_scope(Token#cx_refresh_token.scope, Params),
        {ok, refresh_response(Token, Client, Scope)}
    end.

redeem(Handle) ->
    case cx_refresh_token:redeem(Handle) of
        {ok, Token} ->
            {ok, Token};
        {error, {reuse, Token}} ->
            %% theft signal: burn the whole family
            _ = cx_refresh_token:revoke_family(Token),
            {error, invalid_grant};
        {error, _} ->
            {error, invalid_grant}
    end.

same_client(#cx_refresh_token{client_id = ClientId}, #cx_oauth_client{client_id = ClientId}) ->
    ok;
same_client(_Token, _Client) ->
    {error, invalid_grant}.

refresh_response(Token, #cx_oauth_client{client_id = ClientId}, Scope) ->
    Subject = Token#cx_refresh_token.subject,
    TenantId = Token#cx_refresh_token.tenant_id,
    {Refresh, _} = cx_refresh_token:rotate(Token, #{scope => Scope}),
    Access = cx_token:access_token(#{
        subject => Subject, tenant_id => TenantId, client_id => ClientId, scope => join(Scope)
    }),
    (response(Access, Scope))#{<<"refresh_token">> => Refresh}.

%% ---- client_credentials ----

client_credentials(Params) ->
    maybe
        {ok, Client} ?= authenticate_client(Params),
        ok ?= require_confidential(Client),
        ok ?= require_grant(Client, <<"client_credentials">>),
        {ok, TenantId} ?= require_tenant(Client),
        {ok, Scope} ?= subset_scope(Client#cx_oauth_client.scopes, Params),
        {ok, client_credentials_response(Client, TenantId, Scope)}
    end.

require_confidential(#cx_oauth_client{client_type = confidential}) -> ok;
require_confidential(_Client) -> {error, invalid_client}.

require_grant(#cx_oauth_client{grant_types = Grants}, Grant) ->
    case lists:member(Grant, Grants) of
        true -> ok;
        false -> {error, unauthorized_client}
    end.

require_tenant(#cx_oauth_client{tenant_id = TenantId}) when is_binary(TenantId) ->
    {ok, TenantId};
require_tenant(_Client) ->
    {error, invalid_client}.

client_credentials_response(#cx_oauth_client{client_id = ClientId}, TenantId, Scope) ->
    Access = cx_token:access_token(#{
        subject => ClientId, tenant_id => TenantId, client_id => ClientId, scope => join(Scope)
    }),
    response(Access, Scope).

%% ---- shared ----

authenticate_client(Params) ->
    case maps:get(<<"client_id">>, Params, undefined) of
        ClientId when is_binary(ClientId) ->
            cx_oauth_client:authenticate(
                ClientId, maps:get(<<"client_secret">>, Params, undefined)
            );
        _ ->
            {error, invalid_client}
    end.

%% Requested scope must be a subset of the originally granted scope (refresh).
narrow_scope(Granted, Params) ->
    subset_scope(Granted, Params, Granted).

%% Requested scope must be a subset of what the client is allowed.
subset_scope(Allowed, Params) ->
    subset_scope(Allowed, Params, Allowed).

subset_scope(Allowed, Params, Default) ->
    case maps:get(<<"scope">>, Params, undefined) of
        undefined ->
            {ok, Default};
        Requested ->
            Req = [S || S <- binary:split(Requested, <<" ">>, [global]), S =/= <<>>],
            case lists:all(fun(S) -> lists:member(S, Allowed) end, Req) of
                true -> {ok, Req};
                false -> {error, invalid_scope}
            end
    end.

require(Params, Key) ->
    case maps:get(Key, Params, undefined) of
        Value when is_binary(Value), Value =/= <<>> -> {ok, Value};
        _ -> {error, invalid_request}
    end.

response(Access, Scope) ->
    #{
        <<"access_token">> => Access,
        <<"token_type">> => <<"Bearer">>,
        <<"expires_in">> => cx_config:get(cx_auth, token_access_ttl_s, ?DEFAULT_ACCESS_TTL_S),
        <<"scope">> => join(Scope)
    }.

join(Scopes) ->
    iolist_to_binary(lists:join(<<" ">>, Scopes)).
