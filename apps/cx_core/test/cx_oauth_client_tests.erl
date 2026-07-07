-module(cx_oauth_client_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("cx_core/include/cx_core.hrl").

client_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            fun confidential_auth/0,
            fun public_needs_no_secret/0,
            fun wrong_secret_rejected/0,
            fun unknown_client_rejected/0,
            fun seed_is_idempotent/0
        ]
    end}.

setup() ->
    Dir =
        "_build/eunit-mnesia-oauthclient-" ++
            integer_to_list(erlang:system_time(microsecond)) ++
            "-" ++ integer_to_list(erlang:unique_integer([positive])),
    application:set_env(cx_core, mnesia_dir, Dir),
    ok = cx_db:init(),
    ok.

cleanup(_) ->
    mnesia:stop(),
    ok.

confidential_auth() ->
    ok = cx_oauth_client:ensure_seed(#{
        client_id => <<"c1">>,
        type => confidential,
        secret => <<"s3cret">>,
        tenant_id => <<"t1">>,
        grant_types => [<<"client_credentials">>]
    }),
    ?assertMatch(
        {ok, #cx_oauth_client{client_id = <<"c1">>}},
        cx_oauth_client:authenticate(<<"c1">>, <<"s3cret">>)
    ).

public_needs_no_secret() ->
    ok = cx_oauth_client:ensure_seed(#{
        client_id => <<"spa">>, type => public, grant_types => [<<"authorization_code">>]
    }),
    ?assertMatch({ok, _}, cx_oauth_client:authenticate(<<"spa">>, undefined)).

wrong_secret_rejected() ->
    ok = cx_oauth_client:ensure_seed(#{
        client_id => <<"c2">>, type => confidential, secret => <<"right">>
    }),
    ?assertEqual({error, invalid_client}, cx_oauth_client:authenticate(<<"c2">>, <<"wrong">>)).

unknown_client_rejected() ->
    ?assertEqual({error, invalid_client}, cx_oauth_client:authenticate(<<"ghost">>, <<"x">>)).

seed_is_idempotent() ->
    Spec = #{client_id => <<"c3">>, type => public, grant_types => []},
    ok = cx_oauth_client:ensure_seed(Spec),
    ok = cx_oauth_client:ensure_seed(Spec),
    ?assertMatch({ok, #cx_oauth_client{client_id = <<"c3">>}}, cx_oauth_client:fetch(<<"c3">>)).
