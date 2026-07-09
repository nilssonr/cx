-module(cx_handler_socket).

%% The push transport: one cowboy_websocket process per connected agent
%% app. First-frame auth (browsers cannot set Authorization on a
%% WebSocket), then the socket becomes (a) the delivery channel for the
%% user's own router events + tenant presence events, and (b) a device
%% connection feeding the presence engine (connected/disconnected/
%% activity).
%%
%% Close codes: 4400 protocol violation, 4401 auth failed / token
%% expired / session revoked, 4403 no agent identity / agent
%% deactivated, 4408 auth deadline, 4429 slow consumer, 4503 presence
%% unavailable (transient registration retries exhausted).
%%
%% First-frame auth is not forever: a session_check timer closes the
%% socket when the token's exp passes and periodically re-resolves the
%% claims (cx_auth_claims:to_context), so disabling a user or changing
%% their roles takes effect on live sockets, not just new connections.

-behaviour(cowboy_websocket).

-include_lib("cx_core/include/cx_core.hrl").

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

%% server-side floor for activity reports; clients throttle to >= 30s
-define(ACTIVITY_MIN_MS, 5000).
%% transient presence-registration retries before giving up (4503)
-define(PRESENCE_MAX_RETRIES, 5).

-record(socket, {
    phase = unauth :: unauth | ready,
    auth_context :: #auth_context{} | undefined,
    auth_timer_ref :: reference() | undefined,
    %% token expiry (ms since epoch) and the session_check timer
    expiry_ms = 0 :: integer(),
    session_timer_ref :: reference() | undefined,
    device_id :: binary() | undefined,
    %% presence session pid + our monitor on it
    presence :: {pid(), reference()} | undefined,
    %% consecutive failed registration attempts (reset on success)
    presence_retries = 0 :: non_neg_integer(),
    user_agent :: binary() | undefined,
    peer :: inet:ip_address() | undefined,
    last_activity = 0 :: integer(),
    max_queue :: pos_integer()
}).

init(Req, _Opts) ->
    %% headers die at the upgrade — capture what DeviceInfo wants here
    {Peer, _Port} = cowboy_req:peer(Req),
    State = #socket{
        user_agent = cowboy_req:header(<<"user-agent">>, Req),
        peer = Peer,
        max_queue = cx_config:get(cx_api_rest, ws_max_queue, 1000)
    },
    {cowboy_websocket, Req, State, #{
        idle_timeout => cx_config:get(cx_api_rest, ws_idle_timeout_ms, 60000),
        max_frame_size => 65536
    }}.

