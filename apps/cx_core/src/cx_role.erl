-module(cx_role).

-include("cx_core.hrl").

-export([create/2, get/2, list/1, update/3, delete/2]).
-export([fetch/2, to_map/1]).

create(Ctx = #auth_context{tenant_id = T}, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"roles:write">>),
        {ok, Name} ?= cx_params:require_binary(Params, <<"name">>),
        {ok, Permissions} ?= optional_permissions(Params, []),
        Rec = #cx_role{key = {T, cx_id:new()}, name = Name, permissions = Permissions},
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, element(2, Rec#cx_role.key), role_created),
        {ok, to_map(Rec)}
    end.

%% Reads need no specific permission: any authenticated tenant member may
%% see role definitions (agents resolve their own permissions through them).
get(#auth_context{tenant_id = T}, RoleId) ->
    maybe
        {ok, Rec} ?= cx_store:read(cx_role, {T, RoleId}),
        {ok, to_map(Rec)}
    end.

list(#auth_context{tenant_id = T}) ->
    Recs = cx_store:list(cx_role, cx_patterns:roles(T)),
    {ok, [to_map(R) || R <- Recs]}.

update(Ctx = #auth_context{tenant_id = T}, RoleId, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"roles:write">>),
        {ok, Rec0} ?= cx_store:read(cx_role, {T, RoleId}),
        {ok, Name} ?= cx_params:optional_binary(Params, <<"name">>, Rec0#cx_role.name),
        {ok, Permissions} ?= optional_permissions(Params, Rec0#cx_role.permissions),
        Rec = Rec0#cx_role{name = Name, permissions = Permissions},
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, RoleId, role_updated),
        {ok, to_map(Rec)}
    end.

%% Deleting a role users reference is blocked (409) — a dangling role id
%% would silently drop permissions at next token resolution.
delete(Ctx = #auth_context{tenant_id = T}, RoleId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"roles:write">>),
        ok ?=
            cx_store:tx(fun() ->
                case mnesia:read(cx_role, {T, RoleId}) of
                    [] ->
                        {error, not_found};
                    [_] ->
                        case referenced(T, RoleId) of
                            true -> {error, in_use};
                            false -> mnesia:delete({cx_role, {T, RoleId}})
                        end
                end
            end),
        publish(T, RoleId, role_deleted),
        ok
    end.

referenced(T, RoleId) ->
    lists:any(
        fun(#cx_user{role_ids = RoleIds}) -> lists:member(RoleId, RoleIds) end,
        mnesia:match_object(cx_patterns:users(T))
    ).

-spec fetch(binary(), binary()) -> {ok, #cx_role{}} | {error, not_found}.
fetch(TenantId, RoleId) ->
    cx_store:read(cx_role, {TenantId, RoleId}).

to_map(#cx_role{key = {_, Id}, name = Name, permissions = Permissions}) ->
    #{<<"id">> => Id, <<"name">> => Name, <<"permissions">> => Permissions}.

%% Only catalog permissions a tenant may grant itself pass — <<"*">>,
%% tenants:admin and unknown strings are rejected, so a tenant admin
%% with roles:write cannot escalate past their tenant.
optional_permissions(Params, Default) ->
    case cx_params:optional_list(Params, <<"permissions">>, Default) of
        {ok, L} ->
            case lists:all(fun cx_permission:is_tenant_assignable/1, L) of
                true -> {ok, L};
                false -> {error, {invalid, <<"permissions">>}}
            end;
        Error ->
            Error
    end.

publish(TenantId, RoleId, Type) ->
    cx_event:publish(TenantId, undefined, undefined, Type, #{<<"id">> => RoleId}).
