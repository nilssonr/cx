-module(cx_oauth_client_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("cx_core/include/cx_core.hrl").

client_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            fun config_client_resolves_public/0,
            fun confidential_client_in_mnesia/0,
            fun config_shadows_mnesia/0,
            fun unknown_client_rejected/0
        ]
    end}.

setup() ->
    Dir =
        "_build/eunit-mnesia-oauthclient-" ++
            integer_to_list(erlang:system_time(microsecond)) ++
            "-" ++ integer_to_list(erlang:unique_integer([positive])),
    application:set_env(cx_core, mnesia_dir, Dir),
    application:set_env(cx_auth, first_party_clients, [
        #{
            client_id => <<"spa">>,
            type => public,
            grant_types => [<<"authorization_code">>],
            redirect_uris => [<<"https://app/cb">>],
            scopes => [<<"openid">>]
        }
    ]),
    ok = cx_db:init(),
    ok.

cleanup(_) ->
    application:unset_env(cx_auth, first_party_clients),
    mnesia:stop(),
    ok.

%% Internal app declared in config, resolved live — no Mnesia row, no secret.
config_client_resolves_public() ->
    ?assertMatch(
        {ok, #cx_oauth_client{client_id = <<"spa">>, client_type = public, secret_hash = undefined}},
        cx_oauth_client:fetch(<<"spa">>)
    ),
    ?assertMatch({ok, _}, cx_oauth_client:authenticate(<<"spa">>, undefined)).

confidential_client_in_mnesia() ->
    ok = cx_oauth_client:store(#{
        client_id => <<"svc">>,
        type => confidential,
        secret => <<"s3cret">>,
        tenant_id => <<"t1">>,
        grant_types => [<<"client_credentials">>]
    }),
    ?assertMatch(
        {ok, #cx_oauth_client{client_type = confidential}},
        cx_oauth_client:authenticate(<<"svc">>, <<"s3cret">>)
    ),
    ?assertEqual({error, invalid_client}, cx_oauth_client:authenticate(<<"svc">>, <<"wrong">>)).

%% A config-declared id wins over a Mnesia row of the same id — a runtime
%% client can never hijack an internal app's identity.
config_shadows_mnesia() ->
    ok = cx_oauth_client:store(#{client_id => <<"spa">>, type => confidential, secret => <<"x">>}),
    ?assertMatch(
        {ok, #cx_oauth_client{client_type = public}}, cx_oauth_client:fetch(<<"spa">>)
    ).

unknown_client_rejected() ->
    ?assertEqual({error, invalid_client}, cx_oauth_client:authenticate(<<"ghost">>, <<"x">>)).