websocket_init(State) ->
    AuthTimeout = cx_config:get(cx_api_rest, ws_auth_timeout_ms, 10000),
    TimerRef = erlang:start_timer(AuthTimeout, self(), auth_deadline),
    {[], State#socket{auth_timer_ref = TimerRef}}.

%% ---- frames ----

websocket_handle({text, Frame}, State = #socket{phase = unauth}) ->
    case cx_ws_protocol:decode(Frame) of
        {auth, Token, DeviceId} ->
            authenticate(Token, DeviceId, State);
        _ ->
            {[{close, 4400, <<"expected_auth">>}], State}
    end;
websocket_handle({text, Frame}, State = #socket{phase = ready}) ->
    case cx_ws_protocol:decode(Frame) of
        ping ->
            %% the one frame guaranteed to recur on quiet connections —
            %% hibernate here to cap idle heap
            {[{text, cx_ws_protocol:pong_frame()}], State, hibernate};
        activity ->
            {[], report_activity(State)};
        {reauth, Token} ->
            reauth(Token, State);
        {auth, _, _} ->
            {[{text, cx_ws_protocol:error_frame(<<"already_authenticated">>)}], State};
        {error, invalid_frame} ->
            {[{text, cx_ws_protocol:error_frame(<<"invalid_frame">>)}], State}
    end;
websocket_handle(_Other, State) ->
    %% binary frames (or anything else) are protocol violations pre- and
    %% post-auth alike; cowboy answers protocol pings itself
    {[{close, 4400, <<"unsupported_frame">>}], State}.

%% ---- infos ----

websocket_info(
    {timeout, TimerRef, auth_deadline}, State = #socket{phase = unauth, auth_timer_ref = TimerRef}
) ->
    {[{close, 4408, <<"auth_timeout">>}], State};
websocket_info({timeout, _TRef, auth_deadline}, State) ->
    %% stale deadline that lost the cancel race after auth — ignore
    {[], State};
websocket_info({timeout, _TRef, presence_retry}, State = #socket{phase = ready}) ->
    register_presence(State);
websocket_info(
    {timeout, TimerRef, session_check},
    State = #socket{
        phase = ready, session_timer_ref = TimerRef, expiry_ms = ExpiryMs, auth_context = Context
    }
) ->
    %% no extra leeway: verify-time leeway already covered issuer clock
    %% skew, and stretching past exp only prolongs revoked credentials
    case cx_time:now_ms() >= ExpiryMs of
        true ->
            {[{close, 4401, <<"token_expired">>}], State};
        false ->
            %% re-resolve the claims: user disabled/deleted closes the
            %% socket; role/permission changes refresh the live auth_context
            case cx_auth_claims:to_context(Context#auth_context.claims) of
                {ok, Context1} ->
                    State1 = State#socket{
                        auth_context = Context1,
                        session_timer_ref = schedule_session_check(ExpiryMs)
                    },
                    {[], State1};
                {error, unauthorized} ->
                    {[{close, 4401, <<"session_revoked">>}], State}
            end
    end;
websocket_info({timeout, _TRef, session_check}, State) ->
    %% stale timer from a superseded schedule — ignore
    {[], State};
websocket_info({cx_event, {_T, QueueId, Media, Event}}, State = #socket{phase = ready}) ->
    case queue_overflow(State) of
        true ->
            %% drop-and-close: silent per-event drops would create
            %% undetectable divergence; the client reconnects + resyncs
            {[{close, 4429, <<"slow_consumer">>}], State};
        false ->
            UserId = (State#socket.auth_context)#auth_context.user_id,
            case cx_ws_protocol:relevant(Event, UserId) of
                true ->
                    {[{text, cx_ws_protocol:event_frame(QueueId, Media, Event)}], State};
                false ->
                    {[], State}
            end
    end;
websocket_info({'DOWN', Ref, process, _Pid, _Reason}, State = #socket{presence = {_, Ref}}) ->
    %% presence session died: re-register after a beat (it is rebuilt
    %% from live connections — us — by design); the retry budget was
    %% reset when this registration succeeded
    _ = schedule_presence_retry(),
    {[], State#socket{presence = undefined}};
websocket_info(_Info, State) ->
    {[], State}.

terminate(_Reason, _PartialReq, #socket{phase = ready, auth_context = Context}) ->
    %% fast path only — the presence session's monitor on this process
    %% is the authoritative disconnect signal (terminate isn't
    %% guaranteed on brutal kills)
    try
        cx_presence:disconnected(Context, self())
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
        {ok, #auth_context{user_id = undefined}} ->
            %% valid token without an agent identity (integrator
            %% credentials) — nothing to deliver, nothing to register
            {[{close, 4403, <<"no_agent_identity">>}], State};
        {ok, Context = #auth_context{tenant_id = T, user_id = UserId}} ->
            cancel_auth_timer(State#socket.auth_timer_ref),
            ExpiryMs = expiry_ms(Context),
            %% subscribe BEFORE ready so no event can fall in the gap;
            %% the client resyncs current state via REST on connect
            ok = cx_event:subscribe(T),
            {Commands, State1} = register_presence(State#socket{
                phase = ready,
                auth_context = Context,
                auth_timer_ref = undefined,
                device_id = DeviceId,
                last_activity = cx_time:now_ms(),
                expiry_ms = ExpiryMs,
                session_timer_ref = schedule_session_check(ExpiryMs)
            }),
            Ready = cx_ws_protocol:ready_frame(UserId, T, DeviceId),
            %% ready first; a close command (if any) follows it in order
            {[{text, Ready} | Commands], State1}
    end.

%% In-band token refresh on a live socket: re-verify and reset the expiry
%% deadline so a socket outlives its ~10-min access token without dropping.
%% The new token must carry the SAME subject — a swap to a different identity
%% on an established connection is rejected. Presence + event subscription are
%% first-connect concerns and stay untouched; the superseded session_check
%% timer is left to the stale-timer clause, exactly as a normal reschedule.
reauth(Token, State = #socket{auth_context = #auth_context{subject = Subject}}) ->
    case cx_auth:authenticate(Token) of
        {ok, Context = #auth_context{subject = Subject}} ->
            ExpiryMs = expiry_ms(Context),
            State1 = State#socket{
                auth_context = Context,
                expiry_ms = ExpiryMs,
                session_timer_ref = schedule_session_check(ExpiryMs)
            },
            {[{text, cx_ws_protocol:reauth_ok_frame()}], State1};
        {ok, _Other} ->
            {[{close, 4401, <<"subject_mismatch">>}], State};
        {error, unauthorized} ->
            {[{close, 4401, <<"unauthorized">>}], State}
    end.

%% Token expiry as ms since epoch. exp is required by cx_auth_jwt:validate_claims;
%% if it is somehow absent, fail closed as already-expired.
expiry_ms(#auth_context{claims = Claims}) ->
    case maps:get(<<"exp">>, Claims, undefined) of
        E when is_integer(E) -> E * 1000;
        _ -> 0
    end.

cancel_auth_timer(undefined) ->
    ok;
cancel_auth_timer(TimerRef) ->
    _ = erlang:cancel_timer(TimerRef),
    ok.

%% Next re-validation: every ws_session_check_ms, but never past exp —
%% expiry closes the socket at exp, not up to an interval late.
schedule_session_check(ExpiryMs) ->
    Interval = cx_config:get(cx_api_rest, ws_session_check_ms, 60000),
    Delay = max(0, min(Interval, ExpiryMs - cx_time:now_ms())),
    erlang:start_timer(Delay, self(), session_check).

register_presence(State = #socket{auth_context = Context, presence_retries = N}) ->
    DeviceInfo = #{
        device_id => State#socket.device_id,
        user_agent => State#socket.user_agent,
        ip => State#socket.peer
    },
    case cx_presence:connected(Context, self(), DeviceInfo) of
        {ok, SessionPid} ->
            State1 = State#socket{
                presence = {SessionPid, erlang:monitor(process, SessionPid)},
                presence_retries = 0
            },
            {[], State1};
        {error, Reason} when Reason =:= forbidden; Reason =:= no_user ->
            %% permanent: the user lost their agent identity (e.g.
            %% deactivated mid-connection) — retrying can never succeed
            {[{close, 4403, <<"forbidden">>}], State};
        {error, _Transient} when N < ?PRESENCE_MAX_RETRIES ->
            %% a lost session race — retry, but bounded
            _ = schedule_presence_retry(),
            {[], State#socket{presence = undefined, presence_retries = N + 1}};
        {error, _} ->
            {[{close, 4503, <<"presence_unavailable">>}], State}
    end.

schedule_presence_retry() ->
    RetryMs = cx_config:get(cx_api_rest, ws_presence_retry_ms, 1000),
    erlang:start_timer(RetryMs, self(), presence_retry).

report_activity(State = #socket{last_activity = Last}) ->
    Now = cx_time:now_ms(),
    case Now - Last >= ?ACTIVITY_MIN_MS of
        true ->
            ok = cx_presence:activity(State#socket.auth_context),
            State#socket{last_activity = Now};
        false ->
            State
    end.

queue_overflow(#socket{max_queue = Max}) ->
    case process_info(self(), message_queue_len) of
        {message_queue_len, Len} -> Len > Max;
        undefined -> false
    end.
