-module(cx_oidc_SUITE).

%% Full-stack e2e for the OpenID Provider metadata endpoints, booted with
%% the built-in issuer (key_source = local) so cx_signing_keys generates a
%% real key at startup. Exercises routing + the auth-exempt middleware
%% bypass + the handlers over real HTTP.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([jwks_served/1, discovery_served/1, no_auth_required/1]).

all() ->
    [jwks_served, discovery_served, no_auth_required].

init_per_suite(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    ok = application:set_env(
        cx_core, mnesia_dir, filename:join(PrivDir, "mnesia"), [{persistent, true}]
    ),
    ok = application:set_env(cx_api_rest, port, 0, [{persistent, true}]),
    ok = application:set_env(cx_auth, issuer, <<"https://issuer.test">>, [{persistent, true}]),
    ok = application:set_env(cx_auth, audiences, [<<"cx-api">>], [{persistent, true}]),
    ok = application:set_env(cx_auth, key_source, local, [{persistent, true}]),
    ok = application:set_env(cx_auth, signing_alg, <<"RS256">>, [{persistent, true}]),
    ok = application:set_env(cx_auth, signing_key_bits, 1024, [{persistent, true}]),
    {ok, _} = application:ensure_all_started(cx_api_rest),
    {ok, _} = application:ensure_all_started(inets),
    Port = ranch:get_port(cx_http),
    [{port, Port} | Config].

end_per_suite(_Config) ->
    application:stop(cx_api_rest),
    application:stop(cx_router),
    application:stop(cx_auth),
    application:stop(cx_core),
    application:stop(mnesia),
    ok.

jwks_served(Config) ->
    {200, Body} = get_json(Config, "/.well-known/jwks.json"),
    Keys = maps:get(<<"keys">>, Body),
    ?assertEqual(1, length(Keys)),
    [Key] = Keys,
    ?assertEqual(<<"RSA">>, maps:get(<<"kty">>, Key)),
    ?assert(maps:is_key(<<"kid">>, Key)),
    %% never a private key over the wire
    ?assertNot(maps:is_key(<<"d">>, Key)).

discovery_served(Config) ->
    {200, Body} = get_json(Config, "/.well-known/openid-configuration"),
    ?assertEqual(<<"https://issuer.test">>, maps:get(<<"issuer">>, Body)),
    ?assertEqual(<<"https://issuer.test/token">>, maps:get(<<"token_endpoint">>, Body)),
    ?assertEqual(
        <<"https://issuer.test/.well-known/jwks.json">>, maps:get(<<"jwks_uri">>, Body)
    ),
    ?assert(
        lists:member(<<"RS256">>, maps:get(<<"id_token_signing_alg_values_supported">>, Body))
    ),
    ?assert(lists:member(<<"S256">>, maps:get(<<"code_challenge_methods_supported">>, Body))),
    ?assertEqual(true, maps:get(<<"authorization_response_iss_parameter_supported">>, Body)).

%% Both metadata endpoints must be reachable with no Authorization header.
no_auth_required(Config) ->
    ?assertMatch({200, _}, get_json(Config, "/.well-known/jwks.json")),
    ?assertMatch({200, _}, get_json(Config, "/.well-known/openid-configuration")).

get_json(Config, Path) ->
    Port = proplists:get_value(port, Config),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
    {ok, {{_, Status, _}, _, Body}} = httpc:request(get, {Url, []}, [], [{body_format, binary}]),
    {ok, Map} = cx_json:decode(Body),
    {Status, Map}.
