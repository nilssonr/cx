-module(cx_authz).

%% Pure authorization checks over #auth_ctx{}. Domain functions call
%% require/2 themselves — transports never enforce permissions.

-include("cx_core.hrl").

-export([has/2, require/2, ctx/2, ctx/4]).

-spec has(#auth_ctx{}, binary()) -> boolean().
has(#auth_ctx{permissions = Perms}, Perm) ->
    sets:is_element(<<"*">>, Perms) orelse sets:is_element(Perm, Perms).

-spec require(#auth_ctx{}, binary()) -> ok | {error, forbidden}.
require(Ctx, Perm) ->
    case has(Ctx, Perm) of
        true -> ok;
        false -> {error, forbidden}
    end.

%% Constructors, mainly for tests and internal callers.
-spec ctx(binary(), [binary()]) -> #auth_ctx{}.
ctx(TenantId, Perms) ->
    ctx(TenantId, undefined, undefined, Perms).

-spec ctx(binary(), binary() | undefined, binary() | undefined, [binary()]) -> #auth_ctx{}.
ctx(TenantId, UserId, Subject, Perms) ->
    #auth_ctx{tenant_id = TenantId,
              user_id = UserId,
              subject = Subject,
              permissions = sets:from_list(Perms)}.
