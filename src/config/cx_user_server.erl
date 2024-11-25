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

-spec create_user(map()) -> {ok, #cx_user{}} | {error, term()}.
create_user(Values) when is_map(Values) ->
    case validate_required_fields(Values) of
        true ->
            NewUser = create_record(Values),
            case mnesia:transaction(fun() -> mnesia:write(NewUser) end) of
                {atomic, ok} ->
                    {ok, NewUser};
                {aborted, Reason} ->
                    {error, Reason}
            end;
        false ->
            {error, bad_request}
    end.

-spec validate_required_fields(map()) -> true | false.
validate_required_fields(Values) when is_map(Values) ->
    Required = [first_name, email_address, password, tenant_id],
    lists:all(fun(K) -> maps:is_key(K, Values) end, Required).

-spec create_record(map()) -> #cx_user{}.
create_record(Values) when is_map(Values) ->
    {ok, Salt} = bcrypt:gen_salt(),
    {ok, Password} = bcrypt:hashpw(maps:get(password, Values), Salt),
    #cx_user{
        id = cx_mnesia:create_id(),
        first_name = maps:get(first_name, Values),
        last_name = maps:get(last_name, Values, <<>>),
        email_address = maps:get(email_address, Values),
        password = list_to_binary(Password),
        tenant_id = maps:get(tenant_id, Values)
    }.

-spec get_user(binary()) -> {ok, list()} | {error, term()}.
get_user(TenantId) ->
    Fun = fun() -> qlc:e(get_user_query([{tenant_id, TenantId}])) end,
    case mnesia:transaction(Fun) of
        {atomic, Users} ->
            {ok, Users};
        {aborted, Reason} ->
            {error, Reason}
    end.

-spec get_user(binary(), binary()) -> {ok, #cx_user{}} | {error, not_found} | {error, term()}.
get_user(TenantId, Id) ->
    Fun = fun() -> qlc:e(get_user_query([{tenant_id, TenantId}, {id, Id}])) end,
    case mnesia:transaction(Fun) of
        {atomic, []} ->
            {error, not_found};
        {atomic, [User]} ->
            {ok, User};
        {aborted, Reason} ->
            {error, Reason}
    end.

get_user_query([{tenant_id, TenantId}]) ->
    qlc:q([U || U <- mnesia:table(?TABLE), U#cx_user.tenant_id =:= TenantId]);
get_user_query([{tenant_id, TenantId}, {id, Id}]) ->
    qlc:q([U || U <- mnesia:table(?TABLE), U#cx_user.tenant_id =:= TenantId, U#cx_user.id =:= Id]).
