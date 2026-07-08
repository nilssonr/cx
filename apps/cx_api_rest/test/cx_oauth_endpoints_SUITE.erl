-module(cx_oauth_endpoints_SUITE).

%% Full-stack e2e for the Phase 5 endpoints — /revoke (RFC 7009),
%% /introspect (RFC 7662), /userinfo (OIDC §5.3) and RP-initiated /logout —
%% plus the WWW-Authenticate: Bearer challenge on protected resources. Booted
%% with the built-in issuer (key_source = local) so real tokens are minted and
%% verified end to end. tenant_claim = tenant_id matches what cx_token mints.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("cx_core/include/cx_core.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    revoke_then_refresh_fails/1,
    revoke_unknown_succeeds/1,
    revoke_bad_client_unauthorized/1,
    revoke_foreign_token_ignored/1,
    introspect_active_access_token/1,
    introspect_revoked_refresh_inactive/1,
    introspect_requires_client_auth/1,
    userinfo_returns_claims/1,
    userinfo_bad_token_challenge/1,
    userinfo_no_token_bare_challenge/1,
    protected_forbidden_challenge/1,
    logout_ends_session/1,
    discovery_advertises_endpoints/1
]).

all() ->
    [
        revoke_then_refresh_fails,
        revoke_unknown_succeeds,
        revoke_bad_client_unauthorized,
        revoke_foreign_token_ignored,
        introspect_active_access_token,
        introspect_revoked_refresh_inactive,
        introspect_requires_client_auth,
        userinfo_returns_claims,
        userinfo_bad_token_challenge,
        userinfo_no_token_bare_challenge,
        protected_forbidden_challenge,
        logout_ends_session,
        discovery_advertises_endpoints
    ].

init_per_suite(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    set(cx_core, mnesia_dir, filename:join(PrivDir, "mnesia")),
    set(cx_api_rest, port, 0),
    set(cx_auth, issuer, <<"https://issuer.test">>),
    set(cx_auth, audiences, [<<"cx-api">>]),
    set(cx_auth, key_source, local),
    set(cx_auth, signing_alg, rs256),
    set(cx_auth, signing_source, cx_signing_key_generated),
    set(cx_auth, signing_source_opts, #{rsa_bits => 1024}),
    %% the built-in issuer mints the tenant_id claim
    set(cx_auth, tenant_claim, <<"tenant_id">>),
    set(cx_auth, first_party_clients, [
        #{
            client_id => <<"spa">>,
            type => public,
            grant_types => [<<"authorization_code">>, <<"refresh_token">>],
            redirect_uris => [<<"https://app/cb">>],
            scopes => [<<"openid">>]
        }
    ]),
    {ok, _} = application:ensure_all_started(cx_api_rest),
    {ok, _} = application:ensure_all_started(inets),
    %% a confidential client (for the client-auth paths of revoke/introspect)
    ok = cx_oauth_client:store(#{
        client_id => <<"svc">>,
        type => confidential,
        secret => <<"svc-secret">>,
        tenant_id => <<"t1">>,
        grant_types => [<<"client_credentials">>],
        scopes => [<<"interactions:read">>]
    }),
    %% a normal user: identity supplies the userinfo email, the tenant user the
    %% name; role_ids = [] gives no permissions (drives the 403 challenge test)
    ok = cx_identity:ensure_seed(#{
        subject => <<"alice-sub">>, email => <<"alice@example.test">>, password => <<"pw-alice">>
    }),
    Now = cx_time:now_ms(),
    ok = cx_store:tx(fun() ->
        mnesia:write(#cx_tenant{
            id = <<"t1">>,
            name = <<"Tenant One">>,
            status = active,
            created_at = Now,
            updated_at = Now
        }),
        mnesia:write(#cx_user{
            key = {<<"t1">>, cx_id:new()},
            subject = <<"alice-sub">>,
            name = <<"Alice">>,
            email = <<"alice@example.test">>,
            role_ids = [],
            skills = #{},
            routing_profile_id = undefined,
            status = active,
            created_at = Now,
            updated_at = Now
        })
    end),
    Port = ranch:get_port(cx_http),
    [{port, Port} | Config].

end_per_suite(_Config) ->
    application:stop(cx_api_rest),
    application:stop(cx_router),
    application:stop(cx_auth),
    application:stop(cx_core),
    application:stop(mnesia),
    ok.

%% ---- /revoke (RFC 7009) ----

