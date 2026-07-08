-module(cx_provider_session_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("cx_core/include/cx_core.hrl").

session_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            fun create_and_fetch/0,
            fun idle_expiry/0,
            fun touch_extends_idle/0,
            fun destroy/0,
            fun destroy_for_subject/0
        ]
    end}.

setup() ->
    Dir =
        "_build/eunit-mnesia-session-" ++
            integer_to_list(erlang:system_time(microsecond)) ++
            "-" ++ integer_to_list(erlang:unique_integer([positive])),
    application:set_env(cx_core, mnesia_dir, Dir),
    ok = cx_db:init(),
    ok.

cleanup(_) ->
    application:unset_env(cx_auth, session_idle_ttl_s),
    mnesia:stop(),
    ok.

create_and_fetch() ->
    {Id, _} = cx_provider_session:create(<<"alice">>, false),
    ?assertMatch({ok, #cx_provider_session{subject = <<"alice">>}}, cx_provider_session:fetch(Id)),
    ?assertEqual({error, not_found}, cx_provider_session:fetch(<<"nope">>)).

idle_expiry() ->
    application:set_env(cx_auth, session_idle_ttl_s, 0),
    {Id, _} = cx_provider_session:create(<<"bob">>, false),
    timer:sleep(2),
    ?assertEqual({error, expired}, cx_provider_session:fetch(Id)),
    application:unset_env(cx_auth, session_idle_ttl_s).

touch_extends_idle() ->
    {Id, _} = cx_provider_session:create(<<"carol">>, false),
    {ok, Session} = cx_provider_session:fetch(Id),
    ok = cx_provider_session:touch(Session),
    ?assertMatch({ok, _}, cx_provider_session:fetch(Id)).

destroy() ->
    {Id, _} = cx_provider_session:create(<<"dave">>, false),
    ok = cx_provider_session:destroy(Id),
    ?assertEqual({error, not_found}, cx_provider_session:fetch(Id)).

destroy_for_subject() ->
    {Id1, _} = cx_provider_session:create(<<"erin">>, false),
    {Id2, _} = cx_provider_session:create(<<"erin">>, true),
    ok = cx_provider_session:destroy_for_subject(<<"erin">>),
    ?assertEqual({error, not_found}, cx_provider_session:fetch(Id1)),
    ?assertEqual({error, not_found}, cx_provider_session:fetch(Id2)).
