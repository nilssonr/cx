-module(cx_store).

%% Thin Mnesia access helpers shared by the entity modules.
%% sync_transaction so config writes are on disk when the call returns.
%%
%% Rows coming out of Mnesia are dynamically typed by nature; the
%% dynamic() returns push the checking to the callers' pattern matches
%% instead of pretending Mnesia gives us typed records.

-export([tx/1, read/2, list/2]).

-spec tx(fun(() -> eqwalizer:dynamic())) -> eqwalizer:dynamic().
tx(Fun) ->
    case mnesia:sync_transaction(Fun) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> error({db_aborted, Reason})
    end.

-spec read(atom(), term()) ->
          {ok, eqwalizer:dynamic()} | {error, not_found}.
read(Tab, Key) ->
    tx(fun() ->
        case mnesia:read(Tab, Key) of
            [Rec] -> {ok, Rec};
            [] -> {error, not_found}
        end
    end).

%% Pattern comes from cx_patterns and must constrain the key to
%% {TenantId, '_'} (or the tenant id itself for cx_tenant) — tenant
%% scoping happens in the pattern.
-spec list(atom(), tuple()) -> [eqwalizer:dynamic()].
list(Tab, Pattern) ->
    tx(fun() -> mnesia:match_object(Tab, Pattern, read) end).
