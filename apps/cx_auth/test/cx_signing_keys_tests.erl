-module(cx_signing_keys_tests).

-include_lib("eunit/include/eunit.hrl").

%% One manager, three key types through the SAME seam — the proof the
%% abstraction isn't a single-implementation façade. 1024-bit RSA keeps
%% generation fast; correctness is size-independent.

%% RS256 (generated) — the default asymmetric path.
rs256_test_() ->
    {setup, gen_setup(rs256, cx_signing_key_generated, #{rsa_bits => 1024}), fun cleanup/1, fun(_) ->
        [
            fun generates_and_signs/0,
            fun jwks_is_public_only/0,
            fun rotation_overlaps/0
        ]
    end}.

%% EdDSA (generated) — a different asymmetric key TYPE (OKP), same seam.
eddsa_test_() ->
    {setup, gen_setup(eddsa, cx_signing_key_generated, #{}), fun cleanup/1, fun(_) ->
        [fun eddsa_signs_and_publishes/0]
    end}.

%% HS256 (static shared secret) — symmetric: no JWKS, verifies with the
%% secret. The dev/lab path, handled without shoehorning.
hs256_test_() ->
    {setup,
        gen_setup(hs256, cx_signing_key_static, #{secret => <<"dev-shared-secret-32-bytes-long!">>}),
        fun cleanup/1, fun(_) ->
            [fun symmetric_has_no_jwks/0]
        end}.

gen_setup(Alg, Source, Opts) ->
    fun() ->
        Dir =
            "_build/eunit-mnesia-signkeys-" ++
                integer_to_list(erlang:system_time(microsecond)) ++
                "-" ++ integer_to_list(erlang:unique_integer([positive])),
        application:set_env(cx_core, mnesia_dir, Dir),
        application:set_env(cx_auth, issuer, <<"https://issuer.test">>),
        application:set_env(cx_auth, signing_alg, Alg),
        application:set_env(cx_auth, signing_source, Source),
        application:set_env(cx_auth, signing_source_opts, Opts),
        {ok, _} = application:ensure_all_started(jose),
        ok = jose:json_module(cx_jose_json),
        ok = cx_db:init(),
        {ok, Pid} = cx_signing_keys:start_link(),
        Pid
    end.

cleanup(Pid) ->
    gen_server:stop(Pid),
    mnesia:stop(),
    ok.

generates_and_signs() ->
    {Kid, JWK, JwsName} = cx_signing_keys:signing_key(),
    ?assertEqual(<<"RS256">>, JwsName),
    ?assert(is_binary(Kid)),
    Token = compact(JWK, JwsName, Kid),
    [{Kid, PubJWK}] = cx_signing_keys:verification_keys(),
    ?assertMatch({true, _, _}, jose_jwt:verify_strict(PubJWK, [<<"RS256">>], Token)).

jwks_is_public_only() ->
    [Entry] = cx_signing_keys:jwks(),
    ?assertEqual(<<"RSA">>, maps:get(<<"kty">>, Entry)),
    ?assertEqual(<<"RS256">>, maps:get(<<"alg">>, Entry)),
    ?assertEqual(<<"sig">>, maps:get(<<"use">>, Entry)),
    ?assert(maps:is_key(<<"kid">>, Entry)),
    ?assertNot(maps:is_key(<<"d">>, Entry)).

rotation_overlaps() ->
    {Kid0, _, _} = cx_signing_keys:signing_key(),
    ok = cx_signing_keys:rotate(),
    {Kid1, _, _} = cx_signing_keys:signing_key(),
    ?assertNotEqual(Kid0, Kid1),
    Kids = [maps:get(<<"kid">>, E) || E <- cx_signing_keys:jwks()],
    ?assert(lists:member(Kid0, Kids)),
    ?assert(lists:member(Kid1, Kids)),
    ?assertEqual(2, length(cx_signing_keys:verification_keys())).

eddsa_signs_and_publishes() ->
    {Kid, JWK, JwsName} = cx_signing_keys:signing_key(),
    ?assertEqual(<<"EdDSA">>, JwsName),
    [Entry] = cx_signing_keys:jwks(),
    ?assertEqual(<<"OKP">>, maps:get(<<"kty">>, Entry)),
    ?assertEqual(<<"EdDSA">>, maps:get(<<"alg">>, Entry)),
    ?assertNot(maps:is_key(<<"d">>, Entry)),
    Token = compact(JWK, JwsName, Kid),
    [{Kid, PubJWK}] = cx_signing_keys:verification_keys(),
    ?assertMatch({true, _, _}, jose_jwt:verify_strict(PubJWK, [<<"EdDSA">>], Token)).

symmetric_has_no_jwks() ->
    {Kid, JWK, JwsName} = cx_signing_keys:signing_key(),
    ?assertEqual(<<"HS256">>, JwsName),
    %% a shared secret has no public half — it MUST NOT reach the JWKS
    ?assertEqual([], cx_signing_keys:jwks()),
    %% but it still verifies, against the secret itself
    Token = compact(JWK, JwsName, Kid),
    [{Kid, SecretJWK}] = cx_signing_keys:verification_keys(),
    ?assertMatch({true, _, _}, jose_jwt:verify_strict(SecretJWK, [<<"HS256">>], Token)).

compact(JWK, JwsName, Kid) ->
    Signed = jose_jwt:sign(JWK, #{<<"alg">> => JwsName, <<"kid">> => Kid}, #{<<"sub">> => <<"s">>}),
    {_, Token} = jose_jws:compact(Signed),
    Token.
