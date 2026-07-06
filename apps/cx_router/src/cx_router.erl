-module(cx_router).

%% Domain facade for the router: every operation a transport (REST today,
%% gRPC/GraphQL later) can invoke exists here as a plain function taking
%% an #auth_ctx{}. Permission checks live here or below — never in
%% transports.

-include_lib("cx_core/include/cx_core.hrl").

-export([start_session/1, stop_session/1, stop_session/2, get_session/1]).
-export([force_stop_session/2]).
-export([set_ready/3]).
-export([create_interaction/2, cancel_interaction/2, get_interaction/2]).
-export([list_interactions/2, agent_interactions/1]).
-export([accept_offer/2, reject_offer/2]).
-export([complete/2, hold/2, resume/2, qualify/3]).
-export([extend_wrapup/3, finalize_wrapup/2]).

-define(CALL_TIMEOUT, 10000).

%% ---- agent session lifecycle ----

%% Idempotent sign-in: the token identity IS the natural idempotency
%% key (one session per {tenant, user}), so a retried POST returns the
%% live session's state exactly like GET would.
start_session(Ctx = #auth_ctx{tenant_id = T, user_id = UserId}) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:session:self">>),
        ok ?= cx_authz:require_user(Ctx),
        {ok, User} ?= cx_user:fetch(T, UserId),
        ok ?= active_user(User),
        {ok, Profile} ?= load_profile(T, User#cx_user.routing_profile_id),
        case
            cx_agent_session_sup:start_session(
                T,
                UserId,
                User#cx_user.skills,
                Profile
            )
        of
            {ok, Pid} -> call(Pid, get_state);
            {error, {already_started, Pid}} -> call(Pid, get_state)
        end
    end.

stop_session(Ctx) ->
    stop_session(Ctx, false).

%% Idempotent sign-out: no session to delete is already the desired
%% state. Force requeues engaged work and finalizes ACW (the escape
%% hatch past has_active_interactions and qualification_required).
stop_session(Ctx = #auth_ctx{}, Force) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:session:self">>),
        case {session_of(Ctx), Force} of
            {{ok, Pid}, true} -> call(Pid, force_stop_session);
            {{ok, Pid}, false} -> call(Pid, stop_session);
            {{error, no_session}, _} -> ok
        end
    end.

%% Supervisor kick-out — a separate, deliberately grantable authority.
force_stop_session(Ctx = #auth_ctx{tenant_id = T}, UserId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:session:any">>),
        case cx_reg:whereis_name({agent, T, UserId}) of
            Pid when is_pid(Pid) -> call(Pid, force_stop_session);
            undefined -> ok
        end
    end.

get_session(Ctx = #auth_ctx{}) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:session:self">>),
        {ok, Pid} ?= session_of(Ctx),
        call(Pid, get_state)
    end.

%% ---- readiness ----

set_ready(Ctx = #auth_ctx{tenant_id = T}, Media, ReadyState) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:ready:self">>),
        ok ?= valid_media(Media),
        ok ?= validate_reason(T, ReadyState),
        {ok, Pid} ?= session_of(Ctx),
        call(Pid, {set_ready, Media, ReadyState})
    end.

valid_media(Media) ->
    case cx_media:is_valid(Media) of
        true -> ok;
        false -> {error, {invalid, <<"media_type">>}}
    end.

validate_reason(_T, ready) ->
    ok;
validate_reason(_T, {not_ready, undefined}) ->
    ok;
validate_reason(T, {not_ready, ReasonId}) ->
    case cx_not_ready_reason:fetch(T, ReasonId) of
        {ok, #cx_not_ready_reason{active = true}} -> ok;
        {ok, #cx_not_ready_reason{active = false}} -> {error, {invalid, <<"reason_id">>}};
        {error, not_found} -> {error, {invalid, <<"reason_id">>}}
    end.

%% ---- interactions (Open Media rides on this directly) ----

create_interaction(Ctx = #auth_ctx{tenant_id = T}, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"interactions:create">>),
        {ok, QueueId} ?= cx_params:require_bin(Params, <<"queue_id">>),
        {ok, Media} ?= cx_params:require_bin(Params, <<"media_type">>),
        ok ?= valid_media(Media),
        {ok, Props} ?= validate_properties(Params),
        {ok, Queue} ?= cx_queue:fetch(T, QueueId),
        ok ?= open_queue(Queue),
        {ok, QPid} ?= cx_queue_proc:ensure_started(T, QueueId),
        {ok, IId} ?= call(QPid, {enqueue, cx_id:new(), Media, Props, cx_time:now_ms()}),
        {ok, #{<<"id">> => IId}}
    end.

cancel_interaction(Ctx = #auth_ctx{tenant_id = T}, IId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"interactions:cancel">>),
        {ok, Rec} ?= cx_store:read(cx_interaction, {T, IId}),
        {_, QueueId} = Rec#cx_interaction.queue_key,
        {ok, QPid} ?= cx_queue_proc:ensure_started(T, QueueId),
        call(QPid, {cancel, IId})
    end.

get_interaction(Ctx = #auth_ctx{tenant_id = T}, IId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"interactions:read">>),
        {ok, Rec} ?= cx_store:read(cx_interaction, {T, IId}),
        {ok, interaction_to_map(Rec)}
    end.

%% Tenant-wide, filterable, cursor-paginated. Filters arrive as the raw
%% query-string map; unknown keys are ignored, malformed values are 422.
%% M1 scale note: this match-objects the tenant's interactions and
%% filters/sorts in memory — revisit with a real index when volume says so.
list_interactions(Ctx = #auth_ctx{tenant_id = T}, Filters) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"interactions:read">>),
        {ok, Limit} ?= parse_limit(Filters),
        ok ?= valid_filters(Filters),
        Recs = cx_store:dirty_list(cx_interaction, cx_patterns:interactions(T)),
        Matching = [R || R <- Recs, matches_filters(R, Filters)],
        Sorted = lists:sort(fun newest_first/2, Matching),
        Page = page_after(Sorted, maps:get(<<"after">>, Filters, undefined), Limit),
        Next =
            case length(Page) =:= Limit andalso Page =/= [] of
                true -> element(2, (lists:last(Page))#cx_interaction.key);
                false -> null
            end,
        {ok, #{
            <<"items">> => [interaction_to_map(R) || R <- Page],
            <<"next">> => Next
        }}
    end.

%% The agent's own interactions in full detail — the rehydration surface
%% a reconnecting client uses instead of replaying missed events.
agent_interactions(Ctx = #auth_ctx{tenant_id = T}) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:interactions:self">>),
        {ok, Pid} ?= session_of(Ctx),
        {ok, IIds} ?= call(Pid, list_work),
        Recs = [
            Rec
         || IId <- IIds,
            Rec <- [
                case cx_store:read(cx_interaction, {T, IId}) of
                    {ok, R} -> R;
                    {error, not_found} -> undefined
                end
            ],
            Rec =/= undefined
        ],
        {ok, [interaction_to_map(R) || R <- lists:sort(fun oldest_first/2, Recs)]}
    end.

-define(LIST_LIMIT_DEFAULT, 50).
-define(LIST_LIMIT_MAX, 200).

parse_limit(Filters) ->
    case Filters of
        #{<<"limit">> := Raw} when is_binary(Raw) ->
            try binary_to_integer(Raw) of
                N when N >= 1, N =< ?LIST_LIMIT_MAX -> {ok, N};
                _ -> {error, {invalid, <<"limit">>}}
            catch
                error:badarg -> {error, {invalid, <<"limit">>}}
            end;
        #{<<"limit">> := _} ->
            {error, {invalid, <<"limit">>}};
        _ ->
            {ok, ?LIST_LIMIT_DEFAULT}
    end.

valid_filters(Filters) ->
    States = [
        <<"queued">>,
        <<"offered">>,
        <<"active">>,
        <<"held">>,
        <<"wrapup">>,
        <<"completed">>,
        <<"cancelled">>
    ],
    maybe
        ok ?=
            case Filters of
                #{<<"state">> := S} ->
                    case lists:member(S, States) of
                        true -> ok;
                        false -> {error, {invalid, <<"state">>}}
                    end;
                _ ->
                    ok
            end,
        case Filters of
            #{<<"media_type">> := M} -> valid_media(M);
            _ -> ok
        end
    end.

matches_filters(Rec, Filters) ->
    {_, QueueId} = Rec#cx_interaction.queue_key,
    Checks = [
        {<<"queue_id">>, QueueId},
        {<<"state">>, atom_to_binary(Rec#cx_interaction.state)},
        {<<"media_type">>, Rec#cx_interaction.media_type},
        {<<"agent_id">>, Rec#cx_interaction.agent_id}
    ],
    lists:all(
        fun({Key, Actual}) ->
            case Filters of
                #{Key := Want} -> Want =:= Actual;
                _ -> true
            end
        end,
        Checks
    ).

newest_first(A, B) ->
    {A#cx_interaction.created_at, A#cx_interaction.key} >=
        {B#cx_interaction.created_at, B#cx_interaction.key}.

oldest_first(A, B) ->
    {A#cx_interaction.accepted_at, A#cx_interaction.key} =<
        {B#cx_interaction.accepted_at, B#cx_interaction.key}.

page_after(Sorted, undefined, Limit) ->
    lists:sublist(Sorted, Limit);
page_after(Sorted, AfterId, Limit) when is_binary(AfterId) ->
    Rest = lists:dropwhile(
        fun(R) -> element(2, R#cx_interaction.key) =/= AfterId end,
        Sorted
    ),
    case Rest of
        %% unknown/expired cursor: an empty page, never an error
        [] -> [];
        [_ | Tail] -> lists:sublist(Tail, Limit)
    end;
page_after(_Sorted, _, _Limit) ->
    [].

%% ---- offer handling and completion (the agent side) ----

%% A retried accept (response lost, client resent) is served from the
%% session's recent-accept tombstones: same 200, same interaction_id.
accept_offer(Ctx, OfferId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:offers:self">>),
        {ok, Pid} ?= session_of(Ctx),
        case call(Pid, {pending_queue, OfferId}) of
            {ok, QueuePid} ->
                case call(QueuePid, {accepted, OfferId}) of
                    {ok, IId} -> {ok, #{<<"interaction_id">> => IId}};
                    Error -> Error
                end;
            {recently_accepted, IId} ->
                {ok, #{<<"interaction_id">> => IId}};
            Error ->
                Error
        end
    end.

reject_offer(Ctx, OfferId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:offers:self">>),
        {ok, Pid} ?= session_of(Ctx),
        case call(Pid, {pending_queue, OfferId}) of
            {ok, QueuePid} -> call(QueuePid, {rejected, OfferId});
            %% you already accepted it; rejecting now is a stale race
            {recently_accepted, _} -> {error, expired};
            Error -> Error
        end
    end.

%% ---- owned-interaction operations ----

%% Retried complete: the session no longer knows the interaction, but if
%% the row says this agent already completed it, the desired state holds.
complete(Ctx, IId) ->
    case interaction_op(Ctx, <<"agent:interactions:self">>, {complete, IId}) of
        {error, not_found} -> completed_by_me(Ctx, IId);
        Result -> Result
    end.

hold(Ctx, IId) ->
    interaction_op(Ctx, <<"agent:interactions:self">>, {hold, IId}).

resume(Ctx, IId) ->
    interaction_op(Ctx, <<"agent:interactions:self">>, {resume, IId}).

%% PUT-semantics: the given list REPLACES the interaction's codes ([]
%% clears them). Any active node of the tenant's tree is selectable.
qualify(Ctx = #auth_ctx{tenant_id = T}, IId, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:interactions:self">>),
        {ok, Ids} ?= parse_qualification_ids(Params),
        ok ?= validate_qualifications(T, Ids),
        {ok, Pid} ?= session_of(Ctx),
        call(Pid, {qualify, IId, Ids})
    end.

parse_qualification_ids(Params) ->
    case Params of
        #{<<"qualification_ids">> := Ids} when is_list(Ids) ->
            case lists:all(fun(Id) -> is_binary(Id) andalso Id =/= <<>> end, Ids) of
                true -> {ok, lists:usort(Ids)};
                false -> {error, {invalid, <<"qualification_ids">>}}
            end;
        _ ->
            {error, {invalid, <<"qualification_ids">>}}
    end.

validate_qualifications(_T, []) ->
    ok;
validate_qualifications(T, [Id | Rest]) ->
    case cx_qualification_code:fetch(T, Id) of
        {ok, #cx_qualification_code{active = true}} -> validate_qualifications(T, Rest);
        {ok, #cx_qualification_code{active = false}} -> {error, {invalid, <<"qualification_ids">>}};
        {error, not_found} -> {error, {invalid, <<"qualification_ids">>}}
    end.

%% ---- after-call work (per interaction) ----

extend_wrapup(Ctx, IId, ExtraMs) when is_integer(ExtraMs), ExtraMs > 0 ->
    interaction_op(Ctx, <<"agent:wrapup:self">>, {extend_wrapup, IId, ExtraMs});
extend_wrapup(_Ctx, _IId, _) ->
    {error, {invalid, <<"extend_ms">>}}.

finalize_wrapup(Ctx, IId) ->
    case interaction_op(Ctx, <<"agent:wrapup:self">>, {finalize_wrapup, IId}) of
        {error, not_found} -> completed_by_me(Ctx, IId);
        Result -> Result
    end.

interaction_op(Ctx, Perm, Msg) ->
    maybe
        ok ?= cx_authz:require(Ctx, Perm),
        {ok, Pid} ?= session_of(Ctx),
        call(Pid, Msg)
    end.

completed_by_me(#auth_ctx{tenant_id = T, user_id = UserId}, IId) ->
    case cx_store:read(cx_interaction, {T, IId}) of
        {ok, #cx_interaction{state = completed, agent_id = UserId}} when
            UserId =/= undefined
        ->
            ok;
        _ ->
            {error, not_found}
    end.

%% ---- helpers ----

session_of(#auth_ctx{tenant_id = T, user_id = UserId}) ->
    case
        UserId =/= undefined andalso
            cx_reg:whereis_name({agent, T, UserId})
    of
        Pid when is_pid(Pid) -> {ok, Pid};
        _ -> {error, no_session}
    end.

call(Pid, Msg) ->
    try
        gen_statem:call(Pid, Msg, ?CALL_TIMEOUT)
    catch
        exit:{noproc, _} -> {error, no_session}
    end.

active_user(#cx_user{status = active}) -> ok;
active_user(#cx_user{}) -> {error, forbidden}.

load_profile(_T, undefined) ->
    %% no profile configured: nothing is limited (the superhuman default)
    {ok, #cx_routing_profile{key = {<<>>, <<>>}, name = <<"unlimited">>}};
load_profile(T, ProfileId) ->
    %% a configured-but-missing profile fails CLOSED: refusing the session
    %% is recoverable, silently substituting unlimited capacity is not
    case cx_routing_profile:fetch(T, ProfileId) of
        {ok, Profile} -> {ok, Profile};
        {error, not_found} -> {error, profile_missing}
    end.

open_queue(#cx_queue{status = open}) -> ok;
open_queue(#cx_queue{}) -> {error, queue_closed}.

validate_properties(Params) ->
    case cx_params:opt_map(Params, <<"properties">>, #{}) of
        {ok, Props} ->
            Valid = lists:all(
                fun({K, V}) -> is_binary(K) andalso is_binary(V) end,
                maps:to_list(Props)
            ),
            case Valid of
                true -> {ok, Props};
                false -> {error, {invalid, <<"properties">>}}
            end;
        Error ->
            Error
    end.

interaction_to_map(#cx_interaction{
    key = {_, Id},
    queue_key = {_, QueueId},
    media_type = Media,
    properties = Props,
    state = State,
    agent_id = AgentId,
    created_at = CreatedAt,
    enqueued_at = EnqueuedAt,
    accepted_at = AcceptedAt,
    wrapup_started_at = WrapupStartedAt,
    wrapup_until = WrapupUntil,
    qualification_ids = QualificationIds,
    completed_at = CompletedAt
}) ->
    #{
        <<"id">> => Id,
        <<"queue_id">> => QueueId,
        <<"media_type">> => Media,
        <<"properties">> => Props,
        <<"state">> => atom_to_binary(State),
        <<"agent_id">> => cx_json:undef_to_null(AgentId),
        <<"created_at">> => CreatedAt,
        <<"enqueued_at">> => EnqueuedAt,
        <<"accepted_at">> => cx_json:undef_to_null(AcceptedAt),
        <<"wrapup_started_at">> => cx_json:undef_to_null(WrapupStartedAt),
        <<"wrapup_until">> => cx_json:undef_to_null(WrapupUntil),
        <<"qualification_ids">> => QualificationIds,
        <<"completed_at">> => cx_json:undef_to_null(CompletedAt)
    }.
