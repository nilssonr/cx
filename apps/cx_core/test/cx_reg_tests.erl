-module(cx_reg_tests).

-include_lib("eunit/include/eunit.hrl").

reg_test_() ->
    {setup,
        fun() ->
            {ok, Pid} = cx_reg:start_link(),
            Pid
        end,
        fun(Pid) ->
            unlink(Pid),
            exit(Pid, shutdown)
        end,
        fun(_) ->
            [
                fun register_whereis_unregister/0,
                fun duplicate_name_refused/0,
                fun cleanup_on_death/0,
                fun via_tuple_works/0
            ]
        end}.

register_whereis_unregister() ->
    Name = {agent, <<"t1">>, <<"u1">>},
    Worker = spawn_idle(),
    ?assertEqual(yes, cx_reg:register_name(Name, Worker)),
    ?assertEqual(Worker, cx_reg:whereis_name(Name)),
    ?assertEqual(ok, cx_reg:unregister_name(Name)),
    ?assertEqual(undefined, cx_reg:whereis_name(Name)),
    stop_idle(Worker).

duplicate_name_refused() ->
    Name = {queue, <<"t1">>, <<"q1">>},
    A = spawn_idle(),
    B = spawn_idle(),
    ?assertEqual(yes, cx_reg:register_name(Name, A)),
    ?assertEqual(no, cx_reg:register_name(Name, B)),
    ?assertEqual(yes, cx_reg:register_name(Name, A)),
    ok = cx_reg:unregister_name(Name),
    stop_idle(A),
    stop_idle(B).

cleanup_on_death() ->
    Name = {agent, <<"t1">>, <<"dying">>},
    Worker = spawn_idle(),
    yes = cx_reg:register_name(Name, Worker),
    stop_idle(Worker),
    wait_until(fun() -> cx_reg:whereis_name(Name) =:= undefined end),
    Reborn = spawn_idle(),
    ?assertEqual(yes, cx_reg:register_name(Name, Reborn)),
    ok = cx_reg:unregister_name(Name),
    stop_idle(Reborn).

via_tuple_works() ->
    Name = {queue, <<"t1">>, <<"via">>},
    {ok, Pid} = gen_server:start({via, cx_reg, Name}, cx_reg_test_server, [], []),
    ?assertEqual(Pid, cx_reg:whereis_name(Name)),
    ?assertEqual(pong, gen_server:call({via, cx_reg, Name}, ping)),
    ok = gen_server:stop(Pid),
    wait_until(fun() -> cx_reg:whereis_name(Name) =:= undefined end).

spawn_idle() ->
    spawn(fun Loop() ->
        receive
            stop -> ok;
            _ -> Loop()
        end
    end).

stop_idle(Pid) ->
    MRef = erlang:monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', MRef, process, Pid, _} -> ok
    after 1000 -> error(worker_did_not_stop)
    end.

wait_until(Fun) ->
    wait_until(Fun, 100).

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
