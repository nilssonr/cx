-module(cx_event_tests).

-include_lib("eunit/include/eunit.hrl").

event_test_() ->
    {setup,
     fun cx_test_support:ensure_pg/0,
     fun(_) -> ok end,
     fun(_) ->
         [
          fun tenant_subscription/0,
          fun queue_subscription/0,
          fun dedup_across_groups/0,
          fun tenant_isolation/0
         ]
     end}.

tenant_subscription() ->
    ok = cx_event:subscribe(<<"t1">>),
    ok = cx_event:publish(<<"t1">>, <<"q1">>, <<"open_media">>, ev(a)),
    ?assertEqual({<<"t1">>, <<"q1">>, <<"open_media">>, ev(a)}, recv()),
    ok = cx_event:unsubscribe(<<"t1">>).

queue_subscription() ->
    ok = cx_event:subscribe(<<"t1">>, <<"q1">>),
    ok = cx_event:publish(<<"t1">>, <<"q1">>, <<"open_media">>, ev(b)),
    ?assertEqual({<<"t1">>, <<"q1">>, <<"open_media">>, ev(b)}, recv()),
    ok = cx_event:publish(<<"t1">>, <<"q2">>, <<"open_media">>, ev(c)),
    ?assertEqual(timeout, recv()),
    ok = cx_event:unsubscribe(<<"t1">>, <<"q1">>).

dedup_across_groups() ->
    ok = cx_event:subscribe(<<"t1">>),
    ok = cx_event:subscribe(<<"t1">>, <<"q1">>),
    ok = cx_event:publish(<<"t1">>, <<"q1">>, <<"open_media">>, ev(d)),
    ?assertEqual({<<"t1">>, <<"q1">>, <<"open_media">>, ev(d)}, recv()),
    ?assertEqual(timeout, recv()),
    ok = cx_event:unsubscribe(<<"t1">>),
    ok = cx_event:unsubscribe(<<"t1">>, <<"q1">>).

tenant_isolation() ->
    ok = cx_event:subscribe(<<"t1">>),
    ok = cx_event:publish(<<"t2">>, <<"q1">>, <<"open_media">>, ev(e)),
    ?assertEqual(timeout, recv()),
    ok = cx_event:unsubscribe(<<"t1">>).

ev(Tag) ->
    #{type => test, at => 0, data => #{tag => Tag}}.

recv() ->
    receive {cx_event, Payload} -> Payload
    after 200 -> timeout
    end.
