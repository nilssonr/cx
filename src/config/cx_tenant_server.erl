-module(cx_tenant_server).
-behaviour(gen_server).

-include("include/cx_config.hrl").
-include_lib("stdlib/include/qlc.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-define(TABLE, cx_tenant).

%%%-------------------------------------------------------------------
%%% Public API
%%%-------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%-------------------------------------------------------------------
%%% gen_server Callbacks
%%%-------------------------------------------------------------------

init([]) ->
    {ok, []}.

handle_call({create, Values}, _From, State) ->
    {reply, create_tenant(Values), State};
handle_call({get}, _From, State) ->
    {reply, get_tenant(), State};
handle_call({get, Id}, _From, State) ->
    {reply, get_tenant(Id), State};
handle_call({update, Id, Values}, _From, State) ->
    {reply, update_tenant(Id, Values), State};
handle_call({delete, Id}, _From, State) ->
    {reply, delete_tenant(Id), State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%-------------------------------------------------------------------
%% Internal functions
%%%-------------------------------------------------------------------

create_tenant([{name, Name}]) ->
    NewTenant = #cx_tenant{id = cx_mnesia:create_id(), name = Name},
    Fun = fun() -> mnesia:write(NewTenant) end,
    case mnesia:transaction(Fun) of
        {atomic, ok} -> {ok, NewTenant};
        {aborted, Reason} -> {error, Reason}
    end.

get_tenant() ->
    Fun = fun() -> qlc:e(qlc:q([T || T <- mnesia:table(?TABLE)])) end,
    case mnesia:transaction(Fun) of
        {atomic, Tenants} -> {ok, Tenants};
        {aborted, Reason} -> {error, Reason}
    end.

get_tenant(Id) ->
    Fun = fun() -> mnesia:read(?TABLE, Id) end,
    case mnesia:transaction(Fun) of
        {atomic, [Tenant]} -> {ok, Tenant};
        {atomic, []} -> {error, not_found};
        {aborted, Reason} -> {error, Reason}
    end.

update_tenant(Id, Values) ->
    Fun = fun() ->
        case mnesia:read({?TABLE, Id}) of
            [Tenant] ->
                UpdatedTenant = update_tenant_fields(Tenant, Values),
                mnesia:write(UpdatedTenant),
                {ok, UpdatedTenant};
            [] ->
                {error, not_found}
        end
    end,
    case mnesia:transaction(Fun) of
        {atomic, {ok, UpdatedTenant}} -> {ok, UpdatedTenant};
        {atomic, {error, Reason}} -> {error, Reason};
        {aborted, Reason} -> {error, Reason}
    end.

update_tenant_fields(Tenant, Values) ->
    Tenant#cx_tenant{
        name = proplists:get_value(name, Values, Tenant#cx_tenant.name)
    }.

delete_tenant(Id) ->
    case mnesia:transaction(fun() -> mnesia:delete({cx_tenant, Id}) end) of
        {atomic, ok} -> {ok, deleted};
        {aborted, Reason} -> {error, Reason}
    end.
