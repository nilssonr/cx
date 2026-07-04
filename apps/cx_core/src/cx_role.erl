-module(cx_role).

-include("cx_core.hrl").

-export([create/2, get/2, list/1, update/3, delete/2]).
-export([fetch/2, to_map/1]).

create(Ctx = #auth_ctx{tenant_id = T}, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"roles:write">>),
        {ok, Name} ?= cx_params:require_bin(Params, <<"name">>),
        {ok, Perms} ?= opt_perms(Params, []),
        Rec = #cx_role{key = {T, cx_id:new()}, name = Name, permissions = Perms},
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, element(2, Rec#cx_role.key), role_created),
        {ok, to_map(Rec)}
    end.

%% Reads need no specific permission: any authenticated tenant member may
%% see role definitions (agents resolve their own permissions through them).
get(#auth_ctx{tenant_id = T}, RoleId) ->
    maybe
        {ok, Rec} ?= cx_store:read(cx_role, {T, RoleId}),
        {ok, to_map(Rec)}
    end.

list(#auth_ctx{tenant_id = T}) ->
    Recs = cx_store:list(cx_role, cx_patterns:roles(T)),
    {ok, [to_map(R) || R <- Recs]}.

update(Ctx = #auth_ctx{tenant_id = T}, RoleId, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"roles:write">>),
        {ok, Rec0} ?= cx_store:read(cx_role, {T, RoleId}),
        {ok, Name} ?= cx_params:opt_bin(Params, <<"name">>, Rec0#cx_role.name),
        {ok, Perms} ?= opt_perms(Params, Rec0#cx_role.permissions),
        Rec = Rec0#cx_role{name = Name, permissions = Perms},
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, RoleId, role_updated),
        {ok, to_map(Rec)}
    end.

%% Deleting a role users reference is blocked (409) — a dangling role id
%% would silently drop permissions at next token resolution.
delete(Ctx = #auth_ctx{tenant_id = T}, RoleId) ->
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

to_map(#cx_role{key = {_, Id}, name = Name, permissions = Perms}) ->
    #{<<"id">> => Id, <<"name">> => Name, <<"permissions">> => Perms}.

opt_perms(Params, Default) ->
    case cx_params:opt_list(Params, <<"permissions">>, Default) of
        {ok, L} ->
            case lists:all(fun is_binary/1, L) of
                true -> {ok, L};
                false -> {error, {invalid, <<"permissions">>}}
            end;
        Error ->
            Error
    end.

publish(TenantId, RoleId, Type) ->
    cx_event:publish(
        TenantId,
        undefined,
        undefined,
        #{
            type => Type,
            at => cx_time:now_ms(),
            data => #{<<"id">> => RoleId}
        }
    ).
