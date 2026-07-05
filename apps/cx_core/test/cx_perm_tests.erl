-module(cx_perm_tests).

-include_lib("eunit/include/eunit.hrl").

all_are_binaries_test() ->
    ?assert(lists:all(fun is_binary/1, cx_perm:all())).

no_duplicates_test() ->
    All = cx_perm:all(),
    ?assertEqual(length(All), length(lists:usort(All))).

wildcard_is_not_a_permission_test() ->
    ?assertNot(lists:member(<<"*">>, cx_perm:all())),
    ?assertNot(cx_perm:is_tenant_assignable(<<"*">>)).

platform_and_tenant_are_disjoint_test() ->
    Tenant = cx_perm:tenant_assignable(),
    ?assertEqual([], [P || P <- cx_perm:platform_only(), lists:member(P, Tenant)]).

tenant_assignable_test() ->
    ?assert(cx_perm:is_tenant_assignable(<<"queues:read">>)),
    ?assertNot(cx_perm:is_tenant_assignable(<<"tenants:admin">>)),
    ?assertNot(cx_perm:is_tenant_assignable(<<"made:up">>)),
    ?assertNot(cx_perm:is_tenant_assignable(queues_read)),
    ?assertNot(cx_perm:is_tenant_assignable(undefined)).

%% Drift alarm: every permission string a domain operation checks must
%% be in the catalog. When cx_authz:require gains a new literal, add it
%% here AND to cx_perm — otherwise no tenant role can ever grant it.
catalog_covers_all_checked_permissions_test() ->
    InUse = [
        <<"agent:offers:self">>,
        <<"agent:ready:self">>,
        <<"agent:session:self">>,
        <<"agent:wrapup:self">>,
        <<"interactions:cancel">>,
        <<"interactions:create">>,
        <<"interactions:read">>,
        <<"not_ready_reasons:write">>,
        <<"presence:set:self">>,
        <<"queues:read">>,
        <<"queues:write">>,
        <<"roles:write">>,
        <<"routing_profiles:write">>,
        <<"skills:write">>,
        <<"tenants:admin">>,
        <<"users:read">>,
        <<"users:write">>
    ],
    All = cx_perm:all(),
    ?assertEqual([], [P || P <- InUse, not lists:member(P, All)]).
