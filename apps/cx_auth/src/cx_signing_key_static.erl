-module(cx_signing_key_static).

%% Dev/lab source: a symmetric key from a FIXED configured secret, so tokens
%% survive restarts with no keypair and no per-boot randomness — the thing
%% that makes local development and lab setups easy.
%%
%% A shared secret is unacceptable in production (anyone holding it forges
%% tokens), so this is restricted to symmetric algorithms; asking for it with
%% an asymmetric alg is a configuration error and fails loudly.

-behaviour(cx_signing_key_source).

-export([create/2]).

-spec create(cx_jws_alg:algorithm(), map()) -> jose_jwk:key().
create(Alg, #{secret := Secret}) when is_binary(Secret) ->
    symmetric = cx_jws_alg:kind(Alg),
    jose_jwk:from_oct(Secret).
