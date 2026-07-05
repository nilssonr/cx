-module(cx_h_socket).

%% The push transport: one cowboy_websocket process per connected agent
%% app. First-frame auth (browsers cannot set Authorization on a
%% WebSocket), then the socket becomes (a) the delivery channel for the
%% user's own router events + tenant presence events, and (b) a device
%% connection feeding the presence engine (connected/disconnected/
%% activity).
%%
%% Close codes: 4400 protocol violation, 4401 auth failed / token
%% expired / session revoked, 4403 no agent identity, 4408 auth
%% deadline, 4429 slow consumer.
%%
%% First-frame auth is not forever: a session_check timer closes the
%% socket when the token's exp passes and periodically re-resolves the
%% claims (cx_auth_claims:to_ctx), so disabling a user or changing
%% their roles takes effect on live sockets, not just new connections.

-behaviour(cowboy_websocket).

-include_lib("cx_core/include/cx_core.hrl").

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

%% server-side floor for activity reports; clients throttle to >= 30s
-define(ACTIVITY_MIN_MS, 5000).

-record(ws, {
    phase = unauth :: unauth | ready,
    ctx :: #auth_ctx{} | undefined,
    auth_tref :: reference() | undefined,
    %% token expiry (ms since epoch) and the session_check timer
    exp_ms = 0 :: integer(),
    session_tref :: reference() | undefined,
    device_id :: binary() | undefined,
    %% presence session pid + our monitor on it
    presence :: {pid(), reference()} | undefined,
    ua :: binary() | undefined,
    peer :: inet:ip_address() | undefined,
    last_activity = 0 :: integer(),
    max_queue :: pos_integer()
}).

init(Req, _Opts) ->
    %% headers die at the upgrade — capture what DeviceInfo wants here
    {Peer, _Port} = cowboy_req:peer(Req),
    State = #ws{
        ua = cowboy_req:header(<<"user-agent">>, Req),
        peer = Peer,
        max_queue = cx_cfg:get(cx_api_rest, ws_max_queue, 1000)
    },
    {cowboy_websocket, Req, State, #{
        idle_timeout => cx_cfg:get(cx_api_rest, ws_idle_timeout_ms, 60000),
        max_frame_size => 65536
    }}.

