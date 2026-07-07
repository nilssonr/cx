-module(cx_handler_oidc_metadata).

%% GET /.well-known/openid-configuration — OpenID Provider metadata (OIDC
%% Discovery 1.0 / RFC 8414). Advertises the issuer, endpoints, JWKS URI and
%% supported capabilities so standard client libraries auto-configure.
%% Auth-exempt (see cx_rest_auth_middleware). RS256 MUST appear in
%% id_token_signing_alg_values_supported (design §13.6).

-export([init/2]).

init(Req0, Opts) ->
    Body = cx_json:encode(metadata()),
    Req = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        Body,
        Req0
    ),
    {ok, Req, Opts}.

metadata() ->
    Issuer = issuer(),
    Alg = signing_alg_name(),
    #{
        <<"issuer">> => Issuer,
        <<"authorization_endpoint">> => join(Issuer, <<"/authorize">>),
        <<"token_endpoint">> => join(Issuer, <<"/token">>),
        <<"userinfo_endpoint">> => join(Issuer, <<"/userinfo">>),
        <<"jwks_uri">> => join(Issuer, <<"/.well-known/jwks.json">>),
        <<"response_types_supported">> => [<<"code">>],
        <<"grant_types_supported">> => [
            <<"authorization_code">>, <<"refresh_token">>, <<"client_credentials">>
        ],
        <<"subject_types_supported">> => [<<"public">>],
        <<"id_token_signing_alg_values_supported">> => [Alg],
        <<"token_endpoint_auth_methods_supported">> => [
            <<"client_secret_basic">>, <<"client_secret_post">>, <<"none">>
        ],
        <<"code_challenge_methods_supported">> => [<<"S256">>],
        <<"scopes_supported">> => [<<"openid">>, <<"profile">>, <<"email">>],
        <<"authorization_response_iss_parameter_supported">> => true
    }.

issuer() ->
    case cx_config:get(cx_auth, issuer, <<>>) of
        Issuer when is_binary(Issuer) -> Issuer;
        _ -> <<>>
    end.

%% The configured signing algorithm as its JWS header name (rs256 ->
%% <<"RS256">>); RS256 if unset/invalid so discovery always advertises a
%% conformant value.
signing_alg_name() ->
    case cx_jws_alg:from_config(cx_config:get(cx_auth, signing_alg, rs256)) of
        {ok, Alg} -> cx_jws_alg:jws_name(Alg);
        {error, unknown_alg} -> <<"RS256">>
    end.

join(Issuer, Path) ->
    <<Issuer/binary, Path/binary>>.
