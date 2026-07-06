-module(cx_qualification_code).

%% Tenant-scoped tree of classification codes (see the record definition
%% in cx_core.hrl). Tree integrity is enforced at write time inside one
%% transaction: parents must exist, reparenting must not create a cycle,
%% and a node with children cannot be deleted. Retiring a code is
%% active=false — history on completed interactions keeps referencing it.

-include("cx_core.hrl").

-export([create/2, get/2, list/1, update/3, delete/2]).
-export([fetch/2, to_map/1]).

create(Ctx = #auth_context{tenant_id = T}, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"qualification_codes:write">>),
        {ok, Name} ?= cx_params:require_binary(Params, <<"name">>),
        {ok, ParentId} ?= parse_parent(Params, undefined),
        Rec = #cx_qualification_code{
            key = {T, cx_id:new()},
            name = Name,
            parent_id = ParentId,
            active = true
        },
        ok ?=
            cx_store:tx(fun() ->
                case parent_ok(T, ParentId) of
                    true -> mnesia:write(Rec);
                    false -> {error, {invalid, <<"parent_id">>}}
                end
            end),
        publish(T, element(2, Rec#cx_qualification_code.key), qualification_code_created),
        {ok, to_map(Rec)}
    end.

%% Reads are open to any tenant member: agents need the tree to qualify.
get(#auth_context{tenant_id = T}, CodeId) ->
    maybe
        {ok, Rec} ?= cx_store:read(cx_qualification_code, {T, CodeId}),
        {ok, to_map(Rec)}
    end.

list(#auth_context{tenant_id = T}) ->
    Recs = cx_store:list(cx_qualification_code, cx_patterns:qualification_codes(T)),
    {ok, [to_map(R) || R <- Recs]}.

update(Ctx = #auth_context{tenant_id = T}, CodeId, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"qualification_codes:write">>),
        {ok, Rec0} ?= cx_store:read(cx_qualification_code, {T, CodeId}),
        {ok, Name} ?=
            cx_params:optional_binary(Params, <<"name">>, Rec0#cx_qualification_code.name),
        {ok, ParentId} ?= parse_parent(Params, Rec0#cx_qualification_code.parent_id),
        {ok, Active} ?=
            cx_params:optional_boolean(Params, <<"active">>, Rec0#cx_qualification_code.active),
        Rec = Rec0#cx_qualification_code{
            name = Name,
            parent_id = ParentId,
            active = Active
        },
        ok ?=
            cx_store:tx(fun() ->
                case
                    parent_ok(T, ParentId) andalso
                        not creates_cycle(T, CodeId, ParentId)
                of
                    true -> mnesia:write(Rec);
                    false -> {error, {invalid, <<"parent_id">>}}
                end
            end),
        publish(T, CodeId, qualification_code_updated),
        {ok, to_map(Rec)}
    end.

delete(Ctx = #auth_context{tenant_id = T}, CodeId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"qualification_codes:write">>),
        ok ?=
            cx_store:tx(fun() ->
                case mnesia:read(cx_qualification_code, {T, CodeId}) of
                    [_] ->
                        Children = mnesia:match_object(
                            cx_patterns:qualification_children(T, CodeId)
                        ),
                        case Children of
                            [] -> mnesia:delete({cx_qualification_code, {T, CodeId}});
                            _ -> {error, in_use}
                        end;
                    [] ->
                        {error, not_found}
                end
            end),
        publish(T, CodeId, qualification_code_deleted),
        ok
    end.

-spec fetch(binary(), binary()) ->
    {ok, #cx_qualification_code{}} | {error, not_found}.
fetch(TenantId, CodeId) ->
    cx_store:read(cx_qualification_code, {TenantId, CodeId}).

to_map(#cx_qualification_code{
    key = {_, Id},
    name = Name,
    parent_id = ParentId,
    active = Active
}) ->
    #{
        <<"id">> => Id,
        <<"name">> => Name,
        <<"parent_id">> => cx_json:undef_to_null(ParentId),
        <<"active">> => Active
    }.

%% parent_id: binary = child of that node, JSON null = root.
parse_parent(Params, Default) ->
    case Params of
        #{<<"parent_id">> := null} -> {ok, undefined};
        #{<<"parent_id">> := V} when is_binary(V), V =/= <<>> -> {ok, V};
        #{<<"parent_id">> := _} -> {error, {invalid, <<"parent_id">>}};
        _ -> {ok, Default}
    end.

%% Runs inside the write transaction.
parent_ok(_T, undefined) -> true;
parent_ok(T, ParentId) -> mnesia:read(cx_qualification_code, {T, ParentId}) =/= [].

%% Would making NewParent the parent of CodeId close a loop? Walk the
%% ancestor chain from NewParent; hitting CodeId means yes. The visited
%% set bounds the walk even if pre-existing data were ever corrupt.
creates_cycle(_T, _CodeId, undefined) ->
    false;
creates_cycle(T, CodeId, NewParent) ->
    walk_ancestors(T, NewParent, CodeId, #{}).

walk_ancestors(_T, undefined, _Target, _Seen) ->
    false;
walk_ancestors(_T, Target, Target, _Seen) ->
    true;
walk_ancestors(T, NodeId, Target, Seen) when not is_map_key(NodeId, Seen) ->
    case mnesia:read(cx_qualification_code, {T, NodeId}) of
        [#cx_qualification_code{parent_id = Up}] ->
            walk_ancestors(T, Up, Target, Seen#{NodeId => true});
        [] ->
            false
    end;
walk_ancestors(_T, _NodeId, _Target, _Seen) ->
    false.

publish(TenantId, CodeId, Type) ->
    cx_event:publish(TenantId, undefined, undefined, Type, #{<<"id">> => CodeId}).
