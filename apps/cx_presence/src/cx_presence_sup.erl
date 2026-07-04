-module(cx_presence_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    ChildSpecs = [
        #{
            id => cx_presence_session_sup,
            start => {cx_presence_session_sup, start_link, []},
            type => supervisor
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
