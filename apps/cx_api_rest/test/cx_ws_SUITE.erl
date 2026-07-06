-module(cx_ws_SUITE).

%% End-to-end WebSocket tests with a real RFC-6455 client (gun).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("cx_core/include/cx_core.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    auth_timeout_closes/1,
    bad_token_closes/1,
    bad_first_frame_closes/1,
    happy_auth_ready_ping/1,
    offer_event_targeted/1,
    presence_fanout_and_disconnect/1,
    expired_token_closes_socket/1,
    disabled_user_closes_socket/1,
    deactivated_user_presence_close/1
]).

all() ->
    [
        auth_timeout_closes,
        bad_token_closes,
        bad_first_frame_closes,
        happy_auth_ready_ping,
        offer_event_targeted,
        presence_fanout_and_disconnect,
        expired_token_closes_socket,
        disabled_user_closes_socket,
        deactivated_user_presence_close
    ].

init_per_suite(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    ok = application:set_env(
        cx_core,
        mnesia_dir,
        filename:join(PrivDir, "mnesia"),
        [{persistent, true}]
    ),
    ok = application:set_env(cx_api_rest, port, 0, [{persistent, true}]),
    Keypair = cx_auth_test:new_keypair(),
    ok = cx_auth_test:install(Keypair, #{}),
    {ok, _} = application:ensure_all_started(cx_api_rest),
    {ok, _} = application:ensure_all_started(gun),
    Port = ranch:get_port(cx_http),
    [{keypair, Keypair}, {port, Port} | Config].

end_per_suite(_Config) ->
    application:stop(cx_api_rest),
    application:stop(cx_presence),
    application:stop(cx_router),
    application:stop(cx_auth),
    application:stop(cx_core),
    application:stop(mnesia),
    ok.

%% ---- cases ----

auth_timeout_closes(Config) ->
    ok = application:set_env(cx_api_rest, ws_auth_timeout_ms, 200),
    {Conn, Stream} = ws_open(Config),
    ?assertMatch({close, 4408, _}, ws_recv_close(Conn, Stream, 2000)),
    gun:close(Conn),
    ok = application:set_env(cx_api_rest, ws_auth_timeout_ms, 10000).

bad_token_closes(Config) ->
    {Conn, Stream} = ws_open(Config),
    ws_send(Conn, Stream, #{<<"type">> => <<"auth">>, <<"token">> => <<"garbage">>}),
    ?assertMatch({close, 4401, _}, ws_recv_close(Conn, Stream, 2000)),
    gun:close(Conn).

bad_first_frame_closes(Config) ->
    {Conn, Stream} = ws_open(Config),
    ws_send(Conn, Stream, #{<<"type">> => <<"ping">>}),
    ?assertMatch({close, 4400, _}, ws_recv_close(Conn, Stream, 2000)),
    gun:close(Conn).

happy_auth_ready_ping(Config) ->
    {T, UserId} = provision_user(<<"Happy">>),
    {Conn, Stream} = ws_auth(Config, T, UserId),
    ws_send(Conn, Stream, #{<<"type">> => <<"ping">>}),
    %% our own presence_changed(online) may interleave before the pong
    #{<<"type">> := <<"pong">>} = ws_recv_type(Conn, Stream, <<"pong">>, 2000),
    gun:close(Conn).

offer_event_targeted(Config) ->
    T = cx_id:new(),
    Admin = cx_authz:ctx(T, [<<"*">>]),
    {ok, #{<<"id">> := QueueId}} =
        cx_queue:create(Admin, #{<<"name">> => <<"q">>, <<"wrapup_duration_ms">> => 0}),
    UserA = create_user(Admin, <<"A">>),
    UserB = create_user(Admin, <<"B">>),

    {ConnA, StreamA} = ws_auth(Config, T, UserA),
    {ConnB, StreamB} = ws_auth(Config, T, UserB),

    %% only A signs in as an agent and goes ready
    AgentA = agent_ctx(T, UserA),
    {ok, _} = cx_router:start_session(AgentA),
    ok = cx_router:set_ready(AgentA, <<"open_media">>, ready),

    Integrator = cx_authz:ctx(T, [<<"interactions:create">>]),
    {ok, #{<<"id">> := InteractionId}} =
        cx_router:create_interaction(Integrator, #{
            <<"queue_id">> => QueueId, <<"media_type">> => <<"open_media">>
        }),

    %% A's socket sees the offer for A's interaction
    #{
        <<"type">> := <<"offer_created">>,
        <<"data">> := #{<<"interaction_id">> := InteractionId, <<"agent_id">> := UserA}
    } = ws_wait_event(ConnA, StreamA, <<"offer_created">>, 3000),

    %% B saw no offer: a marker event published after proves ordering
    cx_event:publish(T, undefined, undefined, presence_changed, #{
        <<"user_id">> => <<"marker">>, <<"state">> => <<"online">>
    }),
    %% B's own online event precedes the marker; wait for the marker
    %% specifically — every presence event before it proves no offer
    %% frame reached B in between
    ok = ws_wait_marker(ConnB, StreamB, <<"marker">>, 3000),
    gun:close(ConnA),
    gun:close(ConnB).

presence_fanout_and_disconnect(Config) ->
    T = cx_id:new(),
    Admin = cx_authz:ctx(T, [<<"*">>]),
    UserA = create_user(Admin, <<"A">>),
    UserB = create_user(Admin, <<"B">>),

    {ConnB, StreamB} = ws_auth(Config, T, UserB),
    %% B's own online event arrives first on its socket
    #{<<"data">> := #{<<"user_id">> := UserB, <<"state">> := <<"online">>}} =
        ws_wait_event(ConnB, StreamB, <<"presence_changed">>, 3000),

    {ConnA, StreamA} = ws_auth(Config, T, UserA),
    %% ...then A connecting fans out to B
    #{<<"data">> := #{<<"user_id">> := UserA, <<"state">> := <<"online">>}} =
        ws_wait_event(ConnB, StreamB, <<"presence_changed">>, 3000),
    _ = StreamA,

    %% closing A's socket takes A offline for B (monitor path)
    gun:close(ConnA),
    #{<<"data">> := #{<<"user_id">> := UserA, <<"state">> := <<"offline">>}} =
        ws_wait_event(ConnB, StreamB, <<"presence_changed">>, 3000),
    gun:close(ConnB).

%% A socket authenticated with a soon-expiring token closes at exp with
%% 4401, even though the client keeps it alive.
expired_token_closes_socket(Config) ->
    ok = application:set_env(cx_api_rest, ws_session_check_ms, 200),
    try
        {T, UserId} = provision_user(<<"Expiring">>),
        {Conn, Stream} = ws_open(Config),
        Keypair = proplists:get_value(keypair, Config),
        {ok, #cx_user{subject = Sub}} = cx_user:fetch(T, UserId),
        Token = cx_auth_test:token(Keypair, #{
            <<"sub">> => Sub,
            <<"urn:zitadel:iam:org:id">> => T,
            <<"exp">> => erlang:system_time(second) + 1
        }),
        ws_send(Conn, Stream, #{<<"type">> => <<"auth">>, <<"token">> => Token}),
        #{<<"type">> := <<"ready">>} = ws_recv_json(Conn, Stream, 3000),
        ?assertMatch(
            {close, 4401, <<"token_expired">>},
            ws_recv_close(Conn, Stream, 5000)
        ),
        gun:close(Conn)
    after
        ok = application:set_env(cx_api_rest, ws_session_check_ms, 60000)
    end.

%% Disabling a user mid-connection revokes the live socket at the next
%% session check.
disabled_user_closes_socket(Config) ->
    ok = application:set_env(cx_api_rest, ws_session_check_ms, 200),
    try
        T = cx_id:new(),
        Admin = cx_authz:ctx(T, [<<"*">>]),
        UserId = create_user(Admin, <<"Doomed">>),
        {Conn, Stream} = ws_auth(Config, T, UserId),
        {ok, _} = cx_user:update(Admin, UserId, #{<<"status">> => <<"disabled">>}),
        ?assertMatch(
            {close, 4401, <<"session_revoked">>},
            ws_recv_close(Conn, Stream, 5000)
        ),
        gun:close(Conn)
    after
        ok = application:set_env(cx_api_rest, ws_session_check_ms, 60000)
    end.

%% A deactivated user's socket must not retry presence registration
%% forever: re-registration after the session dies hits the permanent
%% forbidden and closes 4403 (instead of a 1 Hz retry loop).
deactivated_user_presence_close(Config) ->
    ok = application:set_env(cx_api_rest, ws_presence_retry_ms, 50),
    try
        T = cx_id:new(),
        Admin = cx_authz:ctx(T, [<<"*">>]),
        UserId = create_user(Admin, <<"Gone">>),
        {Conn, Stream} = ws_auth(Config, T, UserId),
        %% registration done: own online event proves the session exists
        #{<<"data">> := #{<<"user_id">> := UserId, <<"state">> := <<"online">>}} =
            ws_wait_event(Conn, Stream, <<"presence_changed">>, 3000),
        {ok, _} = cx_user:update(Admin, UserId, #{<<"status">> => <<"disabled">>}),
        %% kill the presence session: the socket's DOWN triggers a
        %% re-registration, which now hits {error, forbidden}
        SessPid =
            case cx_registry:whereis_name({presence, T, UserId}) of
                P when is_pid(P) -> P
            end,
        exit(SessPid, kill),
        ?assertMatch({close, 4403, _}, ws_recv_close(Conn, Stream, 3000)),
        gun:close(Conn)
    after
        ok = application:set_env(cx_api_rest, ws_presence_retry_ms, 1000)
    end.

%% ---- helpers ----

provision_user(Name) ->
    T = cx_id:new(),
    Admin = cx_authz:ctx(T, [<<"*">>]),
    {T, create_user(Admin, Name)}.

create_user(Admin, Name) ->
    Sub = <<"sub-", Name/binary>>,
    {ok, #{<<"id">> := RoleId}} =
        cx_role:create(Admin, #{
            <<"name">> => <<"role-", Name/binary>>,
            <<"permissions">> => [
                <<"agent:session:self">>,
                <<"agent:ready:self">>,
                <<"agent:offers:self">>,
                <<"presence:set:self">>
            ]
        }),
    {ok, #{<<"id">> := Id}} =
        cx_user:create(Admin, #{
            <<"name">> => Name,
            <<"email">> => <<Name/binary, "@x">>,
            <<"subject">> => Sub,
            <<"role_ids">> => [RoleId]
        }),
    Id.

agent_ctx(T, UserId) ->
    cx_authz:ctx(T, UserId, <<"s">>, [
        <<"agent:session:self">>, <<"agent:ready:self">>, <<"agent:offers:self">>
    ]).

token_for(Config, T, UserId) ->
    Keypair = proplists:get_value(keypair, Config),
    {ok, #cx_user{subject = Sub}} = cx_user:fetch(T, UserId),
    cx_auth_test:token(Keypair, #{
        <<"sub">> => Sub, <<"urn:zitadel:iam:org:id">> => T
    }).

ws_open(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, Conn} = gun:open("127.0.0.1", Port, #{
        transport => tcp, protocols => [http]
    }),
    {ok, _} = gun:await_up(Conn, 5000),
    Stream = gun:ws_upgrade(Conn, "/api/v1/socket", []),
    receive
        {gun_upgrade, Conn, Stream, [<<"websocket">>], _} ->
            {Conn, Stream};
        {gun_response, Conn, Stream, _, Status, Headers} ->
            error({ws_upgrade_rejected, Status, Headers});
        {gun_error, Conn, Stream, Reason} ->
            error({ws_upgrade_error, Reason})
    after 5000 -> error(ws_upgrade_timeout)
    end.

ws_auth(Config, T, UserId) ->
    {Conn, Stream} = ws_open(Config),
    ws_send(Conn, Stream, #{
        <<"type">> => <<"auth">>, <<"token">> => token_for(Config, T, UserId)
    }),
    #{<<"type">> := <<"ready">>, <<"user_id">> := UserId} =
        ws_recv_json(Conn, Stream, 3000),
    {Conn, Stream}.

ws_send(Conn, Stream, Map) ->
    gun:ws_send(Conn, Stream, {text, cx_json:encode(Map)}).

ws_recv_json(Conn, Stream, Timeout) ->
    receive
        {gun_ws, Conn, Stream, {text, Frame}} ->
            {ok, Decoded} = cx_json:decode(Frame),
            Decoded
    after Timeout -> error(ws_recv_timeout)
    end.

%% Receive until a frame of the given top-level type arrives, skipping
%% interleaved event frames.
ws_recv_type(Conn, Stream, Type, Timeout) ->
    case ws_recv_json(Conn, Stream, Timeout) of
        Decoded = #{<<"type">> := Type} -> Decoded;
        _ -> ws_recv_type(Conn, Stream, Type, Timeout)
    end.

%% Consume presence events until the marker user shows up; anything that
%% is NOT a presence event on the way is a filtering failure.
ws_wait_marker(Conn, Stream, Marker, Timeout) ->
    case ws_wait_event(Conn, Stream, <<"presence_changed">>, Timeout) of
        #{<<"data">> := #{<<"user_id">> := Marker}} -> ok;
        _ -> ws_wait_marker(Conn, Stream, Marker, Timeout)
    end.

ws_recv_close(Conn, Stream, Timeout) ->
    receive
        {gun_ws, Conn, Stream, {close, Code, Reason}} -> {close, Code, Reason};
        {gun_ws, Conn, Stream, {text, _}} -> ws_recv_close(Conn, Stream, Timeout)
    after Timeout -> error(ws_close_timeout)
    end.

%% Wait for a specific event type, skipping every other frame (other
%% users' presence noise etc.).
ws_wait_event(Conn, Stream, Type, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    ws_wait_event_loop(Conn, Stream, Type, Deadline).

ws_wait_event_loop(Conn, Stream, Type, Deadline) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    case Left > 0 of
        false ->
            error({ws_event_timeout, Type});
        true ->
            receive
                {gun_ws, Conn, Stream, {text, Frame}} ->
                    case cx_json:decode(Frame) of
                        {ok, #{<<"type">> := <<"event">>, <<"event">> := E = #{<<"type">> := Type}}} ->
                            E;
                        _ ->
                            ws_wait_event_loop(Conn, Stream, Type, Deadline)
                    end
            after Left -> error({ws_event_timeout, Type})
            end
    end.
