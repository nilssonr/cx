-module(cx_skill_server).
-behaviour(gen_server).

-include("include/cx_config.hrl").
-include_lib("stdlib/include/qlc.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-define(TABLE, cx_skill).

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
    {reply, create_skill(Values), State};
handle_call({get, TenantId}, _From, State) ->
    {reply, get_skill(TenantId), State};
handle_call({get, TenantId, Id}, _From, State) ->
    {reply, get_skill(TenantId, Id), State};
handle_call({delete, [{tenant_id, TenantId}, {id, Id}]}, _From, State) ->
    {reply, delete_skill(TenantId, Id), State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%-------------------------------------------------------------------
%% Internal functions
%%%-------------------------------------------------------------------

create_skill([{name, Name}, {tenant_id, TenantId}]) ->
    NewSkill = #cx_skill{
        id = cx_mnesia:create_id(),
        name = Name,
        tenant_id = TenantId
    },
    Fun = fun() -> mnesia:write(NewSkill) end,
    case mnesia:transaction(Fun) of
        {atomic, ok} -> {ok, NewSkill};
        {aborted, Reason} -> {error, Reason}
    end.

get_skill(TenantId) ->
    Fun = fun() ->
        qlc:e(qlc:q([S || S <- mnesia:table(?TABLE), S#cx_skill.tenant_id =:= TenantId]))
    end,
    case mnesia:transaction(Fun) of
        {atomic, Skills} -> {ok, Skills};
        {aborted, Reason} -> {error, Reason}
    end.

get_skill(TenantId, Id) ->
    Fun = fun() ->
        Q = qlc:q([
            S
         || S <- mnesia:table(?TABLE), S#cx_skill.id =:= Id, S#cx_skill.tenant_id =:= TenantId
        ]),
        qlc:eval(Q)
    end,
    case mnesia:transaction(Fun) of
        {atomic, []} -> {error, not_found};
        {atomic, [Skill]} -> {ok, Skill};
        {aborted, Reason} -> {error, Reason}
    end.

delete_skill(TenantId, Id) ->
    Fun = fun() ->
        case mnesia:match_object(#cx_skill{id = Id, tenant_id = TenantId, name = '_'}) of
            [Skill] ->
                mnesia:delete_object(Skill),
                {ok, deleted};
            [] ->
                {error, not_found}
        end
    end,
    case mnesia:transaction(Fun) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.
