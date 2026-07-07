-module(cx_identity_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("cx_core/include/cx_core.hrl").

identity_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            fun create_get_list/0,
            fun duplicate_email_rejected/0,
            fun verify_good_bad_unknown/0,
            fun disabled_refused/0,
            fun lockout_after_threshold/0,
            fun tenants_for_spans_tenants/0,
            fun seed_is_idempotent/0
        ]
    end}.

setup() ->
    Dir =
        "_build/eunit-mnesia-identity-" ++
            integer_to_list(erlang:system_time(microsecond)) ++
            "-" ++ integer_to_list(erlang:unique_integer([positive])),
    application:set_env(cx_core, mnesia_dir, Dir),
    application:set_env(cx_core, password_pbkdf2_iterations, 1000),
    application:set_env(cx_core, login_max_failures, 3),
    application:set_env(cx_core, login_lockout_ms, 60000),
    ok = cx_db:init(),
    ok.

cleanup(_) ->
    mnesia:stop(),
    ok.

%% identities:* is platform-only; a context holding both is the admin caller.
ctx() ->
    cx_authz:context(<<"platform">>, [<<"identities:read">>, <<"identities:write">>]).

create_get_list() ->
    {ok, Map} = cx_identity:create(ctx(), #{
        <<"email">> => <<"alice@x">>, <<"password">> => <<"pw-alice">>
    }),
    Subject = maps:get(<<"subject">>, Map),
    ?assertEqual(<<"alice@x">>, maps:get(<<"email">>, Map)),
    ?assertEqual(<<"active">>, maps:get(<<"status">>, Map)),
    %% credential material never crosses the serializer
    ?assertNot(maps:is_key(<<"password_hash">>, Map)),
    ?assertMatch({ok, #{<<"subject">> := _}}, cx_identity:get(ctx(), Subject)),
    {ok, List} = cx_identity:list(ctx()),
    ?assert(lists:any(fun(I) -> maps:get(<<"subject">>, I) =:= Subject end, List)).

duplicate_email_rejected() ->
    {ok, _} = cx_identity:create(ctx(), #{<<"email">> => <<"dup@x">>, <<"password">> => <<"pw">>}),
    ?assertEqual(
        {error, already_exists},
        cx_identity:create(ctx(), #{<<"email">> => <<"dup@x">>, <<"password">> => <<"pw2">>})
    ).

verify_good_bad_unknown() ->
    {ok, _} = cx_identity:create(ctx(), #{<<"email">> => <<"v@x">>, <<"password">> => <<"secret">>}),
    ?assertMatch({ok, _Subject}, cx_identity:verify_credential(<<"v@x">>, <<"secret">>)),
    ?assertEqual(
        {error, invalid_credentials}, cx_identity:verify_credential(<<"v@x">>, <<"nope">>)
    ),
    %% unknown email is invalid_credentials, not a distinct "no such user"
    ?assertEqual(
        {error, invalid_credentials}, cx_identity:verify_credential(<<"ghost@x">>, <<"x">>)
    ).

disabled_refused() ->
    {ok, Map} = cx_identity:create(ctx(), #{<<"email">> => <<"d@x">>, <<"password">> => <<"pw">>}),
    ok = cx_identity:disable(ctx(), maps:get(<<"subject">>, Map)),
    ?assertEqual({error, disabled}, cx_identity:verify_credential(<<"d@x">>, <<"pw">>)).

lockout_after_threshold() ->
    {ok, _} = cx_identity:create(ctx(), #{<<"email">> => <<"l@x">>, <<"password">> => <<"pw">>}),
    %% login_max_failures = 3 (setup)
    _ = cx_identity:verify_credential(<<"l@x">>, <<"bad">>),
    _ = cx_identity:verify_credential(<<"l@x">>, <<"bad">>),
    _ = cx_identity:verify_credential(<<"l@x">>, <<"bad">>),
    %% now locked — even the CORRECT password is refused until it lapses
    ?assertEqual({error, locked}, cx_identity:verify_credential(<<"l@x">>, <<"pw">>)).

tenants_for_spans_tenants() ->
    {ok, Map} = cx_identity:create(ctx(), #{
        <<"email">> => <<"multi@x">>, <<"password">> => <<"pw">>
    }),
    Subject = maps:get(<<"subject">>, Map),
    write_user(<<"tenantA">>, Subject),
    write_user(<<"tenantB">>, Subject),
    ?assertEqual([<<"tenantA">>, <<"tenantB">>], cx_identity:tenants_for(Subject)).

seed_is_idempotent() ->
    Admin = #{subject => <<"seed-1">>, email => <<"seed@x">>, password => <<"pw">>},
    ok = cx_identity:ensure_seed(Admin),
    ok = cx_identity:ensure_seed(Admin),
    ?assertMatch({ok, #cx_identity{email = <<"seed@x">>}}, cx_identity:fetch(<<"seed-1">>)),
    ?assertMatch({ok, _}, cx_identity:verify_credential(<<"seed@x">>, <<"pw">>)).

%% Write a cx_user row directly (bypassing cx_user:create's referential
%% checks) — this test only cares about the subject -> tenant index join.
write_user(TenantId, Subject) ->
    Now = cx_time:now_ms(),
    User = #cx_user{
        key = {TenantId, cx_id:new()},
        subject = Subject,
        name = <<"n">>,
        email = <<"e">>,
        role_ids = [],
        skills = #{},
        routing_profile_id = undefined,
        status = active,
        created_at = Now,
        updated_at = Now
    },
    ok = cx_store:tx(fun() -> mnesia:write(User) end).
