-module(cx_user).

-include("cx_core.hrl").

-export([create/2, get/2, list/1, update/3, delete/2]).
-export([fetch/2, fetch_by_subject/2, to_map/1]).

create(Ctx = #auth_context{tenant_id = T}, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"users:write">>),
        {ok, Name} ?= cx_params:require_binary(Params, <<"name">>),
        {ok, Email} ?= cx_params:require_binary(Params, <<"email">>),
        {ok, Subject} ?= cx_params:optional_binary(Params, <<"subject">>, undefined),
        {ok, RoleIds} ?= opt_bin_list(Params, <<"role_ids">>),
        {ok, Skills} ?= opt_skills(Params),
        {ok, ProfileId} ?= cx_params:optional_binary(Params, <<"routing_profile_id">>, undefined),
        Now = cx_time:now_ms(),
        Rec = #cx_user{
            key = {T, cx_id:new()},
            subject = Subject,
            name = Name,
            email = Email,
            role_ids = RoleIds,
            skills = Skills,
            routing_profile_id = ProfileId,
            status = active,
            created_at = Now,
            updated_at = Now
        },
        ok ?= write_checked(T, Rec),
        publish(T, element(2, Rec#cx_user.key), user_created),
        {ok, to_map(Rec)}
    end.

get(Ctx = #auth_context{tenant_id = T}, UserId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"users:read">>),
        {ok, Rec} ?= cx_store:read(cx_user, {T, UserId}),
        {ok, to_map(Rec)}
    end.

list(Ctx = #auth_context{tenant_id = T}) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"users:read">>),
        Recs = cx_store:list(cx_user, cx_patterns:users(T)),
        {ok, [to_map(R) || R <- Recs]}
    end.

update(Ctx = #auth_context{tenant_id = T}, UserId, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"users:write">>),
        {ok, Rec0} ?= cx_store:read(cx_user, {T, UserId}),
        {ok, Name} ?= cx_params:optional_binary(Params, <<"name">>, Rec0#cx_user.name),
        {ok, Email} ?= cx_params:optional_binary(Params, <<"email">>, Rec0#cx_user.email),
        {ok, Subject} ?= cx_params:optional_binary(Params, <<"subject">>, Rec0#cx_user.subject),
        {ok, RoleIds} ?= opt_bin_list(Params, <<"role_ids">>, Rec0#cx_user.role_ids),
        {ok, Skills} ?= opt_skills(Params, Rec0#cx_user.skills),
        {ok, ProfileId} ?=
            cx_params:optional_binary(
                Params,
                <<"routing_profile_id">>,
                Rec0#cx_user.routing_profile_id
            ),
        {ok, Status} ?=
            cx_params:optional_atom(
                Params,
                <<"status">>,
                [active, disabled],
                Rec0#cx_user.status
            ),
        Rec = Rec0#cx_user{
            subject = Subject,
            name = Name,
            email = Email,
            role_ids = RoleIds,
            skills = Skills,
            routing_profile_id = ProfileId,
            status = Status,
            updated_at = cx_time:now_ms()
        },
        ok ?= write_checked(T, Rec),
        publish(T, UserId, user_updated),
        {ok, to_map(Rec)}
    end.

delete(Ctx = #auth_context{tenant_id = T}, UserId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"users:write">>),
        ok ?=
            cx_store:tx(fun() ->
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

to_map(#cx_user{
    key = {_, Id},
    subject = Subject,
    name = Name,
    email = Email,
    role_ids = RoleIds,
    skills = Skills,
    routing_profile_id = ProfileId,
    status = Status,
    created_at = C,
    updated_at = U
}) ->
    #{
        <<"id">> => Id,
        <<"subject">> => cx_json:undef_to_null(Subject),
        <<"name">> => Name,
        <<"email">> => Email,
        <<"role_ids">> => RoleIds,
        <<"skills">> => skills_to_list(Skills),
        <<"routing_profile_id">> => cx_json:undef_to_null(ProfileId),
        <<"status">> => atom_to_binary(Status),
        <<"created_at">> => C,
        <<"updated_at">> => U
    }.

%% Wire shape is a list of objects so per-assignment fields can be added
%% later without breaking the API; storage stays #{SkillId => Rank}.
skills_to_list(Skills) ->
    [
        #{<<"skill_id">> => SkillId, <<"rank">> => Rank}
     || {SkillId, Rank} <- lists:keysort(1, maps:to_list(Skills))
    ].

opt_bin_list(Params, Key) ->
    opt_bin_list(Params, Key, []).

opt_bin_list(Params, Key, Default) ->
    case cx_params:optional_list(Params, Key, Default) of
        {ok, L} ->
            case lists:all(fun is_binary/1, L) of
                true -> {ok, L};
                false -> {error, {invalid, Key}}
            end;
        Error ->
            Error
    end.

%% [{"skill_id": Id, "rank": N}, ...] -> #{Id => N}. Duplicate skill_ids
%% are rejected rather than last-write-wins.
opt_skills(Params) ->
    opt_skills(Params, #{}).

opt_skills(Params, Default) ->
    case Params of
        #{<<"skills">> := Raw} -> parse_skills(Raw);
        _ -> {ok, Default}
    end.

parse_skills(Raw) when is_list(Raw) ->
    try
        Pairs = lists:map(
            fun(M) when is_map(M) ->
                SkillId = maps:get(<<"skill_id">>, M),
                Rank = maps:get(<<"rank">>, M),
                true = is_binary(SkillId) andalso SkillId =/= <<>>,
                true = is_integer(Rank) andalso Rank > 0,
                {SkillId, Rank}
            end,
            Raw
        ),
        Skills = maps:from_list(Pairs),
        true = map_size(Skills) =:= length(Pairs),
        {ok, Skills}
    catch
        _:_ -> {error, {invalid, <<"skills">>}}
    end;
parse_skills(_) ->
    {error, {invalid, <<"skills">>}}.

%% Write inside one transaction with the referential checks, so a
%% concurrent skill/role/profile delete cannot race a dangling reference
%% into existence.
write_checked(T, Rec) ->
    cx_store:tx(fun() ->
        maybe
            ok ?=
                check_refs(
                    cx_skill,
                    T,
                    maps:keys(Rec#cx_user.skills),
                    <<"skills">>
                ),
            ok ?= check_refs(cx_role, T, Rec#cx_user.role_ids, <<"role_ids">>),
            ok ?=
                check_refs(
                    cx_routing_profile,
                    T,
                    profile_refs(Rec#cx_user.routing_profile_id),
                    <<"routing_profile_id">>
                ),
            mnesia:write(Rec)
        end
    end).

profile_refs(undefined) -> [];
profile_refs(ProfileId) -> [ProfileId].

check_refs(Tab, T, Ids, Field) ->
    Missing = [Id || Id <- Ids, mnesia:read(Tab, {T, Id}) =:= []],
    case Missing of
        [] -> ok;
        _ -> {error, {invalid, Field}}
    end.

publish(TenantId, UserId, Type) ->
    cx_event:publish(TenantId, undefined, undefined, Type, #{<<"id">> => UserId}).
