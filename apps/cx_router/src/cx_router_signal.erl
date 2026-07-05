-module(cx_router_signal).

%% Availability wake-ups: a bare signal per tenant, delivered to every
%% queue process. Queues re-derive everything from the presence table —
%% the signal carries no state on purpose.

-export([join/1, agent_available/1]).

-spec join(binary()) -> ok.
join(TenantId) ->
    ok = pg:join(cx_event:scope(), {agents_available, TenantId}, self()).

-spec agent_available(binary()) -> ok.
agent_available(TenantId) ->
    Members = pg:get_members(cx_event:scope(), {agents_available, TenantId}),
    lists:foreach(fun(Pid) -> Pid ! cx_agent_available end, Members),
    ok.
