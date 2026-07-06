-module(cx_presence_calculation).

%% The pure core of collaboration presence: effective presence is
%% COMPUTED from the declared layer (durable) plus live connectivity
%% observations — never stored. No processes, no Mnesia, no side
%% effects; the whole semantics is property-testable.

-include_lib("cx_core/include/cx_core.hrl").

-export([from_row/1, normalize/2, effective/5, connectionless/3]).

-type declared() :: #{
    manual_state := binary() | undefined,
    message := binary() | undefined,
    until := integer() | undefined
}.
-type effective() :: #{state := binary(), message := binary() | undefined}.

-export_type([declared/0, effective/0]).

%% Declared layer from a raw row; row absence == fully automatic.
-spec from_row(#cx_presence_decl{} | undefined) -> declared().
from_row(undefined) ->
    #{manual_state => undefined, message => undefined, until => undefined};
from_row(#cx_presence_decl{manual_state = S, message = M, until = U}) ->
    #{manual_state => S, message => M, until => U}.

%% Strip an expired manual layer: once Until =< Now, manual_state and
%% message are both treated as absent. The stored row is never mutated —
%% `until` is only ever compared to now — so connectionless users expire
%% correctly with no process involved.
-spec normalize(declared(), integer()) -> declared().
normalize(#{until := Until}, Now) when
    is_integer(Until), Until =< Now
->
    #{manual_state => undefined, message => undefined, until => undefined};
normalize(Declared, _Now) ->
    Declared.

%% Precedence, top wins:
%%   1. no connected devices          -> offline (message still shown)
%%   2. manual_state set              -> manual_state
%%   3. idle for >= AwayThresholdMs   -> away
%%   4. otherwise                     -> online
-spec effective(
    declared(),
    non_neg_integer(),
    integer(),
    integer(),
    pos_integer()
) -> effective().
effective(Declared0, DeviceCount, LastActivityMs, NowMs, AwayThresholdMs) ->
    #{manual_state := Manual, message := Message} = normalize(Declared0, NowMs),
    State =
        if
            DeviceCount =:= 0 -> <<"offline">>;
            Manual =/= undefined -> Manual;
            NowMs - LastActivityMs >= AwayThresholdMs -> <<"away">>;
            true -> <<"online">>
        end,
    #{state => State, message => Message}.

%% Effective presence for a user with zero live connections: the
%% declared row is the entire input (no devices, no activity). Bundles
%% the normalized `until` with state/message — the three values every
%% connectionless read (directory, own-map, facade publish) needs.
-spec connectionless(#cx_presence_decl{} | undefined, integer(), pos_integer()) ->
    #{
        state := binary(),
        message := binary() | undefined,
        until := integer() | undefined
    }.
connectionless(Row, NowMs, AwayThresholdMs) ->
    Declared = from_row(Row),
    #{state := S, message := M} = effective(Declared, 0, 0, NowMs, AwayThresholdMs),
    #{until := U} = normalize(Declared, NowMs),
    #{state => S, message => M, until => U}.
