-module(cx_service_group_server).
-behaviour(gen_server).

-include("include/cx_config.hrl").
-include_lib("stdlib/include/qlc.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-define(TABLE, cx_service_group).

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
    {reply, create_service_group(Values), State};
handle_call({get, TenantId}, _From, State) ->
    {reply, get_service_group(TenantId), State};
handle_call({get, TenantId, Id}, _From, State) ->
    {reply, get_service_group(TenantId, Id), State};
handle_call({delete, [{tenant_id, TenantId}, {id, Id}]}, _From, State) ->
    {reply, delete_service_group(TenantId, Id), State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%-------------------------------------------------------------------
%% Internal functions
%%%-------------------------------------------------------------------

create_service_group([{name, Name}, {tenant_id, TenantId}]) ->
    NewServiceGroup = #cx_service_group{
        id = cx_mnesia:create_id(),
        name = Name,
        tenant_id = TenantId
    },
    Fun = fun() -> mnesia:write(NewServiceGroup) end,
    case mnesia:transaction(Fun) of
        {atomic, ok} -> {ok, NewServiceGroup};
        {aborted, Reason} -> {error, Reason}
    end.

get_service_group(TenantId) ->
    Fun = fun() ->
        qlc:e(qlc:q([S || S <- mnesia:table(?TABLE), S#cx_service_group.tenant_id =:= TenantId]))
    end,
    case mnesia:transaction(Fun) of
        {atomic, ServiceGroups} -> {ok, ServiceGroups};
        {aborted, Reason} -> {error, Reason}
    end.

get_service_group(TenantId, Id) ->
    Fun = fun() ->
        Q = qlc:q([
            S
         || S <- mnesia:table(?TABLE),
            S#cx_service_group.id =:= Id,
            S#cx_service_group.tenant_id =:= TenantId
        ]),
        qlc:eval(Q)
    end,
    case mnesia:transaction(Fun) of
        {atomic, []} -> {error, not_found};
        {atomic, [ServiceGroup]} -> {ok, ServiceGroup};
        {aborted, Reason} -> {error, Reason}
    end.

delete_service_group(TenantId, Id) ->
    Fun = fun() ->
        case mnesia:match_object(#cx_service_group{id = Id, tenant_id = TenantId, name = '_'}) of
            [ServiceGroup] ->
                mnesia:delete_object(ServiceGroup),
                {ok, deleted};
            [] ->
                {error, not_found}
        end
    end,
    case mnesia:transaction(Fun) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.
