-module(cx_token).

%% Mints cx's own signed tokens (design §6), the issuing half the codebase
%% never had. Access tokens follow the RFC 9068 JWT profile (typ at+jwt,
%% iss/exp/aud/sub/client_id/iat/jti, optional scope + act_as_tenant); ID
%% tokens follow OIDC Core (aud = client_id, optional nonce). Signed with
%% the active key from cx_signing_keys; the existing cx_auth_jwt path
%% verifies them unchanged once key_source = local.
%%
%% Args is a map with atom keys: subject, tenant_id, client_id (required for
%% access), and optional scope / act_as_tenant / nonce.

-export([access_token/1, id_token/1]).

-define(DEFAULT_ACCESS_TTL_S, 600).
-define(DEFAULT_ALG, <<"RS256">>).

-spec access_token(map()) -> binary().
access_token(Args) when is_map(Args) ->
    Now = erlang:system_time(second),
    Ttl = cx_config:get(cx_auth, token_access_ttl_s, ?DEFAULT_ACCESS_TTL_S),
    Base = #{
        <<"iss">> => issuer(),
        <<"aud">> => access_audience(),
        <<"sub">> => maps:get(subject, Args),
        <<"client_id">> => maps:get(client_id, Args),
        <<"tenant_id">> => maps:get(tenant_id, Args),
        <<"iat">> => Now,
        <<"exp">> => Now + Ttl,
        <<"jti">> => cx_id:new()
    },
    Claims = with_optional(
        <<"act_as_tenant">>, act_as_tenant, with_optional(<<"scope">>, scope, Base, Args), Args
    ),
    sign(Claims, #{<<"typ">> => <<"at+jwt">>}).

-spec id_token(map()) -> binary().
id_token(Args) when is_map(Args) ->
    Now = erlang:system_time(second),
    Ttl = cx_config:get(cx_auth, token_access_ttl_s, ?DEFAULT_ACCESS_TTL_S),
    Base = #{
        <<"iss">> => issuer(),
        <<"aud">> => maps:get(client_id, Args),
        <<"sub">> => maps:get(subject, Args),
        <<"iat">> => Now,
        <<"exp">> => Now + Ttl
    },
    Claims = with_optional(<<"nonce">>, nonce, Base, Args),
    sign(Claims, #{}).

%% ---- internals ----

sign(Claims, ExtraHeader) ->
    {Kid, JWK} = cx_signing_keys:signing_key(),
    Alg = cx_config:get(cx_auth, signing_alg, ?DEFAULT_ALG),
    Header = maps:merge(#{<<"alg">> => Alg, <<"kid">> => Kid}, ExtraHeader),
    Signed = jose_jwt:sign(JWK, Header, Claims),
    {_, Token} = jose_jws:compact(Signed),
    Token.

issuer() ->
    cx_config:get(cx_auth, issuer, <<>>).

%% Access tokens are audience-restricted to the API resource (RFC 9068 §3);
%% v1 has a single resource server, the first configured audience.
access_audience() ->
    case cx_config:get(cx_auth, audiences, [<<"cx-api">>]) of
        [Audience | _] -> Audience;
        _ -> <<"cx-api">>
    end.

with_optional(ClaimKey, ArgKey, Claims, Args) ->
    case maps:get(ArgKey, Args, undefined) of
        Value when is_binary(Value), Value =/= <<>> -> Claims#{ClaimKey => Value};
        _ -> Claims
    end.
