-module(cx_auth_claims).

%% Validated claims -> #auth_ctx{}. Tenant comes from a configured claim
%% (Zitadel: the org id). Identity resolution:
%%   - subject listed in platform_admin_subjects (sys.config) -> full
%%     permissions, no user row needed. This is the bootstrap path for
%%     creating the first tenant/users; keep the list tiny.
%%   - otherwise the subject must match an active cx_user in that tenant;
%%     permissions are the union of the user's role permissions.

-include_lib("cx_core/include/cx_core.hrl").

-export([to_ctx/1]).

-spec to_ctx(map()) -> {ok, #auth_ctx{}} | {error, unauthorized}.
to_ctx(Claims) ->
    TenantClaim = application:get_env(
        cx_auth,
        tenant_claim,
        <<"urn:zitadel:iam:org:id">>
    ),
    TenantId = maps:get(TenantClaim, Claims, undefined),
    Subject = maps:get(<<"sub">>, Claims, undefined),
    case {TenantId, Subject} of
        {T, S} when is_binary(T), is_binary(S) ->
            resolve(T, S, Claims);
        _ ->
            {error, unauthorized}
    end.

resolve(TenantId, Subject, Claims) ->
    PlatformAdmins = application:get_env(cx_auth, platform_admin_subjects, []),
    case lists:member(Subject, PlatformAdmins) of
        true ->
            {ok, #auth_ctx{
                tenant_id = TenantId,
                user_id = undefined,
                subject = Subject,
                permissions = sets:from_list([<<"*">>]),
                claims = Claims
            }};
        false ->
            resolve_user(TenantId, Subject, Claims)
    end.

resolve_user(TenantId, Subject, Claims) ->
    case cx_user:fetch_by_subject(TenantId, Subject) of
        {ok, #cx_user{key = {_, UserId}, status = active, role_ids = RoleIds}} ->
            {ok, #auth_ctx{
                tenant_id = TenantId,
                user_id = UserId,
                subject = Subject,
                permissions = role_permissions(TenantId, RoleIds),
                claims = Claims
            }};
        {ok, #cx_user{}} ->
            %% disabled user
            {error, unauthorized};
        {error, not_found} ->
            {error, unauthorized}
    end.

%% Union of the user's role permissions, filtered to the
%% tenant-assignable catalog: cx_role rejects out-of-catalog strings at
%% write time, and this filter neutralizes any row that predates that
%% check (or was written around it) without needing a data migration.
role_permissions(TenantId, RoleIds) ->
    Perms = lists:flatmap(
        fun(RoleId) ->
            case cx_role:fetch(TenantId, RoleId) of
                {ok, #cx_role{permissions = Ps}} -> Ps;
                {error, not_found} -> []
            end
        end,
        RoleIds
    ),
    sets:from_list([P || P <- Perms, cx_perm:is_tenant_assignable(P)]).
