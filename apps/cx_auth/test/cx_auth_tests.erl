-module(cx_auth_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("cx_core/include/cx_core.hrl").

-define(TENANT_CLAIM, <<"urn:zitadel:iam:org:id">>).

auth_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Keypair) ->
        [
            fun() -> platform_admin_token(Keypair) end,
            fun() -> user_token_role_permissions(Keypair) end,
            fun() -> poisoned_role_row_filtered(Keypair) end,
            fun() -> expired_token(Keypair) end,
            fun() -> wrong_audience(Keypair) end,
            fun() -> wrong_issuer(Keypair) end,
            fun() -> unknown_kid(Keypair) end,
            fun() -> unknown_subject(Keypair) end,
            fun() -> disabled_user(Keypair) end,
            fun() -> missing_tenant_claim(Keypair) end,
            fun garbage_tokens/0,
            fun() -> crud_forbidden_without_permission(Keypair) end,
            fun jwks_http_options/0,
            fun jwks_parse_keeps_duplicate_and_absent_kids/0,
            fun() -> rotation_overlap_duplicate_kid_verifies(Keypair) end
        ]
    end}.

setup() ->
    %% unique_integer alone restarts per VM and can collide with a stale
    %% dir from an earlier run (whose schema predates record changes) —
    %% the wall clock makes the dir unique across runs too
    Dir =
        "_build/eunit-mnesia-" ++
            integer_to_list(erlang:system_time(microsecond)) ++
            "-" ++ integer_to_list(erlang:unique_integer([positive])),
    application:set_env(cx_core, mnesia_dir, Dir),
    ok = cx_db:init(),
    {ok, _} = application:ensure_all_started(jose),
    _ = cx_test_support:ensure_pg(),
    Keypair = cx_auth_test:new_keypair(),
    ok = cx_auth_test:install(
        Keypair,
        #{platform_admin_subjects => [<<"boss">>]}
    ),
    Keypair.

cleanup(_) ->
    stopped = mnesia:stop().

platform_admin_token(Keypair) ->
    Token = cx_auth_test:token(Keypair, #{
        <<"sub">> => <<"boss">>,
        ?TENANT_CLAIM => <<"t1">>
    }),
    {ok, Ctx} = cx_auth:authenticate(<<"Bearer ", Token/binary>>),
    ?assertEqual(<<"t1">>, Ctx#auth_context.tenant_id),
    ?assertEqual(undefined, Ctx#auth_context.user_id),
    ?assert(cx_authz:has(Ctx, <<"anything:at:all">>)).

user_token_role_permissions(Keypair) ->
    T = cx_id:new(),
    Admin = cx_authz:ctx(T, [<<"*">>]),
    {ok, #{<<"id">> := RoleId}} =
        cx_role:create(Admin, #{
            <<"name">> => <<"Agent">>,
            <<"permissions">> => [<<"agent:ready:self">>]
        }),
    {ok, #{<<"id">> := UserId}} =
        cx_user:create(Admin, #{
            <<"name">> => <<"A">>,
            <<"email">> => <<"a@x">>,
            <<"subject">> => <<"agent-sub">>,
            <<"role_ids">> => [RoleId]
        }),
    Token = cx_auth_test:token(Keypair, #{
        <<"sub">> => <<"agent-sub">>,
        ?TENANT_CLAIM => T
    }),
    {ok, Ctx} = cx_auth:authenticate(Token),
    ?assertEqual(UserId, Ctx#auth_context.user_id),
    ?assert(cx_authz:has(Ctx, <<"agent:ready:self">>)),
    ?assertNot(cx_authz:has(Ctx, <<"queues:write">>)).

%% A role row carrying out-of-catalog permissions (predating the
%% cx_role allow-list, or written around it) must be neutralized when
%% the ctx is built — the wildcard and platform perms never reach a
%% tenant token.
poisoned_role_row_filtered(Keypair) ->
    T = cx_id:new(),
    Admin = cx_authz:ctx(T, [<<"*">>]),
    RoleId = cx_id:new(),
    ok = cx_store:tx(fun() ->
        mnesia:write(#cx_role{
            key = {T, RoleId},
            name = <<"poisoned">>,
            permissions = [<<"*">>, <<"tenants:admin">>, <<"queues:read">>]
        })
    end),
    {ok, #{<<"id">> := _}} =
        cx_user:create(Admin, #{
            <<"name">> => <<"Evil">>,
            <<"email">> => <<"e@x">>,
            <<"subject">> => <<"evil-sub">>,
            <<"role_ids">> => [RoleId]
        }),
    Token = cx_auth_test:token(Keypair, #{
        <<"sub">> => <<"evil-sub">>,
        ?TENANT_CLAIM => T
    }),
    {ok, Ctx} = cx_auth:authenticate(Token),
    ?assert(cx_authz:has(Ctx, <<"queues:read">>)),
    ?assertNot(cx_authz:has(Ctx, <<"tenants:admin">>)),
    ?assertNot(cx_authz:has(Ctx, <<"queues:write">>)).

