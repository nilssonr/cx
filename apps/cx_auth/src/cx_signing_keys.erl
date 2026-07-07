-module(cx_signing_keys).

%% The issuer's own JWS signing keys (RS256). Generates the first key at
%% boot if none exists, keeps the newest active private key for signing and
%% every public half for verification + JWKS, and rotates with a two-key
%% overlap: a rotated key becomes `retiring` and stays published/accepted
%% until its longest-lived token expires (design §8). Persisted in the
%% cx_signing_key Mnesia table; cached in a protected ETS table for
%% concurrent reads on the hot verify/JWKS paths — the cx_jwks_cache shape,
%% but the keys are ours, not fetched over HTTP.
%%
%% Only started when key_source = local (cx_auth_sup); a deployment still
%% federating to an external IdP has no issuer keys.

-behaviour(gen_server).

-include_lib("cx_core/include/cx_core.hrl").

-export([start_link/0, signing_key/0, verification_keys/0, jwks/0, rotate/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, cx_signing_keys_tab).
-define(DEFAULT_BITS, 2048).
-define(DEFAULT_ALG, <<"RS256">>).
-define(DEFAULT_ACCESS_TTL_S, 600).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% The active key to sign with: {Kid, private JWK}.
-spec signing_key() -> {binary(), jose_jwk:key()}.
signing_key() ->
    [{signing, Kid, JWK}] = ets:lookup(?TAB, signing),
    {Kid, JWK}.

%% Every published key as {Kid, public JWK} — the local key source feeds the
%% existing cx_auth_jwt verify path from this.
-spec verification_keys() -> [{binary(), jose_jwk:key()}].
verification_keys() ->
    try ets:lookup(?TAB, verifying) of
        [{verifying, Keys}] -> Keys;
        [] -> []
    catch
        error:badarg -> []
    end.

%% Public JWK maps for the JWKS endpoint (kid/alg/use annotated; never a
%% private half).
-spec jwks() -> [map()].
jwks() ->
    try ets:lookup(?TAB, jwks) of
        [{jwks, Maps}] -> Maps;
        [] -> []
    catch
        error:badarg -> []
    end.

%% Operator-triggered rotation (design §8): mint a new active key, retire the
%% current one with a grace window covering outstanding access tokens.
-spec rotate() -> ok.
rotate() ->
    gen_server:call(?MODULE, rotate).

init([]) ->
    ok = assert_secure_issuer(),
    ?TAB = ets:new(?TAB, [named_table, set, protected, {read_concurrency, true}]),
    ensure_active(),
    ok = refresh_cache(),
    {ok, #{}}.

handle_call(rotate, _From, State) ->
    ok = do_rotate(),
    ok = refresh_cache(),
    {reply, ok, State};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

%% ---- internals ----

%% Never mint tokens whose iss is a plain-http URL in production. Mirrors the
%% cx_jwks_cache transport guard: the allow_insecure_jwks dev flag (Zitadel
%% on localhost) also permits an http issuer; production leaves it false and
%% must use https.
assert_secure_issuer() ->
    Issuer = application:get_env(cx_auth, issuer, undefined),
    Allow = application:get_env(cx_auth, allow_insecure_jwks, false) =:= true,
    case is_https(Issuer) orelse Allow of
        true ->
            ok;
        false ->
            logger:error(
                "cx_signing_keys: issuer ~p is not https and allow_insecure_jwks "
                "is not set — refusing to start the local issuer.",
                [Issuer]
            ),
            error({insecure_issuer, Issuer})
    end.

is_https(<<"https://", _/binary>>) -> true;
is_https(_) -> false.

ensure_active() ->
    case active_keys(load_all()) of
        [] ->
            _ = generate(),
            ok;
        [_ | _] ->
            ok
    end.

refresh_cache() ->
    Rows = load_all(),
    Signer = signer(Rows),
    true = ets:insert(?TAB, {
        signing,
        Signer#cx_signing_key.kid,
        jose_jwk:from_map(Signer#cx_signing_key.private_jwk)
    }),
    true = ets:insert(
        ?TAB,
        {verifying, [
            {R#cx_signing_key.kid, jose_jwk:from_map(R#cx_signing_key.public_jwk)}
         || R <- Rows
        ]}
    ),
    true = ets:insert(?TAB, {jwks, [jwks_entry(R) || R <- Rows]}),
    ok.

%% Newest active key by created_at is the signer; ensure_active/0 guarantees
%% at least one exists before this runs.
signer(Rows) ->
    hd(
        lists:sort(
            fun(A, B) -> A#cx_signing_key.created_at >= B#cx_signing_key.created_at end,
            active_keys(Rows)
        )
    ).

active_keys(Rows) ->
    [R || R = #cx_signing_key{status = active} <- Rows].

jwks_entry(#cx_signing_key{kid = Kid, alg = Alg, public_jwk = PubMap}) ->
    PubMap#{<<"kid">> => Kid, <<"alg">> => Alg, <<"use">> => <<"sig">>}.

load_all() ->
    cx_store:list(cx_signing_key, cx_patterns:signing_keys()).

generate() ->
    Rec = build_key(),
    ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
    Rec.

do_rotate() ->
    New = build_key(),
    Now = cx_time:now_ms(),
    Grace = cx_config:get(cx_auth, token_access_ttl_s, ?DEFAULT_ACCESS_TTL_S) * 1000,
    ok = cx_store:tx(fun() ->
        Actives = [
            R
         || R = #cx_signing_key{status = active} <- mnesia:match_object(cx_patterns:signing_keys())
        ],
        lists:foreach(
            fun(R) ->
                mnesia:write(R#cx_signing_key{status = retiring, not_after = Now + Grace})
            end,
            Actives
        ),
        mnesia:write(New)
    end),
    ok.

build_key() ->
    Bits = cx_config:get(cx_auth, signing_key_bits, ?DEFAULT_BITS),
    Alg = cx_config:get(cx_auth, signing_alg, ?DEFAULT_ALG),
    JWK = jose_jwk:generate_key({rsa, Bits}),
    Kid = cx_id:new(),
    {_, PubMap} = jose_jwk:to_public_map(JWK),
    {_, PrivMap} = jose_jwk:to_map(JWK),
    Now = cx_time:now_ms(),
    #cx_signing_key{
        kid = Kid,
        alg = Alg,
        private_jwk = PrivMap,
        public_jwk = PubMap,
        status = active,
        created_at = Now,
        not_after = undefined
    }.
