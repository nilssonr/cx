-module(cx_queue_boot).

%% Transient boot worker: starts a queue process for every open queue in
%% Mnesia (so queued interactions recover after a node restart without
%% waiting for traffic), then exits normally.

-include_lib("cx_core/include/cx_core.hrl").

-export([start_link/0]).

start_link() ->
    Pid = spawn_link(fun boot/0),
    {ok, Pid}.

boot() ->
    Queues = mnesia:dirty_match_object(cx_patterns:open_queues()),
    lists:foreach(
        fun(#cx_queue{key = {TenantId, QueueId}}) ->
            {ok, _} = cx_queue_proc:ensure_started(TenantId, QueueId)
        end, Queues).
