-module(cx_presence_calculation_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("cx_core/include/cx_core.hrl").

-define(THR, 300000).

decl(Manual, Message, Until) ->
    #{manual_state => Manual, message => Message, until => Until}.

auto() -> decl(undefined, undefined, undefined).

no_devices_is_offline_test() ->
    ?assertEqual(
        #{state => <<"offline">>, message => undefined},
        cx_presence_calculation:effective(auto(), 0, 1000, 2000, ?THR)
    ).

offline_keeps_message_test() ->
    %% "In Spain for two weeks" is visible even while disconnected
    D = decl(<<"out_of_office">>, <<"In Spain for two weeks">>, undefined),
    ?assertEqual(
        #{state => <<"offline">>, message => <<"In Spain for two weeks">>},
        cx_presence_calculation:effective(D, 0, 0, 1000, ?THR)
    ).

manual_wins_over_activity_test() ->
    D = decl(<<"dnd">>, undefined, undefined),
    ?assertEqual(
        #{state => <<"dnd">>, message => undefined},
        cx_presence_calculation:effective(D, 2, 1000, 1001, ?THR)
    ).

idle_at_threshold_is_away_test() ->
    Now = 1000000,
    ?assertEqual(
        #{state => <<"away">>, message => undefined},
        cx_presence_calculation:effective(auto(), 1, Now - ?THR, Now, ?THR)
    ),
    ?assertEqual(
        #{state => <<"online">>, message => undefined},
        cx_presence_calculation:effective(auto(), 1, Now - ?THR + 1, Now, ?THR)
    ).

until_at_now_is_expired_test() ->
    D = decl(<<"busy">>, <<"m">>, 5000),
    %% at exactly `until` the manual layer is gone
    ?assertEqual(
        #{state => <<"online">>, message => undefined},
        cx_presence_calculation:effective(D, 1, 5000, 5000, ?THR)
    ),
    %% just before, it holds
    ?assertEqual(
        #{state => <<"busy">>, message => <<"m">>},
        cx_presence_calculation:effective(D, 1, 4999, 4999, ?THR)
    ).

expired_until_strips_message_even_offline_test() ->
    D = decl(undefined, <<"stale">>, 5000),
    ?assertEqual(
        #{state => <<"offline">>, message => undefined},
        cx_presence_calculation:effective(D, 0, 0, 6000, ?THR)
    ).

connectionless_test() ->
    Row = #cx_presence_declaration{
        key = {<<"t">>, <<"u">>},
        manual_state = <<"busy">>,
        message = <<"m">>,
        until = 5000,
        updated_at = 1
    },
    %% no row: plain offline
    ?assertEqual(
        #{state => <<"offline">>, message => undefined, until => undefined},
        cx_presence_calculation:connectionless(undefined, 1000, ?THR)
    ),
    %% live manual layer: offline (no devices) but message + until shown
    ?assertEqual(
        #{state => <<"offline">>, message => <<"m">>, until => 5000},
        cx_presence_calculation:connectionless(Row, 4999, ?THR)
    ),
    %% expired until: the whole manual layer is gone
    ?assertEqual(
        #{state => <<"offline">>, message => undefined, until => undefined},
        cx_presence_calculation:connectionless(Row, 5000, ?THR)
    ).

from_row_test() ->
    ?assertEqual(
        #{manual_state => undefined, message => undefined, until => undefined},
        cx_presence_calculation:from_row(undefined)
    ),
    Row = #cx_presence_declaration{
        key = {<<"t">>, <<"u">>},
        manual_state = <<"busy">>,
        message = <<"m">>,
        until = 42,
        updated_at = 1
    },
    ?assertEqual(
        #{manual_state => <<"busy">>, message => <<"m">>, until => 42},
        cx_presence_calculation:from_row(Row)
    ).
