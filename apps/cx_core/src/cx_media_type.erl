-module(cx_media_type).

-include("cx_core.hrl").

-export([create/2, get/2, list/1, update/3, delete/2]).
-export([fetch/2, to_map/1]).

create(Ctx = #auth_ctx{tenant_id = T}, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"media_types:write">>),
        {ok, Name} ?= cx_params:require_bin(Params, <<"name">>),
        {ok, Config} ?= cx_params:opt_map(Params, <<"config">>, #{}),
        Rec = #cx_media_type{key = {T, cx_id:new()}, name = Name, config = Config},
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, element(2, Rec#cx_media_type.key), media_type_created),
        {ok, to_map(Rec)}
    end.

get(#auth_ctx{tenant_id = T}, MediaTypeId) ->
    maybe
        {ok, Rec} ?= cx_store:read(cx_media_type, {T, MediaTypeId}),
        {ok, to_map(Rec)}
    end.

list(#auth_ctx{tenant_id = T}) ->
    Recs = cx_store:list(cx_media_type, cx_patterns:media_types(T)),
    {ok, [to_map(R) || R <- Recs]}.

update(Ctx = #auth_ctx{tenant_id = T}, MediaTypeId, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"media_types:write">>),
        {ok, Rec0} ?= cx_store:read(cx_media_type, {T, MediaTypeId}),
        {ok, Name} ?= cx_params:opt_bin(Params, <<"name">>, Rec0#cx_media_type.name),
        {ok, Config} ?= cx_params:opt_map(Params, <<"config">>, Rec0#cx_media_type.config),
        Rec = Rec0#cx_media_type{name = Name, config = Config},
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, MediaTypeId, media_type_updated),
        {ok, to_map(Rec)}
    end.

delete(Ctx = #auth_ctx{tenant_id = T}, MediaTypeId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"media_types:write">>),
        ok ?= cx_store:tx(fun() ->
            case mnesia:read(cx_media_type, {T, MediaTypeId}) of
                [_] -> mnesia:delete({cx_media_type, {T, MediaTypeId}});
                [] -> {error, not_found}
            end
        end),
        publish(T, MediaTypeId, media_type_deleted),
        ok
    end.

-spec fetch(binary(), binary()) -> {ok, #cx_media_type{}} | {error, not_found}.
fetch(TenantId, MediaTypeId) ->
    cx_store:read(cx_media_type, {TenantId, MediaTypeId}).

to_map(#cx_media_type{key = {_, Id}, name = Name, config = Config}) ->
    #{<<"id">> => Id, <<"name">> => Name, <<"config">> => Config}.

publish(TenantId, MediaTypeId, Type) ->
    cx_event:publish(TenantId, undefined, MediaTypeId,
                     #{type => Type, at => cx_time:now_ms(),
                       data => #{<<"id">> => MediaTypeId}}).
