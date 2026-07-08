-module(cx_oauth_error).

%% OAuth 2.0 error responses (RFC 6749 §5.2) — a flat {"error": code} JSON
%% body, distinct from the RFC 9457 problem+json that cx_handler:problem/1
%% emits for the domain API. invalid_client is a 401 (client authentication
%% failed); everything else is a 400.

-export([status/1, body/1]).

-spec status(cx_oauth:error()) -> 400 | 401.
status(invalid_client) -> 401;
status(_Error) -> 400.

-spec body(cx_oauth:error()) -> map().
body(Error) ->
    #{<<"error">> => atom_to_binary(Error)}.
