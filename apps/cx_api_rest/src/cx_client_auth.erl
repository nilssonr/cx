-module(cx_client_auth).

%% Resolve OAuth client credentials from a request. HTTP Basic, when present,
%% takes precedence over client_id/client_secret in the form body
%% (client_secret_post). Shared by the client-authenticated endpoints /token,
%% /revoke and /introspect; the grant/revocation logic in cx_oauth reads the
%% merged client_id/client_secret from the returned params.

-export([params/2]).

-spec params(map(), cowboy_req:req()) -> map().
params(Form, Req) ->
    case basic_credentials(cowboy_req:header(<<"authorization">>, Req)) of
        {ok, ClientId, Secret} ->
            Form#{<<"client_id">> => ClientId, <<"client_secret">> => Secret};
        none ->
            Form
    end.

-spec basic_credentials(binary() | undefined) -> {ok, binary(), binary()} | none.
basic_credentials(<<"Basic ", Encoded/binary>>) ->
    try
        %% split on the FIRST colon; the secret may itself contain colons
        case binary:split(base64:decode(Encoded), <<":">>) of
            [ClientId, Secret] -> {ok, ClientId, Secret};
            _ -> none
        end
    catch
        _:_ -> none
    end;
basic_credentials(_Other) ->
    none.
