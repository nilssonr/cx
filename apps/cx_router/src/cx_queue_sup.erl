-module(cx_queue_sup).

%% Queue processes are transient: an abnormal exit restarts the process
%% with the same {TenantId, QueueId} args, and its init rebuilds waiting
%% state from Mnesia — a queue crash loses only in-flight offers.

-behaviour(supervisor).

-export([start_link/0, start_queue/2]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_queue(TenantId, QueueId) ->
    supervisor:start_child(?MODULE, [TenantId, QueueId]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    ChildSpecs = [
        #{
            id => cx_queue_process,
            start => {cx_queue_process, start_link, []},
            restart => transient
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