revoke_then_refresh_fails(Config) ->
    Handle = issue_refresh(<<"u-revoke">>),
    {200, _, _} = request(
        post,
        "/revoke",
        [],
        form([
            {<<"token">>, Handle}, {<<"client_id">>, <<"spa">>}
        ]),
        Config
    ),
    %% the revoked handle no longer refreshes
    {Status, _, _} = refresh(Handle, Config),
    ?assertEqual(400, Status).

revoke_unknown_succeeds(Config) ->
    %% RFC 7009: revoking an unknown token still returns 200
    {Status, _, _} = request(
        post,
        "/revoke",
        [],
        form([
            {<<"token">>, <<"no-such-handle">>}, {<<"client_id">>, <<"spa">>}
        ]),
        Config
    ),
    ?assertEqual(200, Status).

revoke_bad_client_unauthorized(Config) ->
    {Status, Headers, Body} = request(
        post,
        "/revoke",
        [],
        form([
            {<<"token">>, <<"whatever">>},
            {<<"client_id">>, <<"svc">>},
            {<<"client_secret">>, <<"wrong">>}
        ]),
        Config
    ),
    ?assertEqual(401, Status),
    ?assertEqual(<<"invalid_client">>, maps:get(<<"error">>, json(Body))),
    ?assertNotEqual(undefined, header(<<"www-authenticate">>, Headers)).

revoke_foreign_token_ignored(Config) ->
    %% a valid but non-owning client cannot revoke another client's token
    Handle = issue_refresh(<<"u-foreign">>),
    {200, _, _} = request(
        post,
        "/revoke",
        [],
        form([
            {<<"token">>, Handle},
            {<<"client_id">>, <<"svc">>},
            {<<"client_secret">>, <<"svc-secret">>}
        ]),
        Config
    ),
    %% still usable by its owner
    {Status, _, _} = refresh(Handle, Config),
    ?assertEqual(200, Status).

%% ---- /introspect (RFC 7662) ----

introspect_active_access_token(Config) ->
    Token = mint_access(<<"alice-sub">>),
    {200, _, Body} = request(
        post,
        "/introspect",
        [],
        form([
            {<<"token">>, Token},
            {<<"client_id">>, <<"svc">>},
            {<<"client_secret">>, <<"svc-secret">>}
        ]),
        Config
    ),
    Map = json(Body),
    ?assertEqual(true, maps:get(<<"active">>, Map)),
    ?assertEqual(<<"alice-sub">>, maps:get(<<"sub">>, Map)).

introspect_revoked_refresh_inactive(Config) ->
    Handle = issue_refresh(<<"u-introspect">>),
    {ok, Rec} = cx_refresh_token:find(Handle),
    ok = cx_refresh_token:revoke(Rec),
    {200, _, Body} = request(
        post,
        "/introspect",
        [],
        form([
            {<<"token">>, Handle},
            {<<"client_id">>, <<"svc">>},
            {<<"client_secret">>, <<"svc-secret">>}
        ]),
        Config
    ),
    ?assertEqual(false, maps:get(<<"active">>, json(Body))).

introspect_requires_client_auth(Config) ->
    %% no client credentials at all -> 401, blocks token scanning
    {Status, _, Body} = request(
        post,
        "/introspect",
        [],
        form([
            {<<"token">>, <<"anything">>}
        ]),
        Config
    ),
    ?assertEqual(401, Status),
    ?assertEqual(<<"invalid_client">>, maps:get(<<"error">>, json(Body))).

%% ---- /userinfo (OIDC §5.3) ----

userinfo_returns_claims(Config) ->
    Token = mint_access(<<"alice-sub">>),
    {200, Headers, Body} = request(get, "/userinfo", [auth(Token)], <<>>, Config),
    ?assertEqual(<<"application/json">>, header(<<"content-type">>, Headers)),
    Map = json(Body),
    ?assertEqual(<<"alice-sub">>, maps:get(<<"sub">>, Map)),
    ?assertEqual(<<"alice@example.test">>, maps:get(<<"email">>, Map)),
    ?assertEqual(<<"Alice">>, maps:get(<<"name">>, Map)).

userinfo_bad_token_challenge(Config) ->
    {Status, Headers, _} = request(get, "/userinfo", [auth(<<"not-a-token">>)], <<>>, Config),
    ?assertEqual(401, Status),
    ?assertEqual(<<"Bearer error=\"invalid_token\"">>, header(<<"www-authenticate">>, Headers)).

