-module(cx_not_ready_reason_server).
-behaviour(gen_server).

-include("include/cx_config.hrl").
-include_lib("stdlib/include/qlc.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-define(TABLE, cx_not_ready_reason).

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
    {reply, create_not_ready_reason(Values), State};
handle_call({get, TenantId}, _From, State) ->
    {reply, get_not_ready_reason(TenantId), State};
handle_call({get, TenantId, Id}, _From, State) ->
    {reply, get_not_ready_reason(TenantId, Id), State};
handle_call({delete, [{tenant_id, TenantId}, {id, Id}]}, _From, State) ->
    {reply, delete_not_ready_reason(TenantId, Id), State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%-------------------------------------------------------------------
%% Internal functions
%%%-------------------------------------------------------------------

create_not_ready_reason([{name, Name}, {tenant_id, TenantId}]) ->
    NewNotReadyReason = #cx_not_ready_reason{
        id = cx_mnesia:create_id(),
        name = Name,
        tenant_id = TenantId
    },
    Fun = fun() -> mnesia:write(NewNotReadyReason) end,
    case mnesia:transaction(Fun) of
        {atomic, ok} -> {ok, NewNotReadyReason};
        {aborted, Reason} -> {error, Reason}
    end.

get_not_ready_reason(TenantId) ->
    Fun = fun() ->
        qlc:e(
            qlc:q([
                N
             || N <- mnesia:table(?TABLE), N#cx_not_ready_reason.tenant_id =:= TenantId
            ])
        )
    end,
    case mnesia:transaction(Fun) of
        {atomic, NotReadyReasons} -> {ok, NotReadyReasons};
        {aborted, Reason} -> {error, Reason}
    end.

get_not_ready_reason(TenantId, Id) ->
    Fun = fun() ->
        Q = qlc:q([
            N
         || N <- mnesia:table(?TABLE),
            N#cx_not_ready_reason.id =:= Id,
            N#cx_not_ready_reason.tenant_id =:= TenantId
        ]),
        qlc:eval(Q)
    end,
    case mnesia:transaction(Fun) of
        {atomic, []} -> {error, not_found};
        {atomic, [NotReadyReason]} -> {ok, NotReadyReason};
        {aborted, Reason} -> {error, Reason}
    end.

delete_not_ready_reason(TenantId, Id) ->
    Fun = fun() ->
        case mnesia:match_object(#cx_not_ready_reason{id = Id, tenant_id = TenantId, name = '_'}) of
            [NotReadyReason] ->
                mnesia:delete_object(NotReadyReason),
                {ok, deleted};
            [] ->
                {error, not_found}
        end
    end,
    case mnesia:transaction(Fun) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.
