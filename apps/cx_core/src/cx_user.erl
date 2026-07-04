-module(cx_user).

-include("cx_core.hrl").

-export([create/2, get/2, list/1, update/3, delete/2]).
-export([fetch/2, fetch_by_subject/2, to_map/1]).

create(Ctx = #auth_ctx{tenant_id = T}, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"users:write">>),
        {ok, Name} ?= cx_params:require_bin(Params, <<"name">>),
        {ok, Email} ?= cx_params:require_bin(Params, <<"email">>),
        {ok, Subject} ?= cx_params:opt_bin(Params, <<"subject">>, undefined),
        {ok, RoleIds} ?= opt_bin_list(Params, <<"role_ids">>),
        {ok, Skills} ?= opt_skills(Params),
        {ok, ProfileId} ?= cx_params:opt_bin(Params, <<"routing_profile_id">>, undefined),
        Now = cx_time:now_ms(),
        Rec = #cx_user{key = {T, cx_id:new()}, subject = Subject,
                       name = Name, email = Email, role_ids = RoleIds,
                       skills = Skills, routing_profile_id = ProfileId,
                       status = active, created_at = Now, updated_at = Now},
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, element(2, Rec#cx_user.key), user_created),
        {ok, to_map(Rec)}
    end.

get(Ctx = #auth_ctx{tenant_id = T}, UserId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"users:read">>),
        {ok, Rec} ?= cx_store:read(cx_user, {T, UserId}),
        {ok, to_map(Rec)}
    end.

list(Ctx = #auth_ctx{tenant_id = T}) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"users:read">>),
        Recs = cx_store:list(cx_user, cx_patterns:users(T)),
        {ok, [to_map(R) || R <- Recs]}
    end.

update(Ctx = #auth_ctx{tenant_id = T}, UserId, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"users:write">>),
        {ok, Rec0} ?= cx_store:read(cx_user, {T, UserId}),
        {ok, Name} ?= cx_params:opt_bin(Params, <<"name">>, Rec0#cx_user.name),
        {ok, Email} ?= cx_params:opt_bin(Params, <<"email">>, Rec0#cx_user.email),
        {ok, Subject} ?= cx_params:opt_bin(Params, <<"subject">>, Rec0#cx_user.subject),
        {ok, RoleIds} ?= opt_bin_list(Params, <<"role_ids">>, Rec0#cx_user.role_ids),
        {ok, Skills} ?= opt_skills(Params, Rec0#cx_user.skills),
        {ok, ProfileId} ?= cx_params:opt_bin(Params, <<"routing_profile_id">>,
                                             Rec0#cx_user.routing_profile_id),
        {ok, Status} ?= cx_params:opt_atom(Params, <<"status">>,
                                           [active, disabled], Rec0#cx_user.status),
        Rec = Rec0#cx_user{subject = Subject, name = Name, email = Email,
                           role_ids = RoleIds, skills = Skills,
                           routing_profile_id = ProfileId, status = Status,
                           updated_at = cx_time:now_ms()},
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, UserId, user_updated),
        {ok, to_map(Rec)}
    end.

delete(Ctx = #auth_ctx{tenant_id = T}, UserId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"users:write">>),
        ok ?= cx_store:tx(fun() ->
            case mnesia:read(cx_user, {T, UserId}) of
                [_] -> mnesia:delete({cx_user, {T, UserId}});
                [] -> {error, not_found}
            end
        end),
        publish(T, UserId, user_deleted),
        ok
    end.

%% Internal, no authorization.
-spec fetch(binary(), binary()) -> {ok, #cx_user{}} | {error, not_found}.
fetch(TenantId, UserId) ->
    cx_store:read(cx_user, {TenantId, UserId}).

%% Token subject -> user, within one tenant (index read then tenant filter).
-spec fetch_by_subject(binary(), binary()) -> {ok, #cx_user{}} | {error, not_found}.
fetch_by_subject(TenantId, Subject) ->
    Recs = cx_store:tx(fun() ->
        mnesia:index_read(cx_user, Subject, #cx_user.subject)
    end),
    case [R || R = #cx_user{key = {T, _}} <- Recs, T =:= TenantId] of
        [Rec | _] -> {ok, Rec};
        [] -> {error, not_found}
    end.

to_map(#cx_user{key = {_, Id}, subject = Subject, name = Name, email = Email,
                role_ids = RoleIds, skills = Skills,
                routing_profile_id = ProfileId, status = Status,
                created_at = C, updated_at = U}) ->
    #{<<"id">> => Id, <<"subject">> => null_if_undefined(Subject),
      <<"name">> => Name, <<"email">> => Email,
      <<"role_ids">> => RoleIds, <<"skills">> => Skills,
      <<"routing_profile_id">> => null_if_undefined(ProfileId),
      <<"status">> => atom_to_binary(Status),
      <<"created_at">> => C, <<"updated_at">> => U}.

null_if_undefined(undefined) -> null;
null_if_undefined(V) -> V.

opt_bin_list(Params, Key) ->
    opt_bin_list(Params, Key, []).

opt_bin_list(Params, Key, Default) ->
    case cx_params:opt_list(Params, Key, Default) of
        {ok, L} ->
            case lists:all(fun is_binary/1, L) of
                true -> {ok, L};
                false -> {error, {invalid, Key}}
            end;
        Error ->
            Error
    end.

opt_skills(Params) ->
    opt_skills(Params, #{}).

opt_skills(Params, Default) ->
    case cx_params:opt_map(Params, <<"skills">>, Default) of
        {ok, Skills} ->
            Valid = lists:all(
                fun({K, V}) -> is_binary(K) andalso is_integer(V) andalso V > 0 end,
                maps:to_list(Skills)),
            case Valid of
                true -> {ok, Skills};
                false -> {error, {invalid, <<"skills">>}}
            end;
        Error ->
            Error
    end.

publish(TenantId, UserId, Type) ->
    cx_event:publish(TenantId, undefined, undefined,
                     #{type => Type, at => cx_time:now_ms(),
                       data => #{<<"id">> => UserId}}).
