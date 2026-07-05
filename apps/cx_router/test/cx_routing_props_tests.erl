-module(cx_routing_props_tests).

%% PropEr properties for the routing core, wrapped in EUnit so plain
%% `rebar3 eunit` runs them (proper is a test-profile dep).
%% eqWAlizer-exempt: PropEr's macro-generated generator code doesn't
%% typecheck; the module under test (cx_routing) is fully checked.

-eqwalizer(ignore).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("cx_core/include/cx_core.hrl").

-define(NUMTESTS, 300).

props_test_() ->
    {timeout, 300, fun run_all/0}.

run_all() ->
    lists:foreach(
        fun({Name, Prop}) ->
            case proper:quickcheck(Prop, [{numtests, ?NUMTESTS}, quiet]) of
                true -> ok;
                _ -> error({property_failed, Name, proper:counterexample()})
            end
        end,
        [
            {deny_wins_guards, prop_deny_wins_guards()},
            {lower_total_cap_monotone, prop_lower_total_cap_monotone()},
            {total_cap_invariant, prop_total_cap_invariant()},
            {widening_monotone, prop_widening_monotone()},
            {eligible_superset_over_time, prop_eligible_superset_over_time()}
        ]
    ).

%% ---- generators ----

media() ->
    oneof([<<"chat">>, <<"email">>, <<"voice">>, <<"open_media">>, <<"social">>]).

mix() ->
    ?LET(Pairs, list({media(), choose(0, 5)}), maps:from_list(Pairs)).

guard() ->
    ?LET(
        {W, Gte, Block},
        {media(), choose(1, 5), non_empty(list(media()))},
        #rp_guard{when_media = W, gte = Gte, block = lists:usort(Block)}
    ).

profile() ->
    ?LET(
        {MaxTotal, Caps, Guards},
        {
            oneof([unlimited, choose(1, 10)]),
            ?LET(Pairs, list({media(), choose(0, 5)}), maps:from_list(Pairs)),
            list(guard())
        },
        #cx_routing_profile{
            key = {<<"t">>, <<"p">>},
            name = <<"p">>,
            max_total = MaxTotal,
            media_caps = Caps,
            guards = Guards
        }
    ).

%% Valid skill_req: widening sorted ascending by after_ms with
%% non-increasing ranks bounded by the base rank (as config validation
%% enforces).
skill_req() ->
    ?LET(
        {SkillId, Base, RawSteps},
        {
            oneof([<<"s1">>, <<"s2">>, <<"s3">>]),
            choose(1, 10),
            list({choose(1, 120000), choose(1, 10)})
        },
        begin
            Afters = lists:usort([A || {A, _} <- RawSteps]),
            Ranks = lists:sublist(
                lists:reverse(lists:sort([min(R, Base) || {_, R} <- RawSteps])),
                length(Afters)
            ),
            #skill_req{
                skill_id = SkillId,
                min_rank = Base,
                widening = lists:zip(Afters, Ranks)
            }
        end
    ).

snapshot() ->
    ?LET(
        {N, Ranks},
        {choose(1, 1000000), vector(3, choose(0, 10))},
        begin
            Skills = maps:from_list(
                [
                    {S, R}
                 || {S, R} <- lists:zip([<<"s1">>, <<"s2">>, <<"s3">>], Ranks),
                    R > 0
                ]
            ),
            #{
                agent_id => integer_to_binary(N),
                pid => undefined,
                ready => #{<<"open_media">> => ready},
                mix => #{},
                wrapup_until => 0,
                skills => Skills,
                profile => #cx_routing_profile{
                    key = {<<"t">>, <<"p">>},
                    name = <<"p">>
                },
                idle_since => 0
            }
        end
    ).

%% ---- properties ----

%% Adding a guard can only remove permissions, never grant them.
prop_deny_wins_guards() ->
    ?FORALL(
        {P, Mix, Media, G},
        {profile(), mix(), media(), guard()},
        begin
            With = P#cx_routing_profile{guards = [G | P#cx_routing_profile.guards]},
            not cx_routing:can_route(With, Mix, Media) orelse
                cx_routing:can_route(P, Mix, Media)
        end
    ).

%% Lowering the total cap can only remove permissions.
prop_lower_total_cap_monotone() ->
    ?FORALL(
        {P, Mix, Media, N1, N2},
        {profile(), mix(), media(), choose(1, 10), choose(1, 10)},
        begin
            [Lo, Hi] = lists:sort([N1, N2]),
            not cx_routing:can_route(P#cx_routing_profile{max_total = Lo}, Mix, Media) orelse
                cx_routing:can_route(P#cx_routing_profile{max_total = Hi}, Mix, Media)
        end
    ).

%% A full agent (total >= max_total) can never be routed anything.
prop_total_cap_invariant() ->
    ?FORALL(
        {P, Mix, Media, N},
        {profile(), mix(), media(), choose(1, 10)},
        ?IMPLIES(
            lists:sum(maps:values(Mix)) >= N,
            not cx_routing:can_route(
                P#cx_routing_profile{max_total = N},
                Mix,
                Media
            )
        )
    ).

%% Waiting longer never raises a requirement.
prop_widening_monotone() ->
    ?FORALL(
        {Req, T1, T2},
        {skill_req(), choose(0, 200000), choose(0, 200000)},
        begin
            [Lo, Hi] = lists:sort([T1, T2]),
            [{_, RankEarly}] = cx_routing:effective_requirements([Req], Lo),
            [{_, RankLate}] = cx_routing:effective_requirements([Req], Hi),
            RankLate =< RankEarly
        end
    ).

%% The eligible agent set only grows as an interaction waits.
prop_eligible_superset_over_time() ->
    ?FORALL(
        {Reqs, Snaps, T1, T2},
        {
            non_empty(list(skill_req())),
            non_empty(list(snapshot())),
            choose(0, 200000),
            choose(0, 200000)
        },
        begin
            [Lo, Hi] = lists:sort([T1, T2]),
            Media = <<"open_media">>,
            Early = cx_routing:eligible(
                Media,
                cx_routing:effective_requirements(Reqs, Lo),
                Snaps,
                0
            ),
            Late = cx_routing:eligible(
                Media,
                cx_routing:effective_requirements(Reqs, Hi),
                Snaps,
                0
            ),
            lists:all(fun(S) -> lists:member(S, Late) end, Early)
        end
    ).
