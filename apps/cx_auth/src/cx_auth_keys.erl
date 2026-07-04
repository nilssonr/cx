-module(cx_auth_keys).

%% Key-source seam: verification code asks for keys and never knows where
%% they came from. {static, JWKMaps} for tests/dev, {jwks, Url} for a live
%% IdP (backed by cx_jwks_cache).

-export([get_keys/0, refresh/0]).

-spec get_keys() -> [{Kid :: binary() | undefined, jose_jwk:key()}].
get_keys() ->
    case application:get_env(cx_auth, key_source) of
        {ok, {static, JWKMaps}} ->
            [{maps:get(<<"kid">>, M, undefined), jose_jwk:from_map(M)}
             || M <- JWKMaps];
        {ok, {jwks, _Url}} ->
            cx_jwks_cache:get_keys();
        undefined ->
            []
    end.

-spec refresh() -> ok.
refresh() ->
    case application:get_env(cx_auth, key_source) of
        {ok, {jwks, _Url}} -> cx_jwks_cache:refresh();
        _ -> ok
    end.
