-module(cx_ws_proto).

%% Pure protocol layer for the WebSocket transport: client-frame
%% decoding, server-frame encoding and the event filter. No processes,
%% no sockets — fully unit-testable.

-export([decode/1, event_frame/3, ready_frame/3, pong_frame/0, error_frame/1]).
-export([relevant/2]).

%% Events an agent receives about THEMSELVES (matched on data.agent_id).
-define(USER_EVENTS, [
    offer_created,
    offer_accepted,
    offer_rejected,
    offer_timeout,
    interaction_requeued,
    interaction_completed,
    wrapup_started,
    wrapup_extended,
    wrapup_cancelled,
    wrapup_ended,
    agent_ready_changed,
    session_started,
    session_ended
]).

%% Events every tenant member receives.
-define(TENANT_EVENTS, [presence_changed]).

%% ---- client -> server ----

-spec decode(binary()) ->
    {auth, binary(), binary() | undefined}
    | ping
    | activity
    | {error, invalid_frame}.
decode(Frame) ->
    case cx_json:decode(Frame) of
        {ok, #{<<"type">> := <<"auth">>, <<"token">> := Token} = M} when
            is_binary(Token)
        ->
            DeviceId =
                case M of
                    #{<<"device_id">> := D} when is_binary(D) -> D;
                    _ -> undefined
                end,
            {auth, Token, DeviceId};
        {ok, #{<<"type">> := <<"ping">>}} ->
            ping;
        {ok, #{<<"type">> := <<"activity">>}} ->
            activity;
        _ ->
            {error, invalid_frame}
    end.

%% ---- server -> client ----

event_frame(QueueId, Media, #{type := Type, at := At, data := Data}) ->
    cx_json:encode(#{
        <<"type">> => <<"event">>,
        <<"event">> => #{
            <<"type">> => atom_to_binary(Type),
            <<"at">> => At,
            <<"queue_id">> => cx_json:undef_to_null(QueueId),
            <<"media_type">> => cx_json:undef_to_null(Media),
            <<"data">> => Data
        }
    }).

ready_frame(UserId, TenantId, DeviceId) ->
    cx_json:encode(#{
        <<"type">> => <<"ready">>,
        <<"user_id">> => UserId,
        <<"tenant_id">> => TenantId,
        <<"device_id">> => cx_json:undef_to_null(DeviceId)
    }).

pong_frame() ->
    cx_json:encode(#{<<"type">> => <<"pong">>}).

error_frame(Code) ->
    cx_json:encode(#{<<"type">> => <<"error">>, <<"code">> => Code}).

%% ---- filter ----

%% Default deny: config CRUD noise and other tenants' operational
%% events never reach agent sockets.
-spec relevant(map(), binary()) -> boolean().
relevant(#{type := Type, data := Data}, UserId) ->
    lists:member(Type, ?TENANT_EVENTS) orelse
        (lists:member(Type, ?USER_EVENTS) andalso
            maps:get(<<"agent_id">>, Data, undefined) =:= UserId);
relevant(_, _) ->
    false.
