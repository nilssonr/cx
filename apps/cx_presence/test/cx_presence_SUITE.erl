-module(cx_presence_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("cx_core/include/cx_core.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    declared_persists_restart/1,
    connect_publishes_online/1,
    disconnect_publishes_offline_and_stops/1,
    away_timer_flow/1,
    until_expiry_with_session/1,
    until_expiry_lazy_offline/1,
    multi_device/1,
    session_crash_reregister/1,
    set_while_connected/1,
    validation_and_permissions/1,
    directory_mixed/1
]).

-define(AWAY_MS, 300).

all() ->
    [
        declared_persists_restart,
        connect_publishes_online,
        disconnect_publishes_offline_and_stops,
        away_timer_flow,
        until_expiry_with_session,
        until_expiry_lazy_offline,
        multi_device,
        session_crash_reregister,
        set_while_connected,
        validation_and_permissions,
        directory_mixed
    ].

init_per_suite(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    ok = application:set_env(
        cx_core,
        mnesia_dir,
        filename:join(PrivDir, "mnesia"),
        [{persistent, true}]
    ),
    ok = application:set_env(cx_auth, key_source, {static, []}, [{persistent, true}]),
    ok = application:set_env(cx_presence, away_threshold_ms, ?AWAY_MS, [
        {persistent, true}
    ]),
    {ok, _} = application:ensure_all_started(cx_presence),
    Config.

end_per_suite(_Config) ->
    application:stop(cx_presence),
    application:stop(cx_auth),
    application:stop(cx_core),
    application:stop(mnesia),
    ok.

%% ---- cases ----

declared_persists_restart(_Config) ->
    {T, UserId} = mk_user(),
    Ctx = user_ctx(T, UserId),
    {ok, #{<<"manual_state">> := <<"busy">>, <<"message">> := <<"In Spain">>}} =
        cx_presence:set_own(Ctx, #{
            <<"state">> => <<"busy">>, <<"message">> => <<"In Spain">>
        }),
    ok = application:stop(cx_presence),
    ok = application:stop(cx_core),
    application:stop(mnesia),
    {ok, _} = application:ensure_all_started(cx_presence),
    {ok, #{
        <<"state">> := <<"offline">>,
        <<"manual_state">> := <<"busy">>,
        <<"message">> := <<"In Spain">>
    }} = cx_presence:get_own(Ctx),
    ok.

