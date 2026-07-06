-module(cx_ws_protocol_tests).

-include_lib("eunit/include/eunit.hrl").

decode_test() ->
    ?assertEqual(
        {auth, <<"tok">>, undefined},
        cx_ws_protocol:decode(<<"{\"type\":\"auth\",\"token\":\"tok\"}">>)
    ),
    ?assertEqual(
        {auth, <<"tok">>, <<"dev-1">>},
        cx_ws_protocol:decode(
            <<"{\"type\":\"auth\",\"token\":\"tok\",\"device_id\":\"dev-1\"}">>
        )
    ),
    ?assertEqual(ping, cx_ws_protocol:decode(<<"{\"type\":\"ping\"}">>)),
    ?assertEqual(activity, cx_ws_protocol:decode(<<"{\"type\":\"activity\"}">>)),
    ?assertEqual({error, invalid_frame}, cx_ws_protocol:decode(<<"not json">>)),
    ?assertEqual({error, invalid_frame}, cx_ws_protocol:decode(<<"{\"type\":\"nope\"}">>)),
    ?assertEqual(
        {error, invalid_frame},
        cx_ws_protocol:decode(<<"{\"type\":\"auth\",\"token\":42}">>)
    ).

relevant_test() ->
    Me = <<"me">>,
    Offer = #{type => offer_created, at => 1, data => #{<<"agent_id">> => Me}},
    NotMine = #{type => offer_created, at => 1, data => #{<<"agent_id">> => <<"other">>}},
    Presence = #{type => presence_changed, at => 1, data => #{<<"user_id">> => <<"x">>}},
    Crud = #{type => queue_created, at => 1, data => #{<<"id">> => <<"q">>}},
    NoAgent = #{type => interaction_queued, at => 1, data => #{}},
    ?assert(cx_ws_protocol:relevant(Offer, Me)),
    ?assertNot(cx_ws_protocol:relevant(NotMine, Me)),
    ?assert(cx_ws_protocol:relevant(Presence, Me)),
    ?assertNot(cx_ws_protocol:relevant(Crud, Me)),
    ?assertNot(cx_ws_protocol:relevant(NoAgent, Me)).

event_frame_test() ->
    Event = #{type => offer_created, at => 42, data => #{<<"agent_id">> => <<"a">>}},
    {ok, Decoded} = cx_json:decode(cx_ws_protocol:event_frame(undefined, <<"open_media">>, Event)),
    ?assertMatch(
        #{
            <<"type">> := <<"event">>,
            <<"event">> := #{
                <<"type">> := <<"offer_created">>,
                <<"at">> := 42,
                <<"queue_id">> := null,
                <<"media_type">> := <<"open_media">>,
                <<"data">> := #{<<"agent_id">> := <<"a">>}
            }
        },
        Decoded
    ).

ready_frame_test() ->
    {ok, Decoded} = cx_json:decode(cx_ws_protocol:ready_frame(<<"u">>, <<"t">>, undefined)),
    ?assertMatch(
        #{<<"type">> := <<"ready">>, <<"user_id">> := <<"u">>, <<"device_id">> := null},
        Decoded
    ).
