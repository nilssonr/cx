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
            fun() -> crud_forbidden_without_permission(Keypair) end
        ]
    end}.

setup() ->
    Dir = "_build/eunit-mnesia-" ++ integer_to_list(erlang:unique_integer([positive])),
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
    ?assertEqual(<<"t1">>, Ctx#auth_ctx.tenant_id),
    ?assertEqual(undefined, Ctx#auth_ctx.user_id),
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
    ?assertEqual(UserId, Ctx#auth_ctx.user_id),
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
