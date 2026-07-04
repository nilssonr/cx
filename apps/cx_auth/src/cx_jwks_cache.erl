-module(cx_jwks_cache).

%% Fetches the issuer's JWKS over HTTP, caches parsed keys in ETS, and
%% refetches periodically. An unknown kid triggers a forced refetch (key
%% rotation) with a cooldown so a flood of bad tokens can't hammer the
%% IdP. A failed fetch keeps the previous keys — better stale than none.

-behaviour(gen_server).

-export([start_link/0, get_keys/0, refresh/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         handle_continue/2]).

-define(TAB, cx_jwks_cache_tab).
-define(COOLDOWN_MS, 30000).
-define(FETCH_TIMEOUT_MS, 5000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_keys() -> [{binary() | undefined, jose_jwk:key()}].
get_keys() ->
    try ets:tab2list(?TAB)
    catch error:badarg -> []
    end.

-spec refresh() -> ok.
refresh() ->
    gen_server:call(?MODULE, refresh, 10000).

init([]) ->
    ?TAB = ets:new(?TAB, [named_table, set, protected, {read_concurrency, true}]),
    RefreshMs = application:get_env(cx_auth, jwks_refresh_ms, 300000),
    {ok, #{last_fetch => 0, refresh_ms => RefreshMs},
     {continue, initial_fetch}}.

handle_continue(initial_fetch, State) ->
    {noreply, schedule(do_fetch(State))}.

handle_call(refresh, _From, State = #{last_fetch := Last}) ->
    Now = erlang:monotonic_time(millisecond),
    State1 = case Now - Last > ?COOLDOWN_MS of
        true -> do_fetch(State);
        false -> State
    end,
    {reply, ok, State1}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(periodic_refresh, State) ->
    {noreply, schedule(do_fetch(State))};
handle_info(_Msg, State) ->
    {noreply, State}.

schedule(State = #{refresh_ms := RefreshMs}) ->
    erlang:send_after(RefreshMs, self(), periodic_refresh),
    State.

do_fetch(State) ->
    {ok, {jwks, Url}} = application:get_env(cx_auth, key_source),
    State1 = State#{last_fetch => erlang:monotonic_time(millisecond)},
    try
        {ok, {{_, 200, _}, _, Body}} =
            httpc:request(get, {binary_to_list(Url), []},
                          [{timeout, ?FETCH_TIMEOUT_MS}],
                          [{body_format, binary}]),
        {ok, #{<<"keys">> := KeyMaps}} = cx_json:decode(Body),
        Keys = [{maps:get(<<"kid">>, M, undefined), jose_jwk:from_map(M)}
                || M <- KeyMaps, is_map(M)],
        ets:delete_all_objects(?TAB),
        ets:insert(?TAB, Keys),
        State1
    catch
        Class:Reason ->
            logger:warning("cx_jwks_cache: JWKS fetch from ~s failed: ~p:~p "
                           "(keeping ~b cached keys)",
                           [Url, Class, Reason, ets:info(?TAB, size)]),
            State1
    end.
