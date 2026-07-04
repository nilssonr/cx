-module(cx_routing_profile).

-include("cx_core.hrl").

-export([create/2, get/2, list/1, update/3, delete/2]).
-export([fetch/2, to_map/1]).

create(Ctx = #auth_ctx{tenant_id = T}, Params) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"routing_profiles:write">>),
        {ok, Name} ?= cx_params:require_bin(Params, <<"name">>),
        {ok, MaxTotal} ?= parse_max_total(Params, unlimited),
        {ok, MediaCaps} ?= parse_media_caps(Params, #{}),
        {ok, Guards} ?=
            case Params of
                #{<<"guards">> := Raw} -> parse_guards(Raw);
                _ -> {ok, []}
            end,
        Rec = #cx_routing_profile{
            key = {T, cx_id:new()},
            name = Name,
            max_total = MaxTotal,
            media_caps = MediaCaps,
            guards = Guards
        },
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, element(2, Rec#cx_routing_profile.key), routing_profile_created),
        {ok, to_map(Rec)}
    end.

get(#auth_ctx{tenant_id = T}, ProfileId) ->
    maybe
        {ok, Rec} ?= cx_store:read(cx_routing_profile, {T, ProfileId}),
        {ok, to_map(Rec)}
    end.

list(#auth_ctx{tenant_id = T}) ->
    Recs = cx_store:list(cx_routing_profile, cx_patterns:routing_profiles(T)),
    {ok, [to_map(R) || R <- Recs]}.

update(Ctx = #auth_ctx{tenant_id = T}, ProfileId, Params) ->
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
        {ok, MediaCaps} ?= parse_media_caps(Params, Rec0#cx_routing_profile.media_caps),
        {ok, Guards} ?=
            case Params of
                #{<<"guards">> := Raw} -> parse_guards(Raw);
                _ -> {ok, Rec0#cx_routing_profile.guards}
            end,
        Rec = Rec0#cx_routing_profile{
            name = Name,
            max_total = MaxTotal,
            media_caps = MediaCaps,
            guards = Guards
        },
        ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
        publish(T, ProfileId, routing_profile_updated),
        {ok, to_map(Rec)}
    end.

delete(Ctx = #auth_ctx{tenant_id = T}, ProfileId) ->
    maybe
        ok ?= cx_authz:require(Ctx, <<"routing_profiles:write">>),
        ok ?=
            cx_store:tx(fun() ->
                case mnesia:read(cx_routing_profile, {T, ProfileId}) of
                    [_] -> mnesia:delete({cx_routing_profile, {T, ProfileId}});
                    [] -> {error, not_found}
                end
            end),
        publish(T, ProfileId, routing_profile_deleted),
        ok
    end.

-spec fetch(binary(), binary()) -> {ok, #cx_routing_profile{}} | {error, not_found}.
fetch(TenantId, ProfileId) ->
    cx_store:read(cx_routing_profile, {TenantId, ProfileId}).

to_map(#cx_routing_profile{
    key = {_, Id},
    name = Name,
    max_total = MaxTotal,
    media_caps = MediaCaps,
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
        <<"media_caps">> => MediaCaps,
        <<"guards">> => [guard_to_map(G) || G <- Guards]
    }.

guard_to_map(#rp_guard{when_media = W, gte = Gte, block = Block}) ->
    #{<<"when_media">> => W, <<"gte">> => Gte, <<"block">> => Block}.

%% max_total: positive integer, or null/absent for unlimited.
parse_max_total(Params, Default) ->
    case Params of
        #{<<"max_total">> := null} -> {ok, unlimited};
        #{<<"max_total">> := N} when is_integer(N), N > 0 -> {ok, N};
        #{<<"max_total">> := _} -> {error, {invalid, <<"max_total">>}};
        _ -> {ok, Default}
    end.

parse_media_caps(Params, Default) ->
    case cx_params:opt_map(Params, <<"media_caps">>, Default) of
        {ok, Caps} ->
            Valid = lists:all(
                fun({K, V}) -> is_binary(K) andalso is_integer(V) andalso V >= 0 end,
                maps:to_list(Caps)
            ),
            case Valid of
                true -> {ok, Caps};
                false -> {error, {invalid, <<"media_caps">>}}
            end;
        Error ->
            Error
    end.

%% [{"when_media": "voice", "gte": 1, "block": ["chat", "email"]}]
parse_guards(Raw) when is_list(Raw) ->
    try
        Guards = lists:map(
            fun(M) when is_map(M) ->
                W = maps:get(<<"when_media">>, M),
                Gte = maps:get(<<"gte">>, M),
                Block = maps:get(<<"block">>, M),
                true = is_binary(W) andalso W =/= <<>>,
                true = is_integer(Gte) andalso Gte > 0,
                true =
                    is_list(Block) andalso Block =/= [] andalso
                        lists:all(fun is_binary/1, Block),
                #rp_guard{when_media = W, gte = Gte, block = Block}
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
    cx_event:publish(
        TenantId,
        undefined,
        undefined,
        #{
            type => Type,
            at => cx_time:now_ms(),
            data => #{<<"id">> => ProfileId}
        }
    ).