expired_token(Keypair) ->
    Now = erlang:system_time(second),
    Token = cx_auth_test:token(Keypair, #{
        <<"sub">> => <<"boss">>,
        <<"exp">> => Now - 3600
    }),
    ?assertEqual({error, unauthorized}, cx_auth:authenticate(Token)).

wrong_audience(Keypair) ->
    Token = cx_auth_test:token(Keypair, #{
        <<"sub">> => <<"boss">>,
        <<"aud">> => <<"other-api">>
    }),
    ?assertEqual({error, unauthorized}, cx_auth:authenticate(Token)).

wrong_issuer(Keypair) ->
    Token = cx_auth_test:token(Keypair, #{
        <<"sub">> => <<"boss">>,
        <<"iss">> => <<"http://evil">>
    }),
    ?assertEqual({error, unauthorized}, cx_auth:authenticate(Token)).

unknown_kid(Keypair) ->
    %% Signed by a key the configured source has never seen.
    Rogue = cx_auth_test:new_keypair(),
    Token = cx_auth_test:token(Rogue, #{<<"sub">> => <<"boss">>}),
    ?assertEqual({error, unauthorized}, cx_auth:authenticate(Token)),
    %% and the original still works afterwards
    Good = cx_auth_test:token(Keypair, #{<<"sub">> => <<"boss">>}),
    ?assertMatch({ok, _}, cx_auth:authenticate(Good)).

unknown_subject(Keypair) ->
    Token = cx_auth_test:token(Keypair, #{
        <<"sub">> => <<"nobody">>,
        ?TENANT_CLAIM => cx_id:new()
    }),
    ?assertEqual({error, unauthorized}, cx_auth:authenticate(Token)).

disabled_user(Keypair) ->
    T = cx_id:new(),
    Admin = cx_authz:ctx(T, [<<"*">>]),
    {ok, #{<<"id">> := UserId}} =
        cx_user:create(Admin, #{
            <<"name">> => <<"D">>,
            <<"email">> => <<"d@x">>,
            <<"subject">> => <<"disabled-sub">>
        }),
    {ok, _} = cx_user:update(Admin, UserId, #{<<"status">> => <<"disabled">>}),
    Token = cx_auth_test:token(Keypair, #{
        <<"sub">> => <<"disabled-sub">>,
        ?TENANT_CLAIM => T
    }),
    ?assertEqual({error, unauthorized}, cx_auth:authenticate(Token)).

missing_tenant_claim(Keypair) ->
    Token = cx_auth_test:token(Keypair, #{
        <<"sub">> => <<"boss">>,
        ?TENANT_CLAIM => null
    }),
    ?assertEqual({error, unauthorized}, cx_auth:authenticate(Token)).

garbage_tokens() ->
    ?assertEqual({error, unauthorized}, cx_auth:authenticate(<<>>)),
    ?assertEqual({error, unauthorized}, cx_auth:authenticate(<<"not-a-jwt">>)),
    ?assertEqual({error, unauthorized}, cx_auth:authenticate(<<"a.b.c">>)),
    ?assertEqual(
        {error, unauthorized},
        cx_auth:authenticate(<<"Bearer still-not-a-jwt">>)
    ).

