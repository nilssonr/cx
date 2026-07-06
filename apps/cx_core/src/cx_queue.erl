-module(cx_queue).

-include("cx_core.hrl").

-export([create/2, get/2, list/1, update/3, delete/2]).
-export([fetch/2, to_map/1]).

%% Defaults are applied HERE, at creation — deliberately not in the
%% record definition, so nothing can materialize a queue with implicit
%% values by merely constructing #cx_queue{}.
-define(DEFAULT_WRAPUP_DURATION_MS, 30000).
-define(DEFAULT_OFFER_TIMEOUT_MS, 6000).

create(Ctx = #auth_context{tenant_id = T}, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"queues:write">>),
        {ok, Name} ?= cx_params:require_binary(Params, <<"name">>),
        {ok, SkillRequirements} ?=
            parse_skill_requirements(maps:get(<<"skill_requirements">>, Params, [])),
        {ok, WrapupMs} ?=
            cx_params:optional_integer(
                Params,
                <<"wrapup_duration_ms">>,
                ?DEFAULT_WRAPUP_DURATION_MS
            ),
        {ok, WrapupMaxMs} ?= opt_infinity_ms(Params, <<"wrapup_max_ms">>, infinity),
        {ok, OfferMs} ?=
            opt_infinity_ms(Params, <<"offer_timeout_ms">>, ?DEFAULT_OFFER_TIMEOUT_MS),
        {ok, QualRequired} ?=
            cx_params:optional_boolean(Params, <<"qualification_required">>, false),
        {ok, Status} ?= cx_params:optional_atom(Params, <<"status">>, [open, closed], open),
        ok ?= validate_wrapup_policy(WrapupMs, WrapupMaxMs, QualRequired),
        Rec = #cx_queue{
            key = {T, cx_id:new()},
            name = Name,
            skill_requirements = SkillRequirements,
            wrapup_duration_ms = WrapupMs,
            wrapup_max_ms = WrapupMaxMs,
            offer_timeout_ms = OfferMs,
            qualification_required = QualRequired,
            status = Status
        },
        ok ?= write_checked(T, Rec),
        publish(T, element(2, Rec#cx_queue.key), queue_created),
        {ok, to_map(Rec)}
    end.

get(Ctx = #auth_context{tenant_id = T}, QueueId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"queues:read">>),
        {ok, Rec} ?= cx_store:read(cx_queue, {T, QueueId}),
        {ok, to_map(Rec)}
    end.

list(Ctx = #auth_context{tenant_id = T}) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"queues:read">>),
        Recs = cx_store:list(cx_queue, cx_patterns:queues(T)),
        {ok, [to_map(R) || R <- Recs]}
    end.

update(Ctx = #auth_context{tenant_id = T}, QueueId, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"queues:write">>),
        {ok, Rec0} ?= cx_store:read(cx_queue, {T, QueueId}),
        {ok, Name} ?= cx_params:optional_binary(Params, <<"name">>, Rec0#cx_queue.name),
        {ok, SkillRequirements} ?=
            case Params of
                #{<<"skill_requirements">> := Raw} -> parse_skill_requirements(Raw);
                _ -> {ok, Rec0#cx_queue.skill_requirements}
            end,
        {ok, WrapupMs} ?=
            cx_params:optional_integer(
                Params,
                <<"wrapup_duration_ms">>,
                Rec0#cx_queue.wrapup_duration_ms
            ),
        {ok, WrapupMaxMs} ?=
            opt_infinity_ms(Params, <<"wrapup_max_ms">>, Rec0#cx_queue.wrapup_max_ms),
        {ok, OfferMs} ?=
            opt_infinity_ms(Params, <<"offer_timeout_ms">>, Rec0#cx_queue.offer_timeout_ms),
        {ok, QualRequired} ?=
            cx_params:optional_boolean(
                Params,
                <<"qualification_required">>,
                Rec0#cx_queue.qualification_required
            ),
        {ok, Status} ?=
            cx_params:optional_atom(
                Params,
                <<"status">>,
                [open, closed],
                Rec0#cx_queue.status
            ),
        ok ?= validate_wrapup_policy(WrapupMs, WrapupMaxMs, QualRequired),
        Rec = Rec0#cx_queue{
            name = Name,
            skill_requirements = SkillRequirements,
            wrapup_duration_ms = WrapupMs,
            wrapup_max_ms = WrapupMaxMs,
            offer_timeout_ms = OfferMs,
            qualification_required = QualRequired,
            status = Status
        },
        ok ?= write_checked(T, Rec),
        publish(T, QueueId, queue_updated),
        {ok, to_map(Rec)}
    end.

delete(Ctx = #auth_context{tenant_id = T}, QueueId) ->
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
        SkillIds = [S || #skill_requirement{skill_id = S} <- Rec#cx_queue.skill_requirements],
        Missing = [S || S <- SkillIds, mnesia:read(cx_skill, {T, S}) =:= []],
        case Missing of
            [] -> mnesia:write(Rec);
            _ -> {error, {invalid, <<"skill_requirements">>}}
        end
    end).

to_map(#cx_queue{
    key = {_, Id},
    name = Name,
    skill_requirements = SkillRequirements,
    wrapup_duration_ms = WrapupMs,
    wrapup_max_ms = WrapupMaxMs,
    offer_timeout_ms = OfferMs,
    qualification_required = QualRequired,
    status = Status
}) ->
    #{
        <<"id">> => Id,
        <<"name">> => Name,
        <<"skill_requirements">> => [skill_requirement_to_map(R) || R <- SkillRequirements],
        <<"wrapup_duration_ms">> => WrapupMs,
        <<"wrapup_max_ms">> => infinity_ms_to_json(WrapupMaxMs),
        <<"offer_timeout_ms">> => infinity_ms_to_json(OfferMs),
        <<"qualification_required">> => QualRequired,
        <<"status">> => atom_to_binary(Status)
    }.

%% Cross-field rules, checked on the EFFECTIVE values in both create
%% and update so no edit order can sneak an invalid combination in:
%% mandatory qualification needs a wrap-up window to gate in, and the
%% initial grant must not already exceed the total-ACW cap.
validate_wrapup_policy(WrapupMs, _WrapupMaxMs, true) when WrapupMs =:= 0 ->
    {error, {invalid, <<"qualification_required">>}};
validate_wrapup_policy(WrapupMs, WrapupMaxMs, _QualRequired) when
    WrapupMaxMs =/= infinity, WrapupMs > WrapupMaxMs
->
    {error, {invalid, <<"wrapup_duration_ms">>}};
validate_wrapup_policy(_WrapupMs, _WrapupMaxMs, _QualRequired) ->
    ok.

%% Millisecond durations where 0 on the wire means "no limit"
%% (offer_timeout_ms: ring forever; wrapup_max_ms: uncapped ACW). 0 is
%% free to carry that meaning because a literal 0 ms value would be
%% useless — internally it is stored as 'infinity' so timer and
%% comparison paths need no translation.
opt_infinity_ms(Params, Key, Default) ->
    case Params of
        #{Key := 0} -> {ok, infinity};
        #{Key := V} when is_integer(V), V > 0 -> {ok, V};
        #{Key := _} -> {error, {invalid, Key}};
        _ -> {ok, Default}
    end.

infinity_ms_to_json(infinity) -> 0;
infinity_ms_to_json(Ms) -> Ms.

skill_requirement_to_map(#skill_requirement{
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
parse_skill_requirements(Raw) when is_list(Raw) ->
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
                #skill_requirement{
                    skill_id = SkillId,
                    min_rank = MinRank,
                    widening = Sorted
                }
            end,
            Raw
        ),
        {ok, Reqs}
    catch
        _:_ -> {error, {invalid, <<"skill_requirements">>}}
    end;
parse_skill_requirements(_) ->
    {error, {invalid, <<"skill_requirements">>}}.

publish(TenantId, QueueId, Type) ->
    cx_event:publish(TenantId, QueueId, undefined, Type, #{<<"id">> => QueueId}).
