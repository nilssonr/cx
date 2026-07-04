-module(cx_router).

%% Domain facade for the router: every operation a transport (REST today,
%% gRPC/GraphQL later) can invoke exists here as a plain function taking
%% an #auth_ctx{}. Permission checks live here or below — never in
%% transports.

-include_lib("cx_core/include/cx_core.hrl").

-export([start_session/1, stop_session/1, get_session/1]).
-export([set_ready/3]).
-export([create_interaction/2, cancel_interaction/2, get_interaction/2]).
-export([accept_offer/2, reject_offer/2, complete/2]).
-export([extend_wrapup/2, cancel_wrapup/1]).

-define(CALL_TIMEOUT, 10000).

%% ---- agent session lifecycle ----

start_session(Ctx = #auth_ctx{tenant_id = T, user_id = UserId}) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:session:self">>),
        ok ?= known_user(UserId),
        {ok, User} ?= cx_user:fetch(T, UserId),
        ok ?= active_user(User),
        Profile = load_profile(T, User#cx_user.routing_profile_id),
        case
            cx_agent_session_sup:start_session(
                T,
                UserId,
                User#cx_user.skills,
                Profile
            )
        of
            {ok, _Pid} -> {ok, #{<<"agent_id">> => UserId}};
            {error, {already_started, _}} -> {error, already_started}
        end
    end.

stop_session(Ctx = #auth_ctx{}) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:session:self">>),
        {ok, Pid} ?= session_of(Ctx),
        call(Pid, stop_session)
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

%% ---- offer handling and completion (the agent side) ----

accept_offer(Ctx, OfferId) ->
    offer_op(Ctx, OfferId, accepted).

reject_offer(Ctx, OfferId) ->
    offer_op(Ctx, OfferId, rejected).

offer_op(Ctx, OfferId, Op) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:offers:self">>),
        {ok, Pid} ?= session_of(Ctx),
        {ok, QueuePid} ?= call(Pid, {pending_queue, OfferId}),
        call(QueuePid, {Op, OfferId})
    end.

complete(Ctx, IId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:offers:self">>),
        {ok, Pid} ?= session_of(Ctx),
        call(Pid, {complete, IId})
    end.

%% ---- wrap-up ----

extend_wrapup(Ctx, ExtraMs) when is_integer(ExtraMs), ExtraMs > 0 ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:wrapup:self">>),
        {ok, Pid} ?= session_of(Ctx),
        call(Pid, {extend_wrapup, ExtraMs})
    end;
extend_wrapup(_Ctx, _) ->
    {error, {invalid, <<"extend_ms">>}}.

cancel_wrapup(Ctx) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"agent:wrapup:self">>),
        {ok, Pid} ?= session_of(Ctx),
        call(Pid, cancel_wrapup)
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

known_user(undefined) -> {error, no_user};
known_user(_) -> ok.

active_user(#cx_user{status = active}) -> ok;
active_user(#cx_user{}) -> {error, forbidden}.

load_profile(_T, undefined) ->
    %% no profile configured: nothing is limited (the superhuman default)
    #cx_routing_profile{key = {<<>>, <<>>}, name = <<"unlimited">>};
load_profile(T, ProfileId) ->
    case cx_routing_profile:fetch(T, ProfileId) of
        {ok, Profile} -> Profile;
        {error, not_found} -> #cx_routing_profile{key = {<<>>, <<>>}, name = <<"unlimited">>}
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
    completed_at = CompletedAt
}) ->
    #{
        <<"id">> => Id,
        <<"queue_id">> => QueueId,
        <<"media_type">> => Media,
        <<"properties">> => Props,
        <<"state">> => atom_to_binary(State),
        <<"agent_id">> => undef_to_null(AgentId),
        <<"created_at">> => CreatedAt,
        <<"enqueued_at">> => EnqueuedAt,
        <<"accepted_at">> => undef_to_null(AcceptedAt),
        <<"completed_at">> => undef_to_null(CompletedAt)
    }.

undef_to_null(undefined) -> null;
undef_to_null(V) -> V.
