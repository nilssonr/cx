-module(cx_jws_alg_tests).

-include_lib("eunit/include/eunit.hrl").

names_test() ->
    ?assertEqual(<<"RS256">>, cx_jws_alg:jws_name(rs256)),
    ?assertEqual(<<"PS512">>, cx_jws_alg:jws_name(ps512)),
    ?assertEqual(<<"EdDSA">>, cx_jws_alg:jws_name(eddsa)),
    ?assertEqual(<<"HS256">>, cx_jws_alg:jws_name(hs256)).

kinds_test() ->
    ?assertEqual(asymmetric, cx_jws_alg:kind(rs256)),
    ?assertEqual(asymmetric, cx_jws_alg:kind(eddsa)),
    ?assertEqual(symmetric, cx_jws_alg:kind(hs256)),
    ?assertEqual(symmetric, cx_jws_alg:kind(hs512)).

from_config_accepts_known_atoms_test() ->
    ?assertEqual({ok, rs256}, cx_jws_alg:from_config(rs256)),
    ?assertEqual({ok, eddsa}, cx_jws_alg:from_config(eddsa)),
    ?assertEqual({ok, hs384}, cx_jws_alg:from_config(hs384)).

from_config_rejects_the_rest_test() ->
    %% EC is deliberately not supported yet (jose to_public_map crash)
    ?assertEqual({error, unknown_alg}, cx_jws_alg:from_config(es256)),
    %% must be the atom, not the JWS binary
    ?assertEqual({error, unknown_alg}, cx_jws_alg:from_config(<<"RS256">>)),
    ?assertEqual({error, unknown_alg}, cx_jws_alg:from_config(made_up)),
    ?assertEqual({error, unknown_alg}, cx_jws_alg:from_config(42)).
