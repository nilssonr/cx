-module(cx_agent_session_sup).

%% Agent sessions are temporary: a crashed session is NOT restarted — the
%% agent's client re-establishes it and comes back not-ready for all
%% media. Readiness the agent didn't reassert is never resurrected.

-behaviour(supervisor).

-export([start_link/0, start_session/4]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_session(TenantId, AgentId, Skills, Profile) ->
    supervisor:start_child(?MODULE, [TenantId, AgentId, Skills, Profile]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    ChildSpecs = [
        #{id => cx_agent_session,
          start => {cx_agent_session, start_link, []},
          restart => temporary}
    ],
    {ok, {SupFlags, ChildSpecs}}.
