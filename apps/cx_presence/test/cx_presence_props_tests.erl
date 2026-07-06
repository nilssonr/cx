-module(cx_presence_props_tests).

%% PropEr properties for the presence pure core, wrapped in EUnit so
%% plain `rebar3 eunit` runs them.
%% eqWAlizer-exempt: PropEr's macro-generated generator code doesn't
%% typecheck; the module under test (cx_presence_calculation) is fully checked.

-eqwalizer(ignore).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

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
            {no_devices_dominance, prop_no_devices_dominance()},
            {until_expiry_monotone, prop_until_expiry_monotone()},
            {manual_over_automatic, prop_manual_over_automatic()},
            {away_iff_idle, prop_away_iff_idle()},
            {totality, prop_totality()},
            {message_survives_offline, prop_message_survives_offline()}
        ]
    ).

%% ---- generators ----

manual() ->
    oneof([undefined | cx_presence_state:all()]).

message() ->
    oneof([undefined, <<"m">>, <<"In Spain for two weeks">>]).

until_gen() ->
    oneof([undefined, choose(0, 2000000)]).

declared() ->
    ?LET(
        {S, M, U},
        {manual(), message(), until_gen()},
        #{manual_state => S, message => M, until => U}
    ).

now_gen() -> choose(0, 2000000).
activity() -> choose(0, 2000000).
devices() -> choose(0, 4).
threshold() -> choose(1, 600000).

%% ---- properties ----

%% Zero devices always renders offline, whatever is declared.
prop_no_devices_dominance() ->
    ?FORALL(
        {D, LA, Now, Thr},
        {declared(), activity(), now_gen(), threshold()},
        maps:get(state, cx_presence_calculation:effective(D, 0, LA, Now, Thr)) =:=
            <<"offline">>
    ).

%% Once until has expired, advancing time never resurrects the manual
%% layer: the result equals the fully-automatic result at every later
%% point.
prop_until_expiry_monotone() ->
    ?FORALL(
        {D, Devs, LA, Now1, Now2, Thr},
        {declared(), devices(), activity(), now_gen(), now_gen(), threshold()},
        ?IMPLIES(
            is_integer(maps:get(until, D)) andalso
                maps:get(until, D) =< min(Now1, Now2),
            begin
                [Lo, Hi] = lists:sort([Now1, Now2]),
                Auto = D#{manual_state => undefined, message => undefined, until => undefined},
                cx_presence_calculation:effective(D, Devs, LA, Lo, Thr) =:=
                    cx_presence_calculation:effective(Auto, Devs, LA, Lo, Thr) andalso
                    cx_presence_calculation:effective(D, Devs, LA, Hi, Thr) =:=
                        cx_presence_calculation:effective(Auto, Devs, LA, Hi, Thr)
            end
        )
    ).

%% Connected + unexpired manual state: the manual state wins regardless
%% of activity.
prop_manual_over_automatic() ->
    ?FORALL(
        {D, Devs, LA, Now, Thr},
        {declared(), choose(1, 4), activity(), now_gen(), threshold()},
        ?IMPLIES(
            maps:get(manual_state, D) =/= undefined andalso
                (maps:get(until, D) =:= undefined orelse maps:get(until, D) > Now),
            maps:get(state, cx_presence_calculation:effective(D, Devs, LA, Now, Thr)) =:=
                maps:get(manual_state, D)
        )
    ).

%% Fully automatic + connected: away iff idle >= threshold, else online.
prop_away_iff_idle() ->
    ?FORALL(
        {Devs, LA, Now, Thr},
        {choose(1, 4), activity(), now_gen(), threshold()},
        begin
            Auto = #{manual_state => undefined, message => undefined, until => undefined},
            State = maps:get(state, cx_presence_calculation:effective(Auto, Devs, LA, Now, Thr)),
            case Now - LA >= Thr of
                true -> State =:= <<"away">>;
                false -> State =:= <<"online">>
            end
        end
    ).

%% The result state is always a member of the product vocabulary.
prop_totality() ->
    ?FORALL(
        {D, Devs, LA, Now, Thr},
        {declared(), devices(), activity(), now_gen(), threshold()},
        cx_presence_state:is_valid(
            maps:get(state, cx_presence_calculation:effective(D, Devs, LA, Now, Thr))
        )
    ).

%% An unexpired message is returned verbatim in every branch, including
%% offline.
prop_message_survives_offline() ->
    ?FORALL(
        {D, Devs, LA, Now, Thr},
        {declared(), devices(), activity(), now_gen(), threshold()},
        ?IMPLIES(
            maps:get(until, D) =:= undefined orelse maps:get(until, D) > Now,
            maps:get(message, cx_presence_calculation:effective(D, Devs, LA, Now, Thr)) =:=
                maps:get(message, D)
        )
    ).
