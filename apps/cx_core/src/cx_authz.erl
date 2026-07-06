-module(cx_authz).

%% Pure authorization checks over #auth_context{}. Domain functions call
%% require/2 themselves — transports never enforce permissions.

-include("cx_core.hrl").

-export([has/2, require/2, require_user/1, context/2, context/4]).

-spec has(#auth_context{}, binary()) -> boolean().
has(#auth_context{permissions = Permissions}, Permission) ->
    sets:is_element(<<"*">>, Permissions) orelse sets:is_element(Permission, Permissions).

-spec require(#auth_context{}, binary()) -> ok | {error, forbidden}.
require(Context, Permission) ->
    case has(Context, Permission) of
        true -> ok;
        false -> {error, forbidden}
    end.

%% Operations acting on "self" need an agent identity in the token
%% (platform admins resolve with user_id = undefined).
-spec require_user(#auth_context{}) -> ok | {error, no_user}.
require_user(#auth_context{user_id = undefined}) -> {error, no_user};
require_user(#auth_context{}) -> ok.

%% Constructors, mainly for tests and internal callers.
-spec context(binary(), [binary()]) -> #auth_context{}.
context(TenantId, Permissions) ->
    context(TenantId, undefined, undefined, Permissions).

-spec context(binary(), binary() | undefined, binary() | undefined, [binary()]) ->
    #auth_context{}.
context(TenantId, UserId, Subject, Permissions) ->
    #auth_context{
        tenant_id = TenantId,
        user_id = UserId,
        subject = Subject,
        permissions = sets:from_list(Permissions)
    }.
