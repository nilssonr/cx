-module(cx_user_server).
-behaviour(gen_server).

-include("include/cx_config.hrl").
-include_lib("stdlib/include/qlc.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-define(TABLE, cx_user).

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
    {reply, create_user(Values), State};
handle_call({get, TenantId}, _From, State) ->
    {reply, get_user(TenantId), State};
handle_call({get, TenantId, Id}, _From, State) ->
    {reply, get_user(TenantId, Id), State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%-------------------------------------------------------------------
%% Internal functions
%%%-------------------------------------------------------------------

create_user(Values) ->
    {ok, Salt} = bcrypt:gen_salt(),
    {ok, Password} = bcrypt:hashpw(proplists:get_value(password, Values, ""), Salt),
    NewUser = #cx_user{
        id = cx_mnesia:create_id(),
        first_name = proplists:get_value(first_name, Values, ""),
        last_name = proplists:get_value(last_name, Values, ""),
        email_address = proplists:get_value(email_address, Values, ""),
        password = Password,
        tenant_id = proplists:get_value(tenant_id, Values, "")
    },
    Fun = fun() -> mnesia:write(NewUser) end,
    case mnesia:transaction(Fun) of
        {atomic, ok} -> {ok, NewUser};
        {aborted, Reason} -> {error, Reason}
    end.

get_user(TenantId) ->
    Fun = fun() ->
        qlc:e(qlc:q([U || U <- mnesia:table(?TABLE), U#cx_user.tenant_id =:= TenantId]))
    end,
    case mnesia:transaction(Fun) of
        {atomic, Users} -> {ok, Users};
        {aborted, Reason} -> {error, Reason}
    end.

get_user(TenantId, Id) ->
    Fun = fun() ->
        Q = qlc:q([
            U
         || U <- mnesia:table(?TABLE), U#cx_user.id =:= Id, U#cx_user.tenant_id =:= TenantId
        ]),
        qlc:eval(Q)
    end,
    case mnesia:transaction(Fun) of
        {atomic, []} -> {error, not_found};
        {atomic, [User]} -> {ok, User};
        {aborted, Reason} -> {error, Reason}
    end.