userinfo_no_token_bare_challenge(Config) ->
    %% no credentials at all -> bare Bearer challenge, no error attribute
    {Status, Headers, _} = request(get, "/userinfo", [], <<>>, Config),
    ?assertEqual(401, Status),
    ?assertEqual(<<"Bearer">>, header(<<"www-authenticate">>, Headers)).

%% ---- WWW-Authenticate on a protected resource ----

protected_forbidden_challenge(Config) ->
    %% alice has no permissions, so listing queues is 403 insufficient_scope
    Token = mint_access(<<"alice-sub">>),
    {Status, Headers, _} = request(get, "/api/v1/queues", [auth(Token)], <<>>, Config),
    ?assertEqual(403, Status),
    ?assertEqual(
        <<"Bearer error=\"insufficient_scope\"">>, header(<<"www-authenticate">>, Headers)
    ).

%% ---- RP-initiated logout ----

logout_ends_session(Config) ->
    {SessionId, _} = cx_provider_session:create(<<"alice-sub">>, false),
    {Handle, _} = cx_refresh_token:issue(#{
        subject => <<"alice-sub">>,
        tenant_id => <<"t1">>,
        client_id => <<"spa">>,
        scope => [<<"openid">>],
        session_id => SessionId
    }),
    Cookie = {"cookie", "cx_session=" ++ binary_to_list(SessionId)},
    {Status, Headers, _} = request(post, "/logout", [Cookie], <<>>, Config),
    ?assertEqual(204, Status),
    %% the provider session is destroyed
    ?assertEqual({error, not_found}, cx_provider_session:fetch(SessionId)),
    %% and its refresh family revoked -> the handle no longer refreshes
    {RefreshStatus, _, _} = refresh(Handle, Config),
    ?assertEqual(400, RefreshStatus),
    %% the cookie is cleared
    SetCookie = header(<<"set-cookie">>, Headers),
    ?assert(is_binary(SetCookie)),
    ?assertNotEqual(nomatch, binary:match(SetCookie, <<"cx_session=">>)).

%% ---- discovery ----

discovery_advertises_endpoints(Config) ->
    {200, _, Body} = request(get, "/.well-known/openid-configuration", [], <<>>, Config),
    Map = json(Body),
    ?assertEqual(<<"https://issuer.test/revoke">>, maps:get(<<"revocation_endpoint">>, Map)),
    ?assertEqual(
        <<"https://issuer.test/introspect">>, maps:get(<<"introspection_endpoint">>, Map)
    ),
    ?assertEqual(<<"https://issuer.test/logout">>, maps:get(<<"end_session_endpoint">>, Map)).

%% ---- helpers ----

set(App, Key, Value) ->
    ok = application:set_env(App, Key, Value, [{persistent, true}]).

issue_refresh(Subject) ->
    {Handle, _} = cx_refresh_token:issue(#{
        subject => Subject, tenant_id => <<"t1">>, client_id => <<"spa">>, scope => [<<"openid">>]
    }),
    Handle.

mint_access(Subject) ->
    cx_token:access_token(#{
        subject => Subject, tenant_id => <<"t1">>, client_id => <<"spa">>, scope => <<"openid">>
    }).

refresh(Handle, Config) ->
    request(
        post,
        "/token",
        [],
        form([
            {<<"grant_type">>, <<"refresh_token">>},
            {<<"refresh_token">>, Handle},
            {<<"client_id">>, <<"spa">>}
        ]),
        Config
    ).

auth(Token) ->
    {"authorization", "Bearer " ++ binary_to_list(Token)}.

%% All form/header values here are URL-safe (identifiers, base64url handles,
%% compact JWTs), so no percent-encoding is needed.
form(Pairs) ->
    iolist_to_binary(lists:join(<<"&">>, [<<K/binary, "=", V/binary>> || {K, V} <- Pairs])).

request(Method, Path, ExtraHeaders, Body, Config) ->
    Port = proplists:get_value(port, Config),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
    Request =
        case Method of
            get -> {Url, ExtraHeaders};
            post -> {Url, ExtraHeaders, "application/x-www-form-urlencoded", Body}
        end,
    {ok, {{_, Status, _}, Headers, RespBody}} =
        httpc:request(Method, Request, [], [{body_format, binary}]),
    {Status, Headers, RespBody}.

json(Body) ->
    {ok, Map} = cx_json:decode(Body),
    Map.

header(Name, Headers) ->
    case lists:keyfind(binary_to_list(Name), 1, Headers) of
        {_, Value} -> list_to_binary(Value);
        false -> undefined
    end.
