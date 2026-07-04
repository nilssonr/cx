-module(cx_not_ready_reason).

-include("cx_core.hrl").

-export([create/2, get/2, list/1, update/3, delete/2]).
-export([fetch/2, to_map/1]).

create(Ctx = #auth_ctx{tenant_id = T}, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"not_ready_reasons:write">>),
        {ok, Name} ?= cx_params:require_bin(Params, <<"name">>),
        Rec = #cx_not_ready_reason{key = {T, cx_id:new()}, name = Name, active = true},
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, element(2, Rec#cx_not_ready_reason.key), not_ready_reason_created),
        {ok, to_map(Rec)}
    end.

%% Reads are open to any tenant member: agents need the reason list.
get(#auth_ctx{tenant_id = T}, ReasonId) ->
    maybe
        {ok, Rec} ?= cx_store:read(cx_not_ready_reason, {T, ReasonId}),
        {ok, to_map(Rec)}
    end.

list(#auth_ctx{tenant_id = T}) ->
    Recs = cx_store:list(cx_not_ready_reason, cx_patterns:not_ready_reasons(T)),
    {ok, [to_map(R) || R <- Recs]}.

update(Ctx = #auth_ctx{tenant_id = T}, ReasonId, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"not_ready_reasons:write">>),
        {ok, Rec0} ?= cx_store:read(cx_not_ready_reason, {T, ReasonId}),
        {ok, Name} ?= cx_params:opt_bin(Params, <<"name">>, Rec0#cx_not_ready_reason.name),
        {ok, Active} ?= parse_active(Params, Rec0#cx_not_ready_reason.active),
        Rec = Rec0#cx_not_ready_reason{name = Name, active = Active},
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, ReasonId, not_ready_reason_updated),
        {ok, to_map(Rec)}
    end.

delete(Ctx = #auth_ctx{tenant_id = T}, ReasonId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"not_ready_reasons:write">>),
        ok ?=
            cx_store:tx(fun() ->
                case mnesia:read(cx_not_ready_reason, {T, ReasonId}) of
                    [_] -> mnesia:delete({cx_not_ready_reason, {T, ReasonId}});
                    [] -> {error, not_found}
                end
            end),
        publish(T, ReasonId, not_ready_reason_deleted),
        ok
    end.

-spec fetch(binary(), binary()) -> {ok, #cx_not_ready_reason{}} | {error, not_found}.
fetch(TenantId, ReasonId) ->
    cx_store:read(cx_not_ready_reason, {TenantId, ReasonId}).

to_map(#cx_not_ready_reason{key = {_, Id}, name = Name, active = Active}) ->
    #{<<"id">> => Id, <<"name">> => Name, <<"active">> => Active}.

parse_active(Params, Default) ->
    case Params of
        #{<<"active">> := B} when is_boolean(B) -> {ok, B};
        #{<<"active">> := _} -> {error, {invalid, <<"active">>}};
        _ -> {ok, Default}
    end.

publish(TenantId, ReasonId, Type) ->
    cx_event:publish(
        TenantId,
        undefined,
        undefined,
        #{
            type => Type,
            at => cx_time:now_ms(),
            data => #{<<"id">> => ReasonId}
        }
    ).
