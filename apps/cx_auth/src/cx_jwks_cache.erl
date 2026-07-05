-module(cx_jwks_cache).

%% Fetches the issuer's JWKS over HTTP, caches parsed keys in ETS, and
%% refetches periodically. An unknown kid triggers a forced refetch (key
%% rotation) with a cooldown so a flood of bad tokens can't hammer the
%% IdP. A failed fetch keeps the previous keys — better stale than none.
%%
%% Transport security: by default https URLs are fetched with
%% verify_peer against the OS trust store and plain http is refused at
%% boot. The cx_auth env `allow_insecure_jwks` (dev/test ONLY — e.g.
%% the plain-HTTP Zitadel in docker/docker-compose.yml) permits http
%% and downgrades https to verify_none. This is not an auth-disabled
%% mode: token signature/iss/aud/exp verification is untouched; the
%% flag governs only how the public keys travel.
%%
%% All keys are kept under one ETS row, so duplicate kids (overlapping
%% rotation) and kid-less keys survive, and a refresh replaces the set
%% atomically (no empty-table window).

-behaviour(gen_server).

-export([start_link/0, get_keys/0, refresh/0]).
-export([http_options/2, parse_jwks/1]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_continue/2
]).

-define(TAB, cx_jwks_cache_tab).
-define(COOLDOWN_MS, 30000).
-define(FETCH_TIMEOUT_MS, 5000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_keys() -> [{binary() | undefined, jose_jwk:key()}].
get_keys() ->
    try ets:lookup(?TAB, keys) of
        [{keys, Keys}] -> Keys;
        [] -> []
    catch
        error:badarg -> []
    end.

-spec refresh() -> ok.
refresh() ->
    gen_server:call(?MODULE, refresh, 10000).

%% httpc HTTPOptions for a JWKS URL. Secure mode (Allow = false, the
%% default): https gets explicit verify_peer + OS CAs — never inets
%% defaults — and http is refused. Insecure mode: http passes and
%% https skips verification.
-spec http_options(binary(), boolean()) -> {ok, [tuple()]} | {error, insecure_jwks_url}.
http_options(<<"https://", _/binary>>, false) ->
    {ok, [
        {timeout, ?FETCH_TIMEOUT_MS},
        {ssl, [
            {verify, verify_peer},
            {cacerts, public_key:cacerts_get()},
            {depth, 3},
            {customize_hostname_check, [
                {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
            ]}
        ]}
    ]};
http_options(<<"https://", _/binary>>, true) ->
    {ok, [{timeout, ?FETCH_TIMEOUT_MS}, {ssl, [{verify, verify_none}]}]};
http_options(<<"http://", _/binary>>, true) ->
    {ok, [{timeout, ?FETCH_TIMEOUT_MS}]};
http_options(_, _) ->
    {error, insecure_jwks_url}.

%% JWKS body -> key list, preserving duplicate and absent kids
%% (overlapping rotation publishes both generations).
-spec parse_jwks(binary()) ->
    {ok, [{binary() | undefined, jose_jwk:key()}]} | {error, {invalid, json}}.
parse_jwks(Body) ->
    maybe
        {ok, #{<<"keys">> := KeyMaps}} ?= cx_json:decode(Body),
        {ok, [
            {maps:get(<<"kid">>, M, undefined), jose_jwk:from_map(M)}
         || M <- KeyMaps, is_map(M)
        ]}
    else
        _ -> {error, {invalid, json}}
    end.

init([]) ->
    {ok, {jwks, Url}} = application:get_env(cx_auth, key_source),
    Allow = application:get_env(cx_auth, allow_insecure_jwks, false) =:= true,
    Allow andalso
        logger:warning(
            "cx_auth: allow_insecure_jwks is enabled — JWKS is fetched "
            "without TLS verification. Dev/test only; production must "
            "leave it at the default (false)."
        ),
    case http_options(Url, Allow) of
        {ok, HttpOpts} ->
            ?TAB = ets:new(?TAB, [named_table, set, protected, {read_concurrency, true}]),
            RefreshMs = application:get_env(cx_auth, jwks_refresh_ms, 300000),
            State = #{last_fetch => 0, refresh_ms => RefreshMs, http_opts => HttpOpts},
            {ok, State, {continue, initial_fetch}};
        {error, insecure_jwks_url} ->
            %% fail fast: silently running keyless would reject every
            %% token with no hint at the cause
            logger:error(
                "cx_auth: JWKS url ~s is plain http but allow_insecure_jwks "
                "is not set — refusing to start. Use https, or set "
                "{allow_insecure_jwks, true} in dev/test config.",
                [Url]
            ),
            {stop, {insecure_jwks_url, Url}}
    end.

handle_continue(initial_fetch, State) ->
    {noreply, schedule(do_fetch(State))}.

handle_call(refresh, _From, State = #{last_fetch := Last}) ->
    Now = erlang:monotonic_time(millisecond),
    State1 =
        case Now - Last > ?COOLDOWN_MS of
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

do_fetch(State = #{http_opts := HttpOpts}) ->
    {ok, {jwks, Url}} = application:get_env(cx_auth, key_source),
    State1 = State#{last_fetch => erlang:monotonic_time(millisecond)},
    try
        Keys =
            case
                httpc:request(
                    get,
                    {binary_to_list(Url), []},
                    HttpOpts,
                    [{body_format, binary}]
                )
            of
                {ok, {{_, 200, _}, _, Body}} when is_binary(Body) ->
                    {ok, Ks} = parse_jwks(Body),
                    Ks
            end,
        %% one insert replaces the whole set atomically
        true = ets:insert(?TAB, {keys, Keys}),
        State1
    catch
        Class:Reason ->
            logger:warning(
                "cx_jwks_cache: JWKS fetch from ~s failed: ~p:~p "
                "(keeping ~b cached keys)",
                [Url, Class, Reason, length(?MODULE:get_keys())]
            ),
            State1
    end.
