-module(cx_refresh_token_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("cx_core/include/cx_core.hrl").

refresh_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            fun issue_and_redeem/0,
            fun rotation_invalidates_the_old/0,
            fun revoke_family_kills_all/0,
            fun expiry/0
        ]
    end}.

setup() ->
    Dir =
        "_build/eunit-mnesia-refresh-" ++
            integer_to_list(erlang:system_time(microsecond)) ++
            "-" ++ integer_to_list(erlang:unique_integer([positive])),
    application:set_env(cx_core, mnesia_dir, Dir),
    ok = cx_db:init(),
    ok.

cleanup(_) ->
    mnesia:stop(),
    ok.

args(Subject) ->
    #{subject => Subject, tenant_id => <<"t1">>, client_id => <<"c1">>, scope => [<<"openid">>]}.

issue_and_redeem() ->
    {Handle, _} = cx_refresh_token:issue(args(<<"u1">>)),
    ?assertMatch({ok, #cx_refresh_token{subject = <<"u1">>}}, cx_refresh_token:redeem(Handle)).

rotation_invalidates_the_old() ->
    {Old, Rec} = cx_refresh_token:issue(args(<<"u2">>)),
    {New, _} = cx_refresh_token:rotate(Rec, #{scope => [<<"openid">>]}),
    ?assertMatch({ok, _}, cx_refresh_token:redeem(New)),
    %% presenting the rotated-away handle is a theft signal
    ?assertMatch({error, {reuse, _}}, cx_refresh_token:redeem(Old)).

revoke_family_kills_all() ->
    {H1, R1} = cx_refresh_token:issue(args(<<"u3">>)),
    {H2, _} = cx_refresh_token:issue(args(<<"u3">>)),
    ok = cx_refresh_token:revoke_family(R1),
    ?assertMatch({error, {reuse, _}}, cx_refresh_token:redeem(H1)),
    ?assertMatch({error, {reuse, _}}, cx_refresh_token:redeem(H2)).

expiry() ->
    application:set_env(cx_auth, token_refresh_ttl_s, 0),
    try
        {Handle, _} = cx_refresh_token:issue(args(<<"u4">>)),
        timer:sleep(2),
        ?assertEqual({error, expired}, cx_refresh_token:redeem(Handle))
    after
        application:unset_env(cx_auth, token_refresh_ttl_s)
    end.
