-module(cx_tenant).

-include("cx_core.hrl").

-export([create/2, get/2, list/1, update/3, delete/2]).
-export([fetch/1, to_map/1]).

%% The id may be supplied explicitly (e.g. the IdP organization id, so
%% token tenant claims map 1:1 onto cx tenants); otherwise generated.
create(Context, Params) ->
    maybe
        ok ?= cx_authz:require(Context, <<"tenants:admin">>),
        {ok, Name} ?= cx_params:require_binary(Params, <<"name">>),
        {ok, Id} ?= cx_params:optional_binary(Params, <<"id">>, cx_id:new()),
        Now = cx_time:now_ms(),
        Rec = #cx_tenant{
            id = Id,
            name = Name,
            status = active,
            created_at = Now,
            updated_at = Now
        },
        ok ?=
            cx_store:tx(fun() ->
                case mnesia:read(cx_tenant, Id) of
                    [] -> mnesia:write(Rec);
                    [_] -> {error, already_exists}
                end
            end),
        publish(Id, tenant_created),
        {ok, to_map(Rec)}
    end.

%% Anyone may read their own tenant; reading others needs tenants:admin.
get(#auth_context{tenant_id = TenantId}, TenantId) ->
    fetch_map(TenantId);
get(Context, TenantId) ->
    maybe
        ok ?= cx_authz:require(Context, <<"tenants:admin">>),
        fetch_map(TenantId)
    end.

list(Context) ->
    maybe
        ok ?= cx_authz:require(Context, <<"tenants:admin">>),
        Recs = cx_store:list(cx_tenant, cx_patterns:tenants()),
        {ok, [to_map(R) || R <- Recs]}
    end.

update(Context, TenantId, Params) ->
    maybe
        ok ?= cx_authz:require(Context, <<"tenants:admin">>),
        {ok, Rec0} ?= cx_store:read(cx_tenant, TenantId),
        {ok, Name} ?= cx_params:optional_binary(Params, <<"name">>, Rec0#cx_tenant.name),
        {ok, Status} ?=
            cx_params:optional_atom(
                Params,
                <<"status">>,
                [active, suspended],
                Rec0#cx_tenant.status
            ),
        Rec = Rec0#cx_tenant{
            name = Name,
            status = Status,
            updated_at = cx_time:now_ms()
        },
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(TenantId, tenant_updated),
        {ok, to_map(Rec)}
    end.

%% No cascade in M1: deleting a tenant leaves its scoped rows orphaned
%% (unreachable, since every read path requires the tenant in the key).
delete(Context, TenantId) ->
    maybe
        ok ?= cx_authz:require(Context, <<"tenants:admin">>),
        ok ?=
            cx_store:tx(fun() ->
                case mnesia:read(cx_tenant, TenantId) of
                    [_] -> mnesia:delete({cx_tenant, TenantId});
                    [] -> {error, not_found}
                end
            end),
        publish(TenantId, tenant_deleted),
        ok
    end.

%% Internal, no authorization — for cx_auth and cx_router.
-spec fetch(binary()) -> {ok, #cx_tenant{}} | {error, not_found}.
fetch(TenantId) ->
    cx_store:read(cx_tenant, TenantId).

to_map(#cx_tenant{
    id = Id,
    name = Name,
    status = Status,
    created_at = C,
    updated_at = U
}) ->
    #{
        <<"id">> => Id,
        <<"name">> => Name,
        <<"status">> => atom_to_binary(Status),
        <<"created_at">> => C,
        <<"updated_at">> => U
    }.

fetch_map(TenantId) ->
    maybe
        {ok, Rec} ?= cx_store:read(cx_tenant, TenantId),
        {ok, to_map(Rec)}
    end.

publish(TenantId, Type) ->
    cx_event:publish(TenantId, undefined, undefined, Type, #{<<"id">> => TenantId}).
