-module(cx_core_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    ChildSpecs = [
        #{
            id => cx_event_scope,
            start => {pg, start_link, [cx_event:scope()]}
        },
        #{
            id => cx_reg,
            start => {cx_reg, start_link, []}
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
