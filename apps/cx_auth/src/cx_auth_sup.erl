-module(cx_auth_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    %% The JWKS cache exists for a live external IdP; the signing-key manager
    %% for the built-in issuer (key_source = local). Static key sources
    %% (tests, dev) need no process at all.
    ChildSpecs =
        case application:get_env(cx_auth, key_source) of
            {ok, {jwks, _Url}} ->
                [#{id => cx_jwks_cache, start => {cx_jwks_cache, start_link, []}}];
            {ok, local} ->
                [#{id => cx_signing_keys, start => {cx_signing_keys, start_link, []}}];
            _ ->
                []
        end,
    {ok, {SupFlags, ChildSpecs}}.
