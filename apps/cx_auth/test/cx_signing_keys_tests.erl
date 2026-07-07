-module(cx_signing_keys_tests).

-include_lib("eunit/include/eunit.hrl").

%% 1024-bit keys keep RSA generation fast; correctness is size-independent.
signing_keys_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            fun generates_and_signs/0,
            fun jwks_is_public_only/0,
            fun rotation_overlaps/0
        ]
    end}.

setup() ->
    Dir =
        "_build/eunit-mnesia-signkeys-" ++
            integer_to_list(erlang:system_time(microsecond)) ++
            "-" ++ integer_to_list(erlang:unique_integer([positive])),
    application:set_env(cx_core, mnesia_dir, Dir),
    application:set_env(cx_auth, issuer, <<"https://issuer.test">>),
    application:set_env(cx_auth, signing_alg, <<"RS256">>),
    application:set_env(cx_auth, signing_key_bits, 1024),
    {ok, _} = application:ensure_all_started(jose),
    ok = jose:json_module(cx_jose_json),
    ok = cx_db:init(),
    {ok, Pid} = cx_signing_keys:start_link(),
    Pid.

cleanup(Pid) ->
    gen_server:stop(Pid),
    mnesia:stop(),
    ok.

generates_and_signs() ->
    {Kid, JWK} = cx_signing_keys:signing_key(),
    ?assert(is_binary(Kid)),
    Signed = jose_jwt:sign(JWK, #{<<"alg">> => <<"RS256">>, <<"kid">> => Kid}, #{
        <<"sub">> => <<"s">>
    }),
    {_, Token} = jose_jws:compact(Signed),
    ?assert(is_binary(Token)),
    %% verifiable against the published public half
    [{Kid, PubJWK}] = cx_signing_keys:verification_keys(),
    ?assertMatch({true, _, _}, jose_jwt:verify_strict(PubJWK, [<<"RS256">>], Token)).

jwks_is_public_only() ->
    [Entry] = cx_signing_keys:jwks(),
    ?assertEqual(<<"RSA">>, maps:get(<<"kty">>, Entry)),
    ?assertEqual(<<"sig">>, maps:get(<<"use">>, Entry)),
    ?assert(maps:is_key(<<"kid">>, Entry)),
    ?assert(maps:is_key(<<"n">>, Entry)),
    %% a JWKS MUST never carry a private key (RFC 7517 / OIDC Discovery §3)
    ?assertNot(maps:is_key(<<"d">>, Entry)).

rotation_overlaps() ->
    {Kid0, _} = cx_signing_keys:signing_key(),
    ok = cx_signing_keys:rotate(),
    {Kid1, _} = cx_signing_keys:signing_key(),
    ?assertNotEqual(Kid0, Kid1),
    %% both generations stay published + verifiable during the overlap
    Kids = [maps:get(<<"kid">>, E) || E <- cx_signing_keys:jwks()],
    ?assert(lists:member(Kid0, Kids)),
    ?assert(lists:member(Kid1, Kids)),
    ?assertEqual(2, length(cx_signing_keys:verification_keys())).
