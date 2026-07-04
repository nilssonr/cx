-module(cx_auth_test).

%% Test/dev tooling: mint real signed JWTs so the full verification path
%% (signature, iss, aud, exp) runs identically to production — only key
%% distribution is stubbed via the {static, ...} key source. Lives in src/
%% so CT suites of other apps (and dev shells) can use it; never called by
%% production code.

-export([new_keypair/0, token/2, install/1, install/2]).

%% -> #{jwk, kid, public_map}; put public_map into the static key source.
new_keypair() ->
    JWK = jose_jwk:generate_key({okp, 'Ed25519'}),
    Kid = cx_id:new(),
    {_, PublicMap} = jose_jwk:to_public_map(JWK),
    #{jwk => JWK, kid => Kid, public_map => PublicMap#{<<"kid">> => Kid}}.

%% Overrides is a claims map merged over sane defaults; pass
%% #{<<"exp">> => Past} etc. to build bad tokens.
token(#{jwk := JWK, kid := Kid}, Overrides) ->
    Issuer = application:get_env(cx_auth, issuer, <<"http://test-issuer">>),
    Audiences = application:get_env(cx_auth, audiences, [<<"cx-api">>]),
    TenantClaim = application:get_env(
        cx_auth,
        tenant_claim,
        <<"urn:zitadel:iam:org:id">>
    ),
    Now = erlang:system_time(second),
    Defaults = #{
        <<"iss">> => Issuer,
        <<"aud">> => hd(Audiences),
        <<"sub">> => <<"test-subject">>,
        <<"exp">> => Now + 3600,
        <<"iat">> => Now,
        TenantClaim => <<"test-tenant">>
    },
    Claims = maps:merge(Defaults, Overrides),
    Signed = jose_jwt:sign(
        JWK,
        #{<<"alg">> => <<"EdDSA">>, <<"kid">> => Kid},
        Claims
    ),
    {_, Token} = jose_jws:compact(Signed),
    Token.

%% Configure cx_auth for tests: static keys + standard issuer/audience.
install(Keypair) ->
    install(Keypair, #{}).

install(#{public_map := PublicMap}, Opts) ->
    {ok, _} = application:ensure_all_started(jose),
    ok = jose:json_module(cx_jose_json),
    %% persistent: a later application load must not reset these
    Persist = [{persistent, true}],
    ok = application:set_env(
        cx_auth,
        issuer,
        maps:get(issuer, Opts, <<"http://test-issuer">>),
        Persist
    ),
    ok = application:set_env(
        cx_auth,
        audiences,
        maps:get(audiences, Opts, [<<"cx-api">>]),
        Persist
    ),
    ok = application:set_env(
        cx_auth,
        key_source,
        {static, [PublicMap]},
        Persist
    ),
    ok = application:set_env(
        cx_auth,
        tenant_claim,
        maps:get(
            tenant_claim,
            Opts,
            <<"urn:zitadel:iam:org:id">>
        ),
        Persist
    ),
    ok = application:set_env(
        cx_auth,
        platform_admin_subjects,
        maps:get(platform_admin_subjects, Opts, []),
        Persist
    ),
    ok.
