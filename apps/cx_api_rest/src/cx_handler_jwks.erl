-module(cx_handler_jwks).

%% GET /.well-known/jwks.json — the issuer's public signing keys (RFC 7517).
%% Public halves only; never a private key. Empty when the deployment
%% federates instead of issuing (no local signing keys). Auth-exempt (see
%% cx_rest_auth_middleware): a JWKS is public by definition.

-export([init/2]).

init(Req0, Opts) ->
    Body = cx_json:encode(#{<<"keys">> => cx_signing_keys:jwks()}),
    Req = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        Body,
        Req0
    ),
    {ok, Req, Opts}.
