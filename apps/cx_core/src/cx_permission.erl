-module(cx_permission).

%% The product's permission vocabulary. Permissions are hard-coded
%% product concepts (the cx_media/cx_presence_state charter): every
%% string a domain operation checks via cx_authz lives here, split by
%% who may grant it. Tenant roles (cx_role) may only carry
%% tenant_assignable/0 entries — anything else is rejected at role
%% write AND filtered at context build, so a tenant admin can never mint
%% platform authority for themselves.
%%
%% <<"*">> is NOT a permission and appears nowhere in all/0: it is the
%% platform-admin wildcard produced exclusively by cx_auth_claims for
%% subjects listed in the cx_auth `platform_admin_subjects` env.
%% tenants:admin is platform-only: it gates tenant CRUD and
%% cross-tenant rescoping (cx_handler:scope_tenant), so granting it from
%% inside a tenant would break tenant isolation.

-export([all/0, tenant_assignable/0, platform_only/0, is_tenant_assignable/1]).

-spec all() -> [binary()].
all() ->
    tenant_assignable() ++ platform_only().

-spec tenant_assignable() -> [binary()].
tenant_assignable() ->
    [
        <<"agent:interactions:self">>,
        <<"agent:offers:self">>,
        <<"agent:ready:self">>,
        <<"agent:session:any">>,
        <<"agent:session:self">>,
        <<"agent:wrapup:self">>,
        <<"interactions:cancel">>,
        <<"interactions:create">>,
        <<"interactions:read">>,
        <<"not_ready_reasons:write">>,
        <<"presence:set:self">>,
        <<"qualification_codes:write">>,
        <<"queues:read">>,
        <<"queues:write">>,
        <<"roles:write">>,
        <<"routing_profiles:write">>,
        <<"skills:write">>,
        <<"users:read">>,
        <<"users:write">>
    ].

-spec platform_only() -> [binary()].
platform_only() ->
    [<<"tenants:admin">>].

-spec is_tenant_assignable(term()) -> boolean().
is_tenant_assignable(Permission) ->
    lists:member(Permission, tenant_assignable()).
