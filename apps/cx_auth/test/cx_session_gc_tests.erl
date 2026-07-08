-module(cx_session_gc_tests).

-include_lib("eunit/include/eunit.hrl").

gc_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) -> [fun sweeps_only_expired/0] end}.

setup() ->
    Dir =
        "_build/eunit-mnesia-sessiongc-" ++
            integer_to_list(erlang:system_time(microsecond)) ++
            "-" ++ integer_to_list(erlang:unique_integer([positive])),
    application:set_env(cx_core, mnesia_dir, Dir),
    ok = cx_db:init(),
    {ok, Pid} = cx_session_gc:start_link(),
    Pid.

cleanup(Pid) ->
    gen_server:stop(Pid),
    application:unset_env(cx_auth, session_idle_ttl_s),
    mnesia:stop(),
    ok.

sweeps_only_expired() ->
    %% one live session, one already-expired
    {Live, _} = cx_provider_session:create(<<"live">>, false),
    application:set_env(cx_auth, session_idle_ttl_s, 0),
    {Dead, _} = cx_provider_session:create(<<"dead">>, false),
    application:unset_env(cx_auth, session_idle_ttl_s),
    timer:sleep(2),
    ?assertEqual(1, cx_session_gc:sweep()),
    %% the live one survives, the dead row is gone
    ?assertMatch({ok, _}, cx_provider_session:fetch(Live)),
    ?assertEqual({error, not_found}, cx_provider_session:fetch(Dead)).
