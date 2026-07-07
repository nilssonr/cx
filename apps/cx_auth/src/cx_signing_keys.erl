-module(cx_signing_keys).

%% The issuer's own JWS signing keys. Owns the LIFECYCLE — generate the first
%% key at boot if none exists, keep the newest active private key for signing
%% and every published half for verification + JWKS, rotate with a two-key
%% overlap — and delegates the two things that vary:
%%   * WHICH algorithm            -> cx_jws_alg (closed atom registry)
%%   * HOW the key is acquired     -> a cx_signing_key_source behaviour module
%%                                    (generated | static-symmetric | ...).
%% So this file no longer knows RSA or "RS256"; it speaks algorithm atoms and
%% source modules. Symmetric keys are handled without shoehorning: they have
%% no public half, so they never reach the JWKS and verify with the shared
%% secret.
%%
%% Persisted in the cx_signing_key Mnesia table; cached in a protected ETS
%% table for concurrent reads on the hot verify/JWKS paths. Only started when
%% key_source = local (cx_auth_sup).

-behaviour(gen_server).

-include_lib("cx_core/include/cx_core.hrl").

-export([start_link/0, signing_key/0, verification_keys/0, jwks/0, rotate/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, cx_signing_keys_tab).
-define(DEFAULT_ALG, rs256).
-define(DEFAULT_SOURCE, cx_signing_key_generated).
-define(DEFAULT_ACCESS_TTL_S, 600).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% The active key to sign with: {Kid, private JWK, JWS alg header name}.
-spec signing_key() -> {binary(), jose_jwk:key(), binary()}.
signing_key() ->
    [{signing, Kid, JWK, JwsName}] = ets:lookup(?TAB, signing),
    {Kid, JWK, JwsName}.

%% Every key that can verify a token as {Kid, JWK}: public half for
%% asymmetric, the shared secret for symmetric.
-spec verification_keys() -> [{binary(), jose_jwk:key()}].
verification_keys() ->
    try ets:lookup(?TAB, verifying) of
        [{verifying, Keys}] -> Keys;
        [] -> []
    catch
        error:badarg -> []
    end.

%% Public JWK maps for the JWKS endpoint. Asymmetric keys only — a symmetric
%% key has no publishable half.
-spec jwks() -> [map()].
jwks() ->
    try ets:lookup(?TAB, jwks) of
        [{jwks, Maps}] -> Maps;
        [] -> []
    catch
        error:badarg -> []
    end.

%% Operator-triggered rotation: mint a new active key and retire the current
%% one with a grace window covering outstanding access tokens.
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

%% ---- config ----

%% {Algorithm, SourceModule, SourceOpts}. A bad signing_alg fails fast at
%% boot with a clear reason rather than a mysterious later crash.
config() ->
    Configured = cx_config:get(cx_auth, signing_alg, ?DEFAULT_ALG),
    Alg =
        case cx_jws_alg:from_config(Configured) of
            {ok, A} -> A;
            {error, unknown_alg} -> error({unknown_signing_alg, Configured})
        end,
    Source = cx_config:get(cx_auth, signing_source, ?DEFAULT_SOURCE),
    Opts = cx_config:get(cx_auth, signing_source_opts, #{}),
    {Alg, Source, Opts}.

%% ---- issuer transport guard ----

%% Never mint tokens whose iss is a plain-http URL in production. Mirrors the
%% cx_jwks_cache guard: the allow_insecure_jwks dev flag also permits an http
%% issuer; production leaves it false and must use https.
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

%% ---- lifecycle ----

ensure_active() ->
    case active_keys(load_all()) of
        [] ->
            {Alg, Source, Opts} = config(),
            _ = generate(Alg, Source, Opts),
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
        jose_jwk:from_map(Signer#cx_signing_key.private_jwk),
        cx_jws_alg:jws_name(alg_of(Signer))
    }),
    true = ets:insert(?TAB, {verifying, [verify_key(R) || R <- Rows]}),
    true = ets:insert(?TAB, {jwks, [jwks_entry(R) || R <- Rows, has_public(R)]}),
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

%% Asymmetric -> verify with the public half; symmetric -> the shared secret
%% (private_jwk) is the verification key.
verify_key(#cx_signing_key{kid = Kid, public_jwk = undefined, private_jwk = Priv}) ->
    {Kid, jose_jwk:from_map(Priv)};
verify_key(#cx_signing_key{kid = Kid, public_jwk = Pub}) ->
    {Kid, jose_jwk:from_map(Pub)}.

has_public(#cx_signing_key{public_jwk = undefined}) -> false;
has_public(#cx_signing_key{}) -> true.

jwks_entry(#cx_signing_key{kid = Kid, public_jwk = Pub} = Rec) when is_map(Pub) ->
    Pub#{<<"kid">> => Kid, <<"alg">> => cx_jws_alg:jws_name(alg_of(Rec)), <<"use">> => <<"sig">>}.

%% Narrow the persisted atom() back into the algorithm() enumeration (and
%% catch a corrupted row loudly rather than mis-sign).
alg_of(#cx_signing_key{alg = Alg}) ->
    case cx_jws_alg:from_config(Alg) of
        {ok, A} -> A;
        {error, unknown_alg} -> error({corrupt_key_alg, Alg})
    end.

load_all() ->
    cx_store:list(cx_signing_key, cx_patterns:signing_keys()).

generate(Alg, Source, Opts) ->
    Rec = build_key(Alg, Source, Opts),
    ok = cx_store:tx(fun() -> mnesia:write(Rec) end),
    Rec.

do_rotate() ->
    {Alg, Source, Opts} = config(),
    New = build_key(Alg, Source, Opts),
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

build_key(Alg, Source, Opts) ->
    JWK = Source:create(Alg, Opts),
    Kid = cx_id:new(),
    {_, PrivMap} = jose_jwk:to_map(JWK),
    Now = cx_time:now_ms(),
    #cx_signing_key{
        kid = Kid,
        alg = Alg,
        private_jwk = PrivMap,
        public_jwk = public_map(Alg, JWK),
        status = active,
        created_at = Now,
        not_after = undefined
    }.

%% Only asymmetric keys have a publishable public half.
public_map(Alg, JWK) ->
    case cx_jws_alg:kind(Alg) of
        asymmetric ->
            {_, PubMap} = jose_jwk:to_public_map(JWK),
            PubMap;
        symmetric ->
            undefined
    end.
