-module(cx_routing_profile).

-include("cx_core.hrl").

-export([create/2, get/2, list/1, update/3, delete/2]).
-export([fetch/2, to_map/1]).

create(Ctx = #auth_context{tenant_id = T}, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"routing_profiles:write">>),
        {ok, Name} ?= cx_params:require_bin(Params, <<"name">>),
        {ok, MaxTotal} ?= parse_max_total(Params, unlimited),
        {ok, MediaCaps} ?= parse_media_capacities(Params, #{}),
        {ok, Guards} ?=
            case Params of
                #{<<"guards">> := Raw} -> parse_guards(Raw);
                _ -> {ok, []}
            end,
        Rec = #cx_routing_profile{
            key = {T, cx_id:new()},
            name = Name,
            max_total = MaxTotal,
            media_capacities = MediaCaps,
            guards = Guards
        },
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, element(2, Rec#cx_routing_profile.key), routing_profile_created),
        {ok, to_map(Rec)}
    end.

get(#auth_context{tenant_id = T}, ProfileId) ->
    maybe
        {ok, Rec} ?= cx_store:read(cx_routing_profile, {T, ProfileId}),
        {ok, to_map(Rec)}
    end.

list(#auth_context{tenant_id = T}) ->
    Recs = cx_store:list(cx_routing_profile, cx_patterns:routing_profiles(T)),
    {ok, [to_map(R) || R <- Recs]}.

update(Ctx = #auth_context{tenant_id = T}, ProfileId, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"routing_profiles:write">>),
        {ok, Rec0} ?= cx_store:read(cx_routing_profile, {T, ProfileId}),
        {ok, Name} ?=
            cx_params:opt_bin(
                Params,
                <<"name">>,
                Rec0#cx_routing_profile.name
            ),
        {ok, MaxTotal} ?= parse_max_total(Params, Rec0#cx_routing_profile.max_total),
        {ok, MediaCaps} ?= parse_media_capacities(Params, Rec0#cx_routing_profile.media_capacities),
        {ok, Guards} ?=
            case Params of
                #{<<"guards">> := Raw} -> parse_guards(Raw);
                _ -> {ok, Rec0#cx_routing_profile.guards}
            end,
        Rec = Rec0#cx_routing_profile{
            name = Name,
            max_total = MaxTotal,
            media_capacities = MediaCaps,
            guards = Guards
        },
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, ProfileId, routing_profile_updated),
        {ok, to_map(Rec)}
    end.

%% Deleting a profile users reference is blocked (409): a dangling
%% profile reference must never happen — the session-start fallback for
%% it fails closed, refusing the session.
delete(Ctx = #auth_context{tenant_id = T}, ProfileId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"routing_profiles:write">>),
        ok ?=
            cx_store:tx(fun() ->
                case mnesia:read(cx_routing_profile, {T, ProfileId}) of
                    [] ->
                        {error, not_found};
                    [_] ->
                        case referenced(T, ProfileId) of
                            true -> {error, in_use};
                            false -> mnesia:delete({cx_routing_profile, {T, ProfileId}})
                        end
                end
            end),
        publish(T, ProfileId, routing_profile_deleted),
        ok
    end.

referenced(T, ProfileId) ->
    lists:any(
        fun(#cx_user{routing_profile_id = P}) -> P =:= ProfileId end,
        mnesia:match_object(cx_patterns:users(T))
    ).

-spec fetch(binary(), binary()) -> {ok, #cx_routing_profile{}} | {error, not_found}.
fetch(TenantId, ProfileId) ->
    cx_store:read(cx_routing_profile, {TenantId, ProfileId}).

to_map(#cx_routing_profile{
    key = {_, Id},
    name = Name,
    max_total = MaxTotal,
    media_capacities = MediaCaps,
    guards = Guards
}) ->
    #{
        <<"id">> => Id,
        <<"name">> => Name,
        <<"max_total">> =>
            case MaxTotal of
                unlimited -> null;
                N -> N
            end,
        <<"media_capacities">> => MediaCaps,
        <<"guards">> => [guard_to_map(G) || G <- Guards]
    }.

guard_to_map(#routing_profile_guard{when_media = W, at_least = AtLeast, block = Block}) ->
    #{<<"when_media">> => W, <<"at_least">> => AtLeast, <<"block">> => Block}.

%% max_total: positive integer, or null/absent for unlimited.
parse_max_total(Params, Default) ->
    case Params of
        #{<<"max_total">> := null} -> {ok, unlimited};
        #{<<"max_total">> := N} when is_integer(N), N > 0 -> {ok, N};
        #{<<"max_total">> := _} -> {error, {invalid, <<"max_total">>}};
        _ -> {ok, Default}
    end.

%% Media names in caps and guards must come from cx_media:all() — a
%% guard referencing a nonexistent media type would be dead config that
%% silently never fires, so it's rejected at write time instead.
parse_media_capacities(Params, Default) ->
    case cx_params:opt_map(Params, <<"media_capacities">>, Default) of
        {ok, Capacities} ->
            Valid = lists:all(
                fun({K, V}) ->
                    cx_media:is_valid(K) andalso is_integer(V) andalso V >= 0
                end,
                maps:to_list(Capacities)
            ),
            case Valid of
                true -> {ok, Capacities};
                false -> {error, {invalid, <<"media_capacities">>}}
            end;
        Error ->
            Error
    end.

%% [{"when_media": "voice", "at_least": 1, "block": ["chat", "email"]}]
parse_guards(Raw) when is_list(Raw) ->
    try
        Guards = lists:map(
            fun(M) when is_map(M) ->
                W = maps:get(<<"when_media">>, M),
                AtLeast = maps:get(<<"at_least">>, M),
                Block = maps:get(<<"block">>, M),
                true = cx_media:is_valid(W),
                true = is_integer(AtLeast) andalso AtLeast > 0,
                true =
                    is_list(Block) andalso Block =/= [] andalso
                        lists:all(fun cx_media:is_valid/1, Block),
                #routing_profile_guard{when_media = W, at_least = AtLeast, block = Block}
            end,
            Raw
        ),
        {ok, Guards}
    catch
        _:_ -> {error, {invalid, <<"guards">>}}
    end;
parse_guards(_) ->
    {error, {invalid, <<"guards">>}}.

publish(TenantId, ProfileId, Type) ->
    cx_event:publish(TenantId, undefined, undefined, Type, #{<<"id">> => ProfileId}).
