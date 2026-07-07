-module(cx_jws_alg).

%% The finite set of JWS algorithms cx can issue with, as atoms — a closed
%% enumeration, so a registry (plain functions), NOT a behaviour. One place
%% that knows each algorithm's JWS header name, its key kind, and how to mint
%% a fresh key of the right type; every other module speaks the atom. This is
%% the "change the alg from an atom" seam.
%%
%% EC (es256/es384/es512) is deliberately absent: jose_jwk:to_public_map/1
%% crashes on EC keys in the current jose/OTP build, so we cannot publish an
%% EC JWKS entry yet. Add them here once that is fixed — the union is the one
%% place to change.

-export([from_config/1, jws_name/1, kind/1, generate/2]).
-export_type([algorithm/0]).

-type algorithm() ::
    rs256
    | rs384
    | rs512
    | ps256
    | ps384
    | ps512
    | eddsa
    | hs256
    | hs384
    | hs512.

%% Validate a config value into the enumeration (fail-fast at boot on typos).
-spec from_config(term()) -> {ok, algorithm()} | {error, unknown_alg}.
from_config(rs256) -> {ok, rs256};
from_config(rs384) -> {ok, rs384};
from_config(rs512) -> {ok, rs512};
from_config(ps256) -> {ok, ps256};
from_config(ps384) -> {ok, ps384};
from_config(ps512) -> {ok, ps512};
from_config(eddsa) -> {ok, eddsa};
from_config(hs256) -> {ok, hs256};
from_config(hs384) -> {ok, hs384};
from_config(hs512) -> {ok, hs512};
from_config(_) -> {error, unknown_alg}.

%% The JWS "alg" header value.
-spec jws_name(algorithm()) -> binary().
jws_name(rs256) -> <<"RS256">>;
jws_name(rs384) -> <<"RS384">>;
jws_name(rs512) -> <<"RS512">>;
jws_name(ps256) -> <<"PS256">>;
jws_name(ps384) -> <<"PS384">>;
jws_name(ps512) -> <<"PS512">>;
jws_name(eddsa) -> <<"EdDSA">>;
jws_name(hs256) -> <<"HS256">>;
jws_name(hs384) -> <<"HS384">>;
jws_name(hs512) -> <<"HS512">>.

%% Asymmetric keys have a publishable public half (JWKS); symmetric keys do
%% not, and are a shared-secret liability outside dev/lab.
-spec kind(algorithm()) -> asymmetric | symmetric.
kind(hs256) -> symmetric;
kind(hs384) -> symmetric;
kind(hs512) -> symmetric;
kind(_) -> asymmetric.

%% Mint a fresh key of the right type for the algorithm. rs*/ps* -> RSA,
%% eddsa -> Ed25519, hs* -> a random octet secret (usually you want a FIXED
%% secret via cx_signing_key_static in dev instead of a random per-boot one).
-spec generate(algorithm(), map()) -> jose_jwk:key().
generate(Alg, Opts) when
    Alg =:= rs256; Alg =:= rs384; Alg =:= rs512; Alg =:= ps256; Alg =:= ps384; Alg =:= ps512
->
    jose_jwk:generate_key({rsa, maps:get(rsa_bits, Opts, 2048)});
generate(eddsa, _Opts) ->
    jose_jwk:generate_key({okp, 'Ed25519'});
generate(Alg, Opts) when Alg =:= hs256; Alg =:= hs384; Alg =:= hs512 ->
    jose_jwk:generate_key({oct, maps:get(oct_bytes, Opts, 32)}).