%% Transport security matrix for the JWKS fetch: secure by default
%% (verify_peer + OS CAs, plain http refused); the dev/test flag admits
%% http and downgrades https to verify_none.
jwks_http_options() ->
    {ok, Secure} = cx_jwks_cache:http_options(<<"https://idp/keys">>, false),
    {ssl, SslOpts} = lists:keyfind(ssl, 1, Secure),
    ?assertEqual({verify, verify_peer}, lists:keyfind(verify, 1, SslOpts)),
    ?assertMatch({cacerts, [_ | _]}, lists:keyfind(cacerts, 1, SslOpts)),
    ?assertEqual(
        {error, insecure_jwks_url},
        cx_jwks_cache:http_options(<<"http://idp/keys">>, false)
    ),
    {ok, InsecureHttp} = cx_jwks_cache:http_options(<<"http://idp/keys">>, true),
    ?assertEqual(false, lists:keyfind(ssl, 1, InsecureHttp)),
    {ok, InsecureHttps} = cx_jwks_cache:http_options(<<"https://idp/keys">>, true),
    {ssl, Insecure} = lists:keyfind(ssl, 1, InsecureHttps),
    ?assertEqual({verify, verify_none}, lists:keyfind(verify, 1, Insecure)),
    ?assertEqual(
        {error, insecure_jwks_url},
        cx_jwks_cache:http_options(<<"ftp://idp/keys">>, true)
    ).

%% Overlapping rotation may publish two keys under one kid, and some
%% IdPs omit kid entirely — every published key must survive parsing.
jwks_parse_keeps_duplicate_and_absent_kids() ->
    #{public_map := P1} = cx_auth_test:new_keypair(),
    #{public_map := P2} = cx_auth_test:new_keypair(),
    #{public_map := P3} = cx_auth_test:new_keypair(),
    Body = cx_json:encode(#{
        <<"keys">> => [
            P1#{<<"kid">> => <<"shared">>},
            P2#{<<"kid">> => <<"shared">>},
            maps:remove(<<"kid">>, P3)
        ]
    }),
    {ok, Keys} = cx_jwks_cache:parse_jwks(Body),
    ?assertEqual(3, length(Keys)),
    ?assertEqual(
        [<<"shared">>, <<"shared">>, undefined],
        [Kid || {Kid, _} <- Keys]
    ),
    ?assertEqual({error, {invalid, json}}, cx_jwks_cache:parse_jwks(<<"nope">>)),
    ?assertEqual({error, {invalid, json}}, cx_jwks_cache:parse_jwks(<<"{}">>)).

%% End to end: two keys sharing a kid, token signed by the second —
%% verification must try every candidate, not just the first.
rotation_overlap_duplicate_kid_verifies(Keypair) ->
    Rotated = cx_auth_test:new_keypair(),
    #{public_map := OldPub, kid := Kid} = Keypair,
    #{public_map := NewPub} = Rotated,
    OldSource = application:get_env(cx_auth, key_source),
    ok = application:set_env(
        cx_auth,
        key_source,
        {static, [OldPub, NewPub#{<<"kid">> => Kid}]},
        [{persistent, true}]
    ),
    try
        Token = cx_auth_test:token(Rotated#{kid => Kid}, #{
            <<"sub">> => <<"boss">>,
            ?TENANT_CLAIM => <<"t1">>
        }),
        ?assertMatch({ok, _}, cx_auth:authenticate(Token))
    after
        {ok, Src} = OldSource,
        ok = application:set_env(cx_auth, key_source, Src, [{persistent, true}])
    end.

crud_forbidden_without_permission(Keypair) ->
    T = cx_id:new(),
    Admin = cx_authz:ctx(T, [<<"*">>]),
    {ok, #{<<"id">> := _}} =
        cx_user:create(Admin, #{
            <<"name">> => <<"P">>,
            <<"email">> => <<"p@x">>,
            <<"subject">> => <<"powerless">>
        }),
    Token = cx_auth_test:token(Keypair, #{
        <<"sub">> => <<"powerless">>,
        ?TENANT_CLAIM => T
    }),
    {ok, Ctx} = cx_auth:authenticate(Token),
    ?assertEqual(
        {error, forbidden},
        cx_queue:create(Ctx, #{<<"name">> => <<"q">>})
    ),
    ?assertEqual({error, forbidden}, cx_user:list(Ctx)).
