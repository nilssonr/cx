-module(cx_refresh_token_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("cx_core/include/cx_core.hrl").

refresh_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            fun issue_and_redeem/0,
            fun rotation_invalidates_the_old/0,
            fun revoke_family_kills_all/0,
            fun find_hit_and_miss/0,
            fun revoke_is_idempotent/0,
            fun revoke_by_session_isolates/0,
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

%% find/1 returns the raw row (no liveness classification) or not_found.
find_hit_and_miss() ->
    {Handle, _} = cx_refresh_token:issue(args(<<"u-find">>)),
    ?assertMatch({ok, #cx_refresh_token{subject = <<"u-find">>}}, cx_refresh_token:find(Handle)),
    ?assertEqual({error, not_found}, cx_refresh_token:find(<<"no-such-handle">>)).

%% revoke/1 accepts a row and is idempotent — revoking a dead token still ok.
revoke_is_idempotent() ->
    {Handle, Rec} = cx_refresh_token:issue(args(<<"u-rev">>)),
    ok = cx_refresh_token:revoke(Rec),
    ?assertMatch({error, {reuse, _}}, cx_refresh_token:redeem(Handle)),
    %% revoking again (via the freshly read row) is still ok
    {ok, Again} = cx_refresh_token:find(Handle),
    ?assertEqual(ok, cx_refresh_token:revoke(Again)).

%% revoke_by_session/1 kills exactly the named session's tokens, no others.
revoke_by_session_isolates() ->
    Keep = <<"session-keep">>,
    Kill = <<"session-kill">>,
    {HKeep, _} = cx_refresh_token:issue((args(<<"u-sess">>))#{session_id => Keep}),
    {HKill, _} = cx_refresh_token:issue((args(<<"u-sess">>))#{session_id => Kill}),
    ok = cx_refresh_token:revoke_by_session(Kill),
    ?assertMatch({error, {reuse, _}}, cx_refresh_token:redeem(HKill)),
    ?assertMatch({ok, _}, cx_refresh_token:redeem(HKeep)).

expiry() ->
    application:set_env(cx_auth, token_refresh_ttl_s, 0),
    try
        {Handle, _} = cx_refresh_token:issue(args(<<"u4">>)),
        timer:sleep(2),
        ?assertEqual({error, expired}, cx_refresh_token:redeem(Handle))
    after
        application:unset_env(cx_auth, token_refresh_ttl_s)
    end.
