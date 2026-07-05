-module(cx_queue).

-include("cx_core.hrl").

-export([create/2, get/2, list/1, update/3, delete/2]).
-export([fetch/2, to_map/1]).

create(Ctx = #auth_ctx{tenant_id = T}, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"queues:write">>),
        {ok, Name} ?= cx_params:require_bin(Params, <<"name">>),
        {ok, SkillReqs} ?= parse_skill_reqs(maps:get(<<"skill_reqs">>, Params, [])),
        {ok, WrapupMs} ?= cx_params:opt_int(Params, <<"wrapup_duration_ms">>, 30000),
        {ok, OfferMs} ?= cx_params:opt_int(Params, <<"offer_timeout_ms">>, 30000),
        {ok, Status} ?= cx_params:opt_atom(Params, <<"status">>, [open, closed], open),
        Rec = #cx_queue{
            key = {T, cx_id:new()},
            name = Name,
            skill_reqs = SkillReqs,
            wrapup_duration_ms = WrapupMs,
            offer_timeout_ms = OfferMs,
            status = Status
        },
        ok ?= write_checked(T, Rec),
        publish(T, element(2, Rec#cx_queue.key), queue_created),
        {ok, to_map(Rec)}
    end.

get(Ctx = #auth_ctx{tenant_id = T}, QueueId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"queues:read">>),
        {ok, Rec} ?= cx_store:read(cx_queue, {T, QueueId}),
        {ok, to_map(Rec)}
    end.

list(Ctx = #auth_ctx{tenant_id = T}) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"queues:read">>),
        Recs = cx_store:list(cx_queue, cx_patterns:queues(T)),
        {ok, [to_map(R) || R <- Recs]}
    end.

update(Ctx = #auth_ctx{tenant_id = T}, QueueId, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"queues:write">>),
        {ok, Rec0} ?= cx_store:read(cx_queue, {T, QueueId}),
        {ok, Name} ?= cx_params:opt_bin(Params, <<"name">>, Rec0#cx_queue.name),
        {ok, SkillReqs} ?=
            case Params of
                #{<<"skill_reqs">> := Raw} -> parse_skill_reqs(Raw);
                _ -> {ok, Rec0#cx_queue.skill_reqs}
            end,
        {ok, WrapupMs} ?=
            cx_params:opt_int(
                Params,
                <<"wrapup_duration_ms">>,
                Rec0#cx_queue.wrapup_duration_ms
            ),
        {ok, OfferMs} ?=
            cx_params:opt_int(
                Params,
                <<"offer_timeout_ms">>,
                Rec0#cx_queue.offer_timeout_ms
            ),
        {ok, Status} ?=
            cx_params:opt_atom(
                Params,
                <<"status">>,
                [open, closed],
                Rec0#cx_queue.status
            ),
        Rec = Rec0#cx_queue{
            name = Name,
            skill_reqs = SkillReqs,
            wrapup_duration_ms = WrapupMs,
            offer_timeout_ms = OfferMs,
            status = Status
        },
        ok ?= write_checked(T, Rec),
        publish(T, QueueId, queue_updated),
        {ok, to_map(Rec)}
    end.

delete(Ctx = #auth_ctx{tenant_id = T}, QueueId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"queues:write">>),
        ok ?=
            cx_store:tx(fun() ->
                case mnesia:read(cx_queue, {T, QueueId}) of
                    [_] -> mnesia:delete({cx_queue, {T, QueueId}});
                    [] -> {error, not_found}
                end
            end),
        publish(T, QueueId, queue_deleted),
        ok
    end.

-spec fetch(binary(), binary()) -> {ok, #cx_queue{}} | {error, not_found}.
fetch(TenantId, QueueId) ->
    cx_store:read(cx_queue, {TenantId, QueueId}).

%% Write inside one transaction with the skill existence checks, so a
%% concurrent skill delete cannot race a dangling requirement in.
write_checked(T, Rec) ->
    cx_store:tx(fun() ->
        SkillIds = [S || #skill_req{skill_id = S} <- Rec#cx_queue.skill_reqs],
        Missing = [S || S <- SkillIds, mnesia:read(cx_skill, {T, S}) =:= []],
        case Missing of
            [] -> mnesia:write(Rec);
            _ -> {error, {invalid, <<"skill_reqs">>}}
        end
    end).

to_map(#cx_queue{
    key = {_, Id},
    name = Name,
    skill_reqs = SkillReqs,
    wrapup_duration_ms = WrapupMs,
    offer_timeout_ms = OfferMs,
    status = Status
}) ->
    #{
        <<"id">> => Id,
        <<"name">> => Name,
        <<"skill_reqs">> => [skill_req_to_map(R) || R <- SkillReqs],
        <<"wrapup_duration_ms">> => WrapupMs,
        <<"offer_timeout_ms">> => OfferMs,
        <<"status">> => atom_to_binary(Status)
    }.

skill_req_to_map(#skill_req{
    skill_id = SkillId,
    min_rank = MinRank,
    widening = Widening
}) ->
    #{
        <<"skill_id">> => SkillId,
        <<"min_rank">> => MinRank,
        <<"widening">> => [
            #{<<"after_ms">> => A, <<"min_rank">> => R}
         || {A, R} <- Widening
        ]
    }.

%% [{"skill_id": "...", "min_rank": 2,
%%   "widening": [{"after_ms": 60000, "min_rank": 1}]}]
%% Widening steps are sorted by after_ms; each step replaces min_rank.
%% Ranks must be non-increasing over time (widening relaxes, never
%% tightens) — this is what makes the eligible agent set grow
%% monotonically with wait time.
parse_skill_reqs(Raw) when is_list(Raw) ->
    try
        Reqs = lists:map(
            fun(M) when is_map(M) ->
                SkillId = maps:get(<<"skill_id">>, M),
                MinRank = maps:get(<<"min_rank">>, M),
                true = is_binary(SkillId) andalso SkillId =/= <<>>,
                true = is_integer(MinRank) andalso MinRank > 0,
                Widening = lists:map(
                    fun(W) ->
                        A = maps:get(<<"after_ms">>, W),
                        R = maps:get(<<"min_rank">>, W),
                        true = is_integer(A) andalso A > 0,
                        true = is_integer(R) andalso R > 0,
                        {A, R}
                    end,
                    maps:get(<<"widening">>, M, [])
                ),
                Sorted = lists:keysort(1, Widening),
                Ranks = [MinRank | [R || {_, R} <- Sorted]],
                true = Ranks =:= lists:reverse(lists:sort(Ranks)),
                #skill_req{
                    skill_id = SkillId,
                    min_rank = MinRank,
                    widening = Sorted
                }
            end,
            Raw
        ),
        {ok, Reqs}
    catch
        _:_ -> {error, {invalid, <<"skill_reqs">>}}
    end;
parse_skill_reqs(_) ->
    {error, {invalid, <<"skill_reqs">>}}.

publish(TenantId, QueueId, Type) ->
    cx_event:publish(TenantId, QueueId, undefined, Type, #{<<"id">> => QueueId}).
