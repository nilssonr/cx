-module(cx_token_SUITE).

%% Full-stack e2e for POST /token: real httpc form-encoded requests through
%% cowboy -> cx_handler_token -> cx_oauth, with the built-in issuer
%% (key_source = local) and clients seeded from config at boot.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([client_credentials_over_http/1, refresh_over_http/1, error_responses/1]).

all() ->
    [client_credentials_over_http, refresh_over_http, error_responses].

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
    set(cx_auth, first_party_clients, [
        #{
            client_id => <<"svc">>,
            type => confidential,
            secret => <<"svc-secret">>,
            tenant_id => <<"t1">>,
            grant_types => [<<"client_credentials">>],
            scopes => [<<"interactions:read">>]
        },
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
    Port = ranch:get_port(cx_http),
    [{port, Port} | Config].

end_per_suite(_Config) ->
    application:stop(cx_api_rest),
    application:stop(cx_router),
    application:stop(cx_auth),
    application:stop(cx_core),
    application:stop(mnesia),
    ok.

set(App, Key, Value) ->
    ok = application:set_env(App, Key, Value, [{persistent, true}]).

client_credentials_over_http(Config) ->
    {Status, Headers, Body} = post(Config, [
        {<<"grant_type">>, <<"client_credentials">>},
        {<<"client_id">>, <<"svc">>},
        {<<"client_secret">>, <<"svc-secret">>}
    ]),
    ?assertEqual(200, Status),
    ?assertEqual(<<"no-store">>, header(<<"cache-control">>, Headers)),
    ?assertEqual(<<"Bearer">>, maps:get(<<"token_type">>, Body)),
    ?assert(is_binary(maps:get(<<"access_token">>, Body))).

refresh_over_http(Config) ->
    %% mint a refresh token in-process, then exchange it over HTTP
    {Handle, _} = cx_refresh_token:issue(#{
        subject => <<"u1">>, tenant_id => <<"t1">>, client_id => <<"spa">>, scope => [<<"openid">>]
    }),
    {Status, _Headers, Body} = post(Config, [
        {<<"grant_type">>, <<"refresh_token">>},
        {<<"refresh_token">>, Handle},
        {<<"client_id">>, <<"spa">>}
    ]),
    ?assertEqual(200, Status),
    ?assert(is_binary(maps:get(<<"access_token">>, Body))),
    ?assert(is_binary(maps:get(<<"refresh_token">>, Body))).

error_responses(Config) ->
    %% wrong client secret -> 401 invalid_client + WWW-Authenticate
    {S1, H1, B1} = post(Config, [
        {<<"grant_type">>, <<"client_credentials">>},
        {<<"client_id">>, <<"svc">>},
        {<<"client_secret">>, <<"wrong">>}
    ]),
    ?assertEqual(401, S1),
    ?assertEqual(<<"invalid_client">>, maps:get(<<"error">>, B1)),
    ?assertNotEqual(undefined, header(<<"www-authenticate">>, H1)),
    %% unknown grant -> 400 unsupported_grant_type
    {S2, _H2, B2} = post(Config, [
        {<<"grant_type">>, <<"telepathy">>},
        {<<"client_id">>, <<"svc">>}
    ]),
    ?assertEqual(400, S2),
    ?assertEqual(<<"unsupported_grant_type">>, maps:get(<<"error">>, B2)).

%% ---- helpers ----

%% All values here are URL-safe (identifiers + base64url handles), so no
%% percent-encoding is needed.
post(Config, Pairs) ->
    Port = proplists:get_value(port, Config),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/token",
    Body = iolist_to_binary(lists:join(<<"&">>, [<<K/binary, "=", V/binary>> || {K, V} <- Pairs])),
    {ok, {{_, Status, _}, Headers, RespBody}} =
        httpc:request(
            post,
            {Url, [], "application/x-www-form-urlencoded", Body},
            [],
            [{body_format, binary}]
        ),
    {ok, Map} = cx_json:decode(RespBody),
    {Status, Headers, Map}.

header(Name, Headers) ->
    case lists:keyfind(binary_to_list(Name), 1, Headers) of
        {_, Value} -> list_to_binary(Value);
        false -> undefined
    end.