websocket_init(State) ->
    AuthTimeout = cx_cfg:get(cx_api_rest, ws_auth_timeout_ms, 10000),
    TRef = erlang:start_timer(AuthTimeout, self(), auth_deadline),
    {[], State#ws{auth_tref = TRef}}.

%% ---- frames ----

websocket_handle({text, Frame}, State = #ws{phase = unauth}) ->
    case cx_ws_proto:decode(Frame) of
        {auth, Token, DeviceId} ->
            authenticate(Token, DeviceId, State);
        _ ->
            {[{close, 4400, <<"expected_auth">>}], State}
    end;
websocket_handle({text, Frame}, State = #ws{phase = ready}) ->
    case cx_ws_proto:decode(Frame) of
        ping ->
            %% the one frame guaranteed to recur on quiet connections —
            %% hibernate here to cap idle heap
            {[{text, cx_ws_proto:pong_frame()}], State, hibernate};
        activity ->
            {[], report_activity(State)};
        {auth, _, _} ->
            {[{text, cx_ws_proto:error_frame(<<"already_authenticated">>)}], State};
        {error, invalid_frame} ->
            {[{text, cx_ws_proto:error_frame(<<"invalid_frame">>)}], State}
    end;
websocket_handle(_Other, State) ->
    %% binary frames (or anything else) are protocol violations pre- and
    %% post-auth alike; cowboy answers protocol pings itself
    {[{close, 4400, <<"unsupported_frame">>}], State}.

%% ---- infos ----

websocket_info({timeout, TRef, auth_deadline}, State = #ws{phase = unauth, auth_tref = TRef}) ->
    {[{close, 4408, <<"auth_timeout">>}], State};
websocket_info({timeout, _TRef, auth_deadline}, State) ->
    %% stale deadline that lost the cancel race after auth — ignore
    {[], State};
websocket_info({timeout, _TRef, presence_retry}, State = #ws{phase = ready}) ->
    {[], register_presence(State)};
websocket_info(
    {timeout, TRef, session_check},
    State = #ws{phase = ready, session_tref = TRef, exp_ms = ExpMs, ctx = Ctx}
) ->
    %% no extra leeway: verify-time leeway already covered issuer clock
    %% skew, and stretching past exp only prolongs revoked credentials
    case cx_time:now_ms() >= ExpMs of
        true ->
            {[{close, 4401, <<"token_expired">>}], State};
        false ->
            %% re-resolve the claims: user disabled/deleted closes the
            %% socket; role/permission changes refresh the live ctx
            case cx_auth_claims:to_ctx(Ctx#auth_ctx.claims) of
                {ok, Ctx1} ->
                    State1 = State#ws{
                        ctx = Ctx1,
                        session_tref = schedule_session_check(ExpMs)
                    },
                    {[], State1};
                {error, unauthorized} ->
                    {[{close, 4401, <<"session_revoked">>}], State}
            end
    end;
websocket_info({timeout, _TRef, session_check}, State) ->
    %% stale timer from a superseded schedule — ignore
    {[], State};
websocket_info({cx_event, {_T, QueueId, Media, Event}}, State = #ws{phase = ready}) ->
    case queue_overflow(State) of
        true ->
            %% drop-and-close: silent per-event drops would create
            %% undetectable divergence; the client reconnects + resyncs
            {[{close, 4429, <<"slow_consumer">>}], State};
        false ->
            UserId = (State#ws.ctx)#auth_ctx.user_id,
            case cx_ws_proto:relevant(Event, UserId) of
                true ->
                    {[{text, cx_ws_proto:event_frame(QueueId, Media, Event)}], State};
                false ->
                    {[], State}
            end
    end;
websocket_info({'DOWN', Ref, process, _Pid, _Reason}, State = #ws{presence = {_, Ref}}) ->
    %% presence session died: re-register after a beat (it is rebuilt
    %% from live connections — us — by design)
    _ = erlang:start_timer(1000, self(), presence_retry),
    {[], State#ws{presence = undefined}};
websocket_info(_Info, State) ->
    {[], State}.

terminate(_Reason, _PartialReq, #ws{phase = ready, ctx = Ctx}) ->
    %% fast path only — the presence session's monitor on this process
    %% is the authoritative disconnect signal (terminate isn't
    %% guaranteed on brutal kills)
    try
        cx_presence:disconnected(Ctx, self())
    catch
        _:_ -> ok
    end,
    ok;
terminate(_Reason, _PartialReq, _State) ->
    ok.

%% ---- internals ----

authenticate(Token, DeviceId, State) ->
    case cx_auth:authenticate(Token) of
        {error, unauthorized} ->
            {[{close, 4401, <<"unauthorized">>}], State};
        {ok, #auth_ctx{user_id = undefined}} ->
            %% valid token without an agent identity (integrator
            %% credentials) — nothing to deliver, nothing to register
            {[{close, 4403, <<"no_agent_identity">>}], State};
        {ok, Ctx = #auth_ctx{tenant_id = T, user_id = UserId, claims = Claims}} ->
            cancel_auth_timer(State#ws.auth_tref),
            %% exp is required by cx_auth_jwt:validate_claims; if it is
            %% somehow absent, fail closed as already-expired
            ExpMs =
                case maps:get(<<"exp">>, Claims, undefined) of
                    E when is_integer(E) -> E * 1000;
                    _ -> 0
                end,
            %% subscribe BEFORE ready so no event can fall in the gap;
            %% the client resyncs current state via REST on connect
            ok = cx_event:subscribe(T),
            State1 = register_presence(State#ws{
                phase = ready,
                ctx = Ctx,
                auth_tref = undefined,
                device_id = DeviceId,
                last_activity = cx_time:now_ms(),
                exp_ms = ExpMs,
                session_tref = schedule_session_check(ExpMs)
            }),
            Ready = cx_ws_proto:ready_frame(UserId, T, DeviceId),
            {[{text, Ready}], State1}
    end.

cancel_auth_timer(undefined) ->
    ok;
cancel_auth_timer(TRef) ->
    _ = erlang:cancel_timer(TRef),
    ok.

%% Next re-validation: every ws_session_check_ms, but never past exp —
%% expiry closes the socket at exp, not up to an interval late.
schedule_session_check(ExpMs) ->
    Interval = cx_cfg:get(cx_api_rest, ws_session_check_ms, 60000),
    Delay = max(0, min(Interval, ExpMs - cx_time:now_ms())),
    erlang:start_timer(Delay, self(), session_check).

register_presence(State = #ws{ctx = Ctx}) ->
    DeviceInfo = #{
        device_id => State#ws.device_id,
        user_agent => State#ws.ua,
        ip => State#ws.peer
    },
    case cx_presence:connected(Ctx, self(), DeviceInfo) of
        {ok, SessPid} ->
            State#ws{presence = {SessPid, erlang:monitor(process, SessPid)}};
        {error, _} ->
            %% presence must never take the event channel down — retry
            _ = erlang:start_timer(1000, self(), presence_retry),
            State#ws{presence = undefined}
    end.

report_activity(State = #ws{last_activity = Last}) ->
    Now = cx_time:now_ms(),
    case Now - Last >= ?ACTIVITY_MIN_MS of
        true ->
            ok = cx_presence:activity(State#ws.ctx),
            State#ws{last_activity = Now};
        false ->
            State
    end.

queue_overflow(#ws{max_queue = Max}) ->
    case process_info(self(), message_queue_len) of
        {message_queue_len, Len} -> Len > Max;
        undefined -> false
    end.
