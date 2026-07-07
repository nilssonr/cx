-module(cx_signing_key_generated).

%% The production source: generate a fresh key of the configured algorithm's
%% type. The alg-specific "how" lives in cx_jws_alg; this module's identity is
%% the acquisition strategy — "freshly generated" vs (later) loaded-from-PEM
%% or shared-secret.

-behaviour(cx_signing_key_source).

-export([create/2]).

-spec create(cx_jws_alg:algorithm(), map()) -> jose_jwk:key().
create(Alg, Opts) ->
    cx_jws_alg:generate(Alg, Opts).
