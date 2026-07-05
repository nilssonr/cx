-module(cx_event_tests).

-include_lib("eunit/include/eunit.hrl").

event_test_() ->
    {setup, fun cx_test_support:ensure_pg/0, fun(_) -> ok end, fun(_) ->
        [
            fun tenant_subscription/0,
            fun queue_subscription/0,
            fun dedup_across_groups/0,
            fun tenant_isolation/0
        ]
    end}.

tenant_subscription() ->
    ok = cx_event:subscribe(<<"t1">>),
    ok = cx_event:publish(<<"t1">>, <<"q1">>, <<"open_media">>, test, #{tag => a}),
    ?assertMatch(
        {<<"t1">>, <<"q1">>, <<"open_media">>, #{type := test, at := At, data := #{tag := a}}} when
            is_integer(At),
        recv()
    ),
    ok = cx_event:unsubscribe(<<"t1">>).

queue_subscription() ->
    ok = cx_event:subscribe(<<"t1">>, <<"q1">>),
    ok = cx_event:publish(<<"t1">>, <<"q1">>, <<"open_media">>, test, #{tag => b}),
    ?assertMatch(
        {<<"t1">>, <<"q1">>, <<"open_media">>, #{type := test, data := #{tag := b}}},
        recv()
    ),
    ok = cx_event:publish(<<"t1">>, <<"q2">>, <<"open_media">>, test, #{tag => c}),
    ?assertEqual(timeout, recv()),
    ok = cx_event:unsubscribe(<<"t1">>, <<"q1">>).

dedup_across_groups() ->
    ok = cx_event:subscribe(<<"t1">>),
    ok = cx_event:subscribe(<<"t1">>, <<"q1">>),
    ok = cx_event:publish(<<"t1">>, <<"q1">>, <<"open_media">>, test, #{tag => d}),
    ?assertMatch(
        {<<"t1">>, <<"q1">>, <<"open_media">>, #{type := test, data := #{tag := d}}},
        recv()
    ),
    ?assertEqual(timeout, recv()),
    ok = cx_event:unsubscribe(<<"t1">>),
    ok = cx_event:unsubscribe(<<"t1">>, <<"q1">>).

tenant_isolation() ->
    ok = cx_event:subscribe(<<"t1">>),
    ok = cx_event:publish(<<"t2">>, <<"q1">>, <<"open_media">>, test, #{tag => e}),
    ?assertEqual(timeout, recv()),
    ok = cx_event:unsubscribe(<<"t1">>).

recv() ->
    receive
        {cx_event, Payload} -> Payload
    after 200 -> timeout
    end.
