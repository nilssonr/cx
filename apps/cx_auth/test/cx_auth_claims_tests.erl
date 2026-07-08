-module(cx_auth_claims_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("cx_core/include/cx_core.hrl").

claims_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun platform_admin_honors_act_as/0,
        fun platform_admin_without_act_as/0
    ]}.

setup() ->
    application:set_env(cx_auth, tenant_claim, <<"tenant_id">>),
    application:set_env(cx_auth, platform_admin_subjects, [<<"boss">>]),
    ok.

cleanup(_) ->
    application:unset_env(cx_auth, tenant_claim),
    application:unset_env(cx_auth, platform_admin_subjects),
    ok.

%% A platform admin's act_as_tenant claim rescopes the effective tenant.
platform_admin_honors_act_as() ->
    Claims = #{
        <<"sub">> => <<"boss">>,
        <<"tenant_id">> => <<"home">>,
        <<"act_as_tenant">> => <<"tenant-x">>
    },
    ?assertMatch(
        {ok, #auth_context{tenant_id = <<"tenant-x">>, user_id = undefined}},
        cx_auth_claims:to_context(Claims)
    ).

%% Without act_as_tenant, the platform admin's tenant is the tenant claim.
platform_admin_without_act_as() ->
    Claims = #{<<"sub">> => <<"boss">>, <<"tenant_id">> => <<"home">>},
    ?assertMatch(
        {ok, #auth_context{tenant_id = <<"home">>}},
        cx_auth_claims:to_context(Claims)
    ).
