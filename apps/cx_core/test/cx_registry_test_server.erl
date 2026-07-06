-module(cx_registry_test_server).

%% Trivial gen_server used by cx_registry_tests to prove via-tuple registration.

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2]).

init([]) -> {ok, #{}}.

handle_call(ping, _From, State) -> {reply, pong, State}.

handle_cast(_Msg, State) -> {noreply, State}.
