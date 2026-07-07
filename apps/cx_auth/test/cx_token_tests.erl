-module(cx_token_tests).

-include_lib("eunit/include/eunit.hrl").

%% cx mints its own tokens and the EXISTING cx_auth_jwt path verifies them
%% unchanged once key_source = local — the whole point of the issuer.
token_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            fun access_token_verifies_through_the_real_path/0,
            fun id_token_targets_the_client/0
        ]
    end}.

setup() ->
    Dir =
        "_build/eunit-mnesia-token-" ++
            integer_to_list(erlang:system_time(microsecond)) ++
            "-" ++ integer_to_list(erlang:unique_integer([positive])),
    application:set_env(cx_core, mnesia_dir, Dir),
    application:set_env(cx_auth, issuer, <<"https://issuer.test">>),
    application:set_env(cx_auth, audiences, [<<"cx-api">>]),
    application:set_env(cx_auth, signing_alg, <<"RS256">>),
    application:set_env(cx_auth, signing_key_bits, 1024),
    application:set_env(cx_auth, key_source, local),
    {ok, _} = application:ensure_all_started(jose),
    ok = jose:json_module(cx_jose_json),
    ok = cx_db:init(),
    {ok, Pid} = cx_signing_keys:start_link(),
    Pid.

cleanup(Pid) ->
    gen_server:stop(Pid),
    mnesia:stop(),
    ok.

access_token_verifies_through_the_real_path() ->
    Token = cx_token:access_token(#{
        subject => <<"user-1">>,
        tenant_id => <<"t1">>,
        client_id => <<"cx-agent-spa">>,
        scope => <<"openid profile">>
    }),
    {ok, Claims} = cx_auth_jwt:verify(Token),
    ?assertEqual(<<"https://issuer.test">>, maps:get(<<"iss">>, Claims)),
    ?assertEqual(<<"cx-api">>, maps:get(<<"aud">>, Claims)),
    ?assertEqual(<<"user-1">>, maps:get(<<"sub">>, Claims)),
    ?assertEqual(<<"t1">>, maps:get(<<"tenant_id">>, Claims)),
    ?assertEqual(<<"cx-agent-spa">>, maps:get(<<"client_id">>, Claims)),
    ?assertEqual(<<"openid profile">>, maps:get(<<"scope">>, Claims)),
    ?assert(is_binary(maps:get(<<"jti">>, Claims))),
    %% RFC 9068 access-token profile header
    Header = jose:decode(jose_jws:peek_protected(Token)),
    ?assertEqual(<<"at+jwt">>, maps:get(<<"typ">>, Header)).

id_token_targets_the_client() ->
    Token = cx_token:id_token(#{
        subject => <<"user-1">>, client_id => <<"cx-agent-spa">>, nonce => <<"n-123">>
    }),
    %% aud = client_id (OIDC), so it is NOT a valid API access token — verify
    %% the signature directly against the published public key.
    [{_Kid, PubJWK}] = cx_signing_keys:verification_keys(),
    {true, {jose_jwt, Claims}, _} = jose_jwt:verify_strict(PubJWK, [<<"RS256">>], Token),
    ?assertEqual(<<"cx-agent-spa">>, maps:get(<<"aud">>, Claims)),
    ?assertEqual(<<"user-1">>, maps:get(<<"sub">>, Claims)),
    ?assertEqual(<<"n-123">>, maps:get(<<"nonce">>, Claims)).
