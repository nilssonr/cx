-module(cx_router_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    ChildSpecs = [
        #{id => cx_agent_session_sup,
          start => {cx_agent_session_sup, start_link, []},
          type => supervisor},
        #{id => cx_queue_sup,
          start => {cx_queue_sup, start_link, []},
          type => supervisor},
        #{id => cx_queue_boot,
          start => {cx_queue_boot, start_link, []},
          restart => transient}
    ],
    {ok, {SupFlags, ChildSpecs}}.
