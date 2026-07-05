-module(cx_auth).

%% Authentication facade: Bearer token in, #auth_ctx{} out. cx never
%% issues tokens — an external OIDC server (Zitadel in dev) does; cx only
%% validates them and maps claims to a tenant-scoped context. There is no
%% "auth disabled" mode, deliberately.

-include_lib("cx_core/include/cx_core.hrl").

-export([authenticate/1]).

%% term(): transports hand us whatever the authorization header held —
%% anything that isn't a valid Bearer token is simply unauthorized.
-spec authenticate(term()) -> {ok, #auth_ctx{}} | {error, unauthorized}.
authenticate(<<"Bearer ", Token/binary>>) ->
    authenticate(Token);
authenticate(Token) when is_binary(Token), Token =/= <<>> ->
    case cx_auth_jwt:verify(Token) of
        {ok, Claims} -> cx_auth_claims:to_ctx(Claims);
        {error, unauthorized} -> {error, unauthorized}
    end;
authenticate(_) ->
    {error, unauthorized}.
