-module(cx_password_tests).

-include_lib("eunit/include/eunit.hrl").

%% Low iteration count keeps the suite fast; correctness is independent of it.
password_test_() ->
    {setup, fun() -> application:set_env(cx_core, password_pbkdf2_iterations, 1000) end,
        fun(_) -> application:unset_env(cx_core, password_pbkdf2_iterations) end, [
            fun roundtrip/0,
            fun distinct_salts/0,
            fun cost_travels_with_hash/0,
            fun malformed/0,
            fun dummy_is_false/0
        ]}.

roundtrip() ->
    Phc = cx_password:hash(<<"correct horse battery staple">>),
    ?assertMatch(<<"$pbkdf2-sha512$i=", _/binary>>, Phc),
    ?assert(cx_password:verify(<<"correct horse battery staple">>, Phc)),
    ?assertNot(cx_password:verify(<<"wrong">>, Phc)).

distinct_salts() ->
    %% same password, different hash — random per-hash salt
    ?assertNotEqual(cx_password:hash(<<"pw">>), cx_password:hash(<<"pw">>)).

cost_travels_with_hash() ->
    %% a hash minted at one cost still verifies after the configured cost
    %% changes — the parameters live in the PHC string (design §4)
    Phc = cx_password:hash(<<"pw">>),
    application:set_env(cx_core, password_pbkdf2_iterations, 2000),
    try
        ?assert(cx_password:verify(<<"pw">>, Phc))
    after
        application:set_env(cx_core, password_pbkdf2_iterations, 1000)
    end.

malformed() ->
    ?assertNot(cx_password:verify(<<"pw">>, <<"not-a-phc">>)),
    ?assertNot(cx_password:verify(<<"pw">>, <<>>)),
    ?assertNot(cx_password:verify(<<"pw">>, <<"$pbkdf2-sha512$i=notint$c2FsdA==$aGFzaA==">>)).

dummy_is_false() ->
    ?assertEqual(false, cx_password:verify_dummy(<<"anything">>)).
