-module(cx_event).

%% Domain event pub/sub on a dedicated pg scope. Every state transition in
%% cx publishes here; consumers (agent desktops, wallboards, reporting)
%% subscribe per tenant or per queue. Delivery is best-effort fan-out —
%% events are notifications, not a durable log (that comes later).

-export([scope/0]).
-export([subscribe/1, subscribe/2, unsubscribe/1, unsubscribe/2]).
-export([publish/4]).

-define(SCOPE, cx_event).

-spec scope() -> atom().
scope() -> ?SCOPE.

-spec subscribe(binary()) -> ok.
subscribe(TenantId) ->
    ok = pg:join(?SCOPE, {tenant, TenantId}, self()).

-spec subscribe(binary(), binary()) -> ok.
subscribe(TenantId, QueueId) ->
    ok = pg:join(?SCOPE, {queue, TenantId, QueueId}, self()).

-spec unsubscribe(binary()) -> ok.
unsubscribe(TenantId) ->
    _ = pg:leave(?SCOPE, {tenant, TenantId}, self()),
    ok.

-spec unsubscribe(binary(), binary()) -> ok.
unsubscribe(TenantId, QueueId) ->
    _ = pg:leave(?SCOPE, {queue, TenantId, QueueId}, self()),
    ok.

%% Event :: #{type := atom(), at := integer(), data := map()}.
%% QueueId/MediaTypeId may be `undefined` for events with no queue/media
%% dimension (e.g. config CRUD).
-spec publish(binary(), binary() | undefined, binary() | undefined, map()) -> ok.
publish(TenantId, QueueId, MediaTypeId, Event) ->
    Msg = {cx_event, {TenantId, QueueId, MediaTypeId, Event}},
    Tenant = pg:get_members(?SCOPE, {tenant, TenantId}),
    Queue =
        case QueueId of
            undefined -> [];
            _ -> pg:get_members(?SCOPE, {queue, TenantId, QueueId})
        end,
    lists:foreach(
        fun(Pid) when is_pid(Pid) -> Pid ! Msg end,
        lists:usort(Tenant ++ Queue)
    ),
    ok.
