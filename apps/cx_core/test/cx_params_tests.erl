-module(cx_params_tests).

-include_lib("eunit/include/eunit.hrl").

optional_boolean_test_() ->
    [
        ?_assertEqual(
            {ok, true},
            cx_params:optional_boolean(#{<<"active">> => true}, <<"active">>, false)
        ),
        ?_assertEqual(
            {ok, false},
            cx_params:optional_boolean(#{<<"active">> => false}, <<"active">>, true)
        ),
        ?_assertEqual(
            {ok, default},
            cx_params:optional_boolean(#{}, <<"active">>, default)
        ),
        ?_assertEqual(
            {error, {invalid, <<"active">>}},
            cx_params:optional_boolean(#{<<"active">> => <<"true">>}, <<"active">>, false)
        ),
        ?_assertEqual(
            {error, {invalid, <<"active">>}},
            cx_params:optional_boolean(#{<<"active">> => null}, <<"active">>, false)
        ),
        ?_assertEqual(
            {error, {invalid, <<"active">>}},
            cx_params:optional_boolean(#{<<"active">> => 1}, <<"active">>, false)
        )
    ].
