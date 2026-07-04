-module(cx_skill).

-include("cx_core.hrl").

-export([create/2, get/2, list/1, update/3, delete/2]).
-export([fetch/2, to_map/1]).

create(Ctx = #auth_ctx{tenant_id = T}, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"skills:write">>),
        {ok, Name} ?= cx_params:require_bin(Params, <<"name">>),
        {ok, Levels} ?= parse_levels(maps:get(<<"levels">>, Params, [])),
        Rec = #cx_skill{key = {T, cx_id:new()}, name = Name, levels = Levels},
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, element(2, Rec#cx_skill.key), skill_created),
        {ok, to_map(Rec)}
    end.

get(#auth_ctx{tenant_id = T}, SkillId) ->
    maybe
        {ok, Rec} ?= cx_store:read(cx_skill, {T, SkillId}),
        {ok, to_map(Rec)}
    end.

list(#auth_ctx{tenant_id = T}) ->
    Recs = cx_store:list(cx_skill, cx_patterns:skills(T)),
    {ok, [to_map(R) || R <- Recs]}.

update(Ctx = #auth_ctx{tenant_id = T}, SkillId, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"skills:write">>),
        {ok, Rec0} ?= cx_store:read(cx_skill, {T, SkillId}),
        {ok, Name} ?= cx_params:opt_bin(Params, <<"name">>, Rec0#cx_skill.name),
        {ok, Levels} ?= case Params of
            #{<<"levels">> := Raw} -> parse_levels(Raw);
            _ -> {ok, Rec0#cx_skill.levels}
        end,
        Rec = Rec0#cx_skill{name = Name, levels = Levels},
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, SkillId, skill_updated),
        {ok, to_map(Rec)}
    end.

delete(Ctx = #auth_ctx{tenant_id = T}, SkillId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"skills:write">>),
        ok ?= cx_store:tx(fun() ->
            case mnesia:read(cx_skill, {T, SkillId}) of
                [_] -> mnesia:delete({cx_skill, {T, SkillId}});
                [] -> {error, not_found}
            end
        end),
        publish(T, SkillId, skill_deleted),
        ok
    end.

-spec fetch(binary(), binary()) -> {ok, #cx_skill{}} | {error, not_found}.
fetch(TenantId, SkillId) ->
    cx_store:read(cx_skill, {TenantId, SkillId}).

to_map(#cx_skill{key = {_, Id}, name = Name, levels = Levels}) ->
    #{<<"id">> => Id, <<"name">> => Name,
      <<"levels">> => [#{<<"rank">> => R, <<"name">> => N} || {R, N} <- Levels]}.

%% [{"rank": 1, "name": "trainee"}, ...] -> [{1, <<"trainee">>}, ...]
%% Ranks must be unique positive integers; result is sorted by rank.
parse_levels(Raw) when is_list(Raw) ->
    try
        Levels = [{maps:get(<<"rank">>, M), maps:get(<<"name">>, M)} || M <- Raw],
        true = lists:all(fun({R, N}) ->
                             is_integer(R) andalso R > 0 andalso
                             is_binary(N) andalso N =/= <<>>
                         end, Levels),
        Ranks = [R || {R, _} <- Levels],
        true = length(lists:usort(Ranks)) =:= length(Ranks),
        {ok, lists:keysort(1, Levels)}
    catch
        _:_ -> {error, {invalid, <<"levels">>}}
    end;
parse_levels(_) ->
    {error, {invalid, <<"levels">>}}.

publish(TenantId, SkillId, Type) ->
    cx_event:publish(TenantId, undefined, undefined,
                     #{type => Type, at => cx_time:now_ms(),
                       data => #{<<"id">> => SkillId}}).
