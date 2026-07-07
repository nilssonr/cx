-module(cx_authorization_code_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("cx_core/include/cx_core.hrl").

code_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            fun consume_is_single_use/0,
            fun expired_code_rejected/0
        ]
    end}.

setup() ->
    Dir =
        "_build/eunit-mnesia-authcode-" ++
            integer_to_list(erlang:system_time(microsecond)) ++
            "-" ++ integer_to_list(erlang:unique_integer([positive])),
    application:set_env(cx_core, mnesia_dir, Dir),
    ok = cx_db:init(),
    ok.

cleanup(_) ->
    mnesia:stop(),
    ok.

args() ->
    #{
        client_id => <<"c1">>,
        subject => <<"u1">>,
        tenant_id => <<"t1">>,
        redirect_uri => <<"https://app/cb">>,
        code_challenge => <<"abc">>,
        code_challenge_method => <<"S256">>,
        scope => [<<"openid">>]
    }.

consume_is_single_use() ->
    Code = cx_authorization_code:issue(args()),
    ?assertMatch(
        {ok, #cx_authorization_code{subject = <<"u1">>}}, cx_authorization_code:consume(Code)
    ),
    %% a replayed code finds nothing
    ?assertEqual({error, invalid}, cx_authorization_code:consume(Code)).

expired_code_rejected() ->
    application:set_env(cx_auth, authorization_code_ttl_s, 0),
    try
        Code = cx_authorization_code:issue(args()),
        timer:sleep(2),
        ?assertEqual({error, expired}, cx_authorization_code:consume(Code))
    after
        application:unset_env(cx_auth, authorization_code_ttl_s)
    end.
