-module(cx_routing_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("cx_core/include/cx_core.hrl").

-define(CHAT, <<"chat">>).
-define(EMAIL, <<"email">>).
-define(VOICE, <<"voice">>).

profile() ->
    profile(unlimited, #{}, []).

profile(MaxTotal, Caps, Guards) ->
    #cx_routing_profile{
        key = {<<"t">>, <<"p">>},
        name = <<"p">>,
        max_total = MaxTotal,
        media_caps = Caps,
        guards = Guards
    }.

empty_profile_blocks_nothing_test() ->
    Mix = #{?CHAT => 6, ?EMAIL => 3, ?VOICE => 2},
    ?assert(cx_routing:can_route(profile(), Mix, ?CHAT)).

total_cap_test() ->
    P = profile(3, #{}, []),
    ?assert(cx_routing:can_route(P, #{?CHAT => 2}, ?EMAIL)),
    ?assertNot(cx_routing:can_route(P, #{?CHAT => 2, ?EMAIL => 1}, ?EMAIL)).

media_cap_test() ->
    P = profile(unlimited, #{?CHAT => 2}, []),
    ?assert(cx_routing:can_route(P, #{?CHAT => 1}, ?CHAT)),
    ?assertNot(cx_routing:can_route(P, #{?CHAT => 2}, ?CHAT)),
    %% other media unaffected by chat's cap
    ?assert(cx_routing:can_route(P, #{?CHAT => 2}, ?EMAIL)).

guard_test() ->
    %% "If I am already handling one phone call, don't route me chats or emails"
    G = #rp_guard{when_media = ?VOICE, gte = 1, block = [?CHAT, ?EMAIL]},
    P = profile(unlimited, #{}, [G]),
    ?assertNot(cx_routing:can_route(P, #{?VOICE => 1}, ?CHAT)),
    ?assertNot(cx_routing:can_route(P, #{?VOICE => 1}, ?EMAIL)),
    ?assert(cx_routing:can_route(P, #{?VOICE => 1}, ?VOICE)),
    ?assert(cx_routing:can_route(P, #{?VOICE => 0}, ?CHAT)),
    ?assert(cx_routing:can_route(P, #{}, ?CHAT)).

guard_threshold_test() ->
    %% "If I'm handling more than two emails, do not route me chats"
    G = #rp_guard{when_media = ?EMAIL, gte = 3, block = [?CHAT]},
    P = profile(unlimited, #{}, [G]),
    ?assert(cx_routing:can_route(P, #{?EMAIL => 2}, ?CHAT)),
    ?assertNot(cx_routing:can_route(P, #{?EMAIL => 3}, ?CHAT)).

effective_requirements_test() ->
    Req = #skill_req{
        skill_id = <<"s1">>,
        min_rank = 3,
        widening = [{30000, 2}, {60000, 1}]
    },
    ?assertEqual([{<<"s1">>, 3}], cx_routing:effective_requirements([Req], 0)),
    ?assertEqual([{<<"s1">>, 3}], cx_routing:effective_requirements([Req], 29999)),
    ?assertEqual([{<<"s1">>, 2}], cx_routing:effective_requirements([Req], 30000)),
    ?assertEqual([{<<"s1">>, 1}], cx_routing:effective_requirements([Req], 600000)).

skill_match_test() ->
    Skills = #{<<"s1">> => 2, <<"s2">> => 5},
    ?assert(cx_routing:skill_match(Skills, [{<<"s1">>, 2}])),
    ?assert(cx_routing:skill_match(Skills, [{<<"s1">>, 1}, {<<"s2">>, 5}])),
    ?assertNot(cx_routing:skill_match(Skills, [{<<"s1">>, 3}])),
    ?assertNot(cx_routing:skill_match(Skills, [{<<"missing">>, 1}])),
    ?assert(cx_routing:skill_match(Skills, [])).

snapshot(Id, Overrides) ->
    maps:merge(
        #{
            agent_id => Id,
            pid => self(),
            ready => #{?CHAT => ready},
            mix => #{},
            wrapup_until => 0,
            skills => #{},
            profile => profile(),
            idle_since => 0
        },
        Overrides
    ).

routable_test() ->
    Now = 1000,
    ?assert(cx_routing:routable(snapshot(<<"a">>, #{}), ?CHAT, Now)),
    %% not ready for the media
    ?assertNot(cx_routing:routable(snapshot(<<"a">>, #{}), ?EMAIL, Now)),
    %% explicitly not ready
    NotReady = snapshot(<<"a">>, #{ready => #{?CHAT => {not_ready, <<"lunch">>}}}),
    ?assertNot(cx_routing:routable(NotReady, ?CHAT, Now)),
    %% in wrap-up
    InWrapup = snapshot(<<"a">>, #{wrapup_until => Now + 1}),
    ?assertNot(cx_routing:routable(InWrapup, ?CHAT, Now)),
    WrapupOver = snapshot(<<"a">>, #{wrapup_until => Now}),
    ?assert(cx_routing:routable(WrapupOver, ?CHAT, Now)),
    %% profile denies
    Full = snapshot(<<"a">>, #{
        profile => profile(1, #{}, []),
        mix => #{?CHAT => 1}
    }),
    ?assertNot(cx_routing:routable(Full, ?CHAT, Now)).

eligible_test() ->
    Reqs = [{<<"s1">>, 2}],
    A = snapshot(<<"a">>, #{skills => #{<<"s1">> => 3}}),
    B = snapshot(<<"b">>, #{skills => #{<<"s1">> => 1}}),
    C = snapshot(<<"c">>, #{
        skills => #{<<"s1">> => 2},
        ready => #{?EMAIL => ready}
    }),
    ?assertEqual([A], cx_routing:eligible(?CHAT, Reqs, [A, B, C], 0)).

rank_test() ->
    Reqs = [{<<"s1">>, 1}],
    HighSkill = snapshot(<<"high">>, #{skills => #{<<"s1">> => 5}}),
    LowSkillIdle = snapshot(<<"idle">>, #{
        skills => #{<<"s1">> => 2},
        idle_since => 100
    }),
    LowSkillBusy = snapshot(<<"busy">>, #{
        skills => #{<<"s1">> => 2},
        mix => #{?CHAT => 2},
        idle_since => 50
    }),
    LowSkillFresh = snapshot(<<"fresh">>, #{
        skills => #{<<"s1">> => 2},
        idle_since => 200
    }),
    Ranked = cx_routing:rank(Reqs, [LowSkillBusy, LowSkillFresh, HighSkill, LowSkillIdle]),
    ?assertEqual(
        [<<"high">>, <<"idle">>, <<"fresh">>, <<"busy">>],
        [maps:get(agent_id, S) || S <- Ranked]
    ).
