-module(cx_auth_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    %% The JWKS cache only exists for a live IdP; static key sources
    %% (tests, dev without Zitadel) need no process at all.
    ChildSpecs = case application:get_env(cx_auth, key_source) of
        {ok, {jwks, _Url}} ->
            [#{id => cx_jwks_cache, start => {cx_jwks_cache, start_link, []}}];
        _ ->
            []
    end,
    {ok, {SupFlags, ChildSpecs}}.