connect_publishes_online(_Config) ->
    {T, UserId} = mk_user(),
    Ctx = user_ctx(T, UserId),
    ok = cx_event:subscribe(T),
    Conn = spawn_conn(),
    {ok, _Pid} = cx_presence:connected(Ctx, Conn, #{}),
    {ok, #{<<"user_id">> := UserId, <<"state">> := <<"online">>}} =
        wait_presence(),
    {ok, #{<<"state">> := <<"online">>, <<"device_count">> := 1}} =
        cx_presence:get_own(Ctx),
    stop_conn(Conn),
    ok.

disconnect_publishes_offline_and_stops(_Config) ->
    {T, UserId} = mk_user(),
    Ctx = user_ctx(T, UserId),
    ok = cx_event:subscribe(T),
    Conn = spawn_conn(),
    {ok, _} = cx_presence:connected(Ctx, Conn, #{}),
    {ok, _} = wait_presence(),
    ok = cx_presence:disconnected(Ctx, Conn),
    {ok, #{<<"user_id">> := UserId, <<"state">> := <<"offline">>}} =
        wait_presence(),
    ok = wait_until(fun() ->
        cx_reg:whereis_name({presence, T, UserId}) =:= undefined
    end),
    ?assertEqual([], mnesia:dirty_read(cx_presence_eff, {T, UserId})),
    stop_conn(Conn),
    ok.

away_timer_flow(_Config) ->
    {T, UserId} = mk_user(),
    Ctx = user_ctx(T, UserId),
    ok = cx_event:subscribe(T),
    Conn = spawn_conn(),
    {ok, _} = cx_presence:connected(Ctx, Conn, #{}),
    {ok, #{<<"state">> := <<"online">>}} = wait_presence(),
    %% no activity: the away timer fires after the (short) threshold
    {ok, #{<<"user_id">> := UserId, <<"state">> := <<"away">>}} =
        wait_presence(2000),
    ok = cx_presence:activity(Ctx),
    {ok, #{<<"state">> := <<"online">>}} = wait_presence(),
    stop_conn(Conn),
    ok.

until_expiry_with_session(_Config) ->
    {T, UserId} = mk_user(),
    Ctx = user_ctx(T, UserId),
    ok = cx_event:subscribe(T),
    Conn = spawn_conn(),
    {ok, _} = cx_presence:connected(Ctx, Conn, #{}),
    {ok, #{<<"state">> := <<"online">>}} = wait_presence(),
    {ok, _} = cx_presence:set_own(Ctx, #{
        <<"state">> => <<"dnd">>, <<"until">> => cx_time:now_ms() + 400
    }),
    {ok, #{<<"state">> := <<"dnd">>}} = wait_presence(),
    %% expiry returns to the automatic state without any further call
    {ok, #{<<"user_id">> := UserId, <<"state">> := State}} = wait_presence(2000),
    ?assert(lists:member(State, [<<"online">>, <<"away">>])),
    stop_conn(Conn),
    ok.

until_expiry_lazy_offline(_Config) ->
    {T, UserId} = mk_user(),
    Ctx = user_ctx(T, UserId),
    ok = cx_event:subscribe(T),
    {ok, _} = cx_presence:set_own(Ctx, #{
        <<"state">> => <<"out_of_office">>,
        <<"message">> => <<"In Spain">>,
        <<"until">> => cx_time:now_ms() + 300
    }),
    %% the set itself publishes (facade path, no session)
    {ok, #{<<"user_id">> := UserId, <<"state">> := <<"offline">>}} =
        wait_presence(),
    timer:sleep(400),
    %% lazily expired at read time: message gone, still offline
    {ok, #{<<"state">> := <<"offline">>, <<"message">> := null, <<"until">> := null}} =
        cx_presence:get_own(Ctx),
    %% and no presence_changed fired at the expiry moment
    ?assertEqual(timeout, wait_presence(300)),
    ok.

multi_device(_Config) ->
    {T, UserId} = mk_user(),
    Ctx = user_ctx(T, UserId),
    ok = cx_event:subscribe(T),
    Desktop = spawn_conn(),
    Mobile = spawn_conn(),
    {ok, _} = cx_presence:connected(Ctx, Desktop, #{device => <<"desktop">>}),
    {ok, #{<<"state">> := <<"online">>}} = wait_presence(),
    {ok, _} = cx_presence:connected(Ctx, Mobile, #{device => <<"mobile">>}),
    {ok, #{<<"device_count">> := 2}} = cx_presence:get_own(Ctx),
    %% one device leaving changes nothing outward (activity first so the
    %% short away threshold can't fire inside the negative window)
    ok = cx_presence:activity(Ctx),
    ok = cx_presence:disconnected(Ctx, Desktop),
    ?assertEqual(timeout, wait_presence(150)),
    {ok, #{<<"device_count">> := 1, <<"state">> := <<"online">>}} =
        cx_presence:get_own(Ctx),
    %% the second dying (monitor path) takes the user offline
    stop_conn(Mobile),
    {ok, #{<<"user_id">> := UserId, <<"state">> := <<"offline">>}} =
        wait_presence(),
    stop_conn(Desktop),
    ok.

session_crash_reregister(_Config) ->
    {T, UserId} = mk_user(),
    Ctx = user_ctx(T, UserId),
    ok = cx_event:subscribe(T),
    Conn = spawn_conn(),
    {ok, SessPid} = cx_presence:connected(Ctx, Conn, #{}),
    {ok, #{<<"state">> := <<"online">>}} = wait_presence(),
    exit(SessPid, kill),
    ok = wait_until(fun() -> not is_process_alive(SessPid) end),
    %% the transport contract: the surviving connection re-registers
    {ok, NewPid} = cx_presence:connected(Ctx, Conn, #{}),
    ?assertNotEqual(SessPid, NewPid),
    {ok, #{<<"state">> := <<"online">>, <<"device_count">> := 1}} =
        cx_presence:get_own(Ctx),
    [#cx_presence_eff{pid = NewPid}] =
        mnesia:dirty_read(cx_presence_eff, {T, UserId}),
    stop_conn(Conn),
    ok.

set_while_connected(_Config) ->
    {T, UserId} = mk_user(),
    Ctx = user_ctx(T, UserId),
    ok = cx_event:subscribe(T),
    Conn = spawn_conn(),
    {ok, _} = cx_presence:connected(Ctx, Conn, #{}),
    {ok, #{<<"state">> := <<"online">>}} = wait_presence(),
    {ok, #{<<"state">> := <<"dnd">>}} =
        cx_presence:set_own(Ctx, #{<<"state">> => <<"dnd">>}),
    {ok, #{<<"user_id">> := UserId, <<"state">> := <<"dnd">>}} = wait_presence(),
    {ok, _} = cx_presence:set_own(Ctx, #{}),
    {ok, #{<<"state">> := <<"online">>}} = wait_presence(),
    stop_conn(Conn),
    ok.

validation_and_permissions(_Config) ->
    {T, UserId} = mk_user(),
    Ctx = user_ctx(T, UserId),
    NoPerms = cx_authz:ctx(T, UserId, <<"s">>, []),
    Integrator = cx_authz:ctx(T, [<<"presence:set:self">>]),
    ?assertEqual({error, forbidden}, cx_presence:set_own(NoPerms, #{})),
    ?assertEqual({error, no_user}, cx_presence:set_own(Integrator, #{})),
    ?assertEqual(
        {error, {invalid, <<"state">>}},
        cx_presence:set_own(Ctx, #{<<"state">> => <<"invisible">>})
    ),
    ?assertEqual(
        {error, {invalid, <<"until">>}},
        cx_presence:set_own(Ctx, #{
            <<"state">> => <<"busy">>, <<"until">> => cx_time:now_ms() - 1
        })
    ),
    %% until with nothing to expire is meaningless
    ?assertEqual(
        {error, {invalid, <<"until">>}},
        cx_presence:set_own(Ctx, #{<<"until">> => cx_time:now_ms() + 10000})
    ),
    ok.

directory_mixed(_Config) ->
    T = cx_id:new(),
    Admin = cx_authz:ctx(T, [<<"*">>]),
    Connected = create_user(Admin, <<"Connected">>),
    Away = create_user(Admin, <<"Vacationer">>),
    Plain = create_user(Admin, <<"Plain">>),
    Disabled = create_user(Admin, <<"Disabled">>),
    {ok, _} = cx_user:update(Admin, Disabled, #{<<"status">> => <<"disabled">>}),

    Conn = spawn_conn(),
    {ok, _} = cx_presence:connected(user_ctx(T, Connected), Conn, #{}),
    {ok, _} = cx_presence:set_own(user_ctx(T, Away), #{
        <<"state">> => <<"out_of_office">>, <<"message">> => <<"In Spain">>
    }),

    {ok, Entries} = cx_presence:directory(user_ctx(T, Plain)),
    ByUser = maps:from_list([{maps:get(<<"user_id">>, E), E} || E <- Entries]),
    ?assertEqual(3, map_size(ByUser)),
    ?assertNot(maps:is_key(Disabled, ByUser)),
    #{Connected := #{<<"state">> := <<"online">>}} = ByUser,
    #{Away := #{<<"state">> := <<"offline">>, <<"message">> := <<"In Spain">>}} =
        ByUser,
    #{Plain := #{<<"state">> := <<"offline">>, <<"message">> := null}} = ByUser,
    stop_conn(Conn),
    ok.

%% ---- helpers ----

mk_user() ->
    T = cx_id:new(),
    Admin = cx_authz:ctx(T, [<<"*">>]),
    {T, create_user(Admin, <<"Agent">>)}.

create_user(Admin, Name) ->
    {ok, #{<<"id">> := Id}} =
        cx_user:create(Admin, #{<<"name">> => Name, <<"email">> => <<"a@x">>}),
    Id.

user_ctx(T, UserId) ->
    cx_authz:ctx(T, UserId, <<"sub-", UserId/binary>>, [<<"presence:set:self">>]).

spawn_conn() ->
    spawn(fun Loop() ->
        receive
            stop -> ok;
            _ -> Loop()
        end
    end).

stop_conn(Pid) ->
    MRef = erlang:monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', MRef, process, Pid, _} -> ok
    after 1000 -> ok
    end.

wait_presence() ->
    wait_presence(2000).

wait_presence(Timeout) ->
    receive
        {cx_event, {_, _, _, #{type := presence_changed, data := Data}}} ->
            {ok, Data}
    after Timeout -> timeout
    end.

wait_until(Fun) ->
    wait_until(Fun, 200).

wait_until(_Fun, 0) ->
    error(condition_never_true);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(10),
            wait_until(Fun, N - 1)
    end.
