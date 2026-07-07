-module(cx_signing_key_source).

%% Behaviour: how signing-key MATERIAL is acquired — the OPEN axis (generate
%% today; PEM/certificate/config-secret later), distinct from cx_jws_alg,
%% which is the CLOSED set of algorithms. The manager (cx_signing_keys) owns
%% the lifecycle (persist, cache, rotate) and delegates acquisition here.
%%
%% v1 boundary: create/2 returns a jose_jwk the manager can hold, cache and
%% rotate — i.e. IN-PROCESS keys only. An HSM/KMS whose private key never
%% leaves the device would need a sign/2 callback instead of create/2; that
%% is a deliberate future extension, not built now (design note).

-callback create(cx_jws_alg:algorithm(), Opts :: map()) -> jose_jwk:key().
