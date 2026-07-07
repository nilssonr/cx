-module(cx_handler_token).

%% POST /token — the OAuth 2.0 token endpoint. Unlike the JSON/Bearer API,
%% this reads an application/x-www-form-urlencoded body and does its own
%% client authentication (HTTP Basic or client_secret_post), so it is exempt
%% from cx_rest_auth_middleware. All responses carry Cache-Control: no-store
%% (RFC 6749 §5.1). Grant logic lives in cx_oauth; this handler only parses,
%% calls, and replies.

-export([init/2]).

-define(NO_STORE, #{<<"cache-control">> => <<"no-store">>, <<"pragma">> => <<"no-cache">>}).

init(Req0, Opts) ->
    Req =
        case cowboy_req:method(Req0) of
            <<"POST">> -> handle(Req0);
            _ -> cowboy_req:reply(405, headers(#{<<"allow">> => <<"POST">>}), <<>>, Req0)
        end,
    {ok, Req, Opts}.

handle(Req0) ->
    {ok, Form, Req1} = cowboy_req:read_urlencoded_body(Req0),
    Params = merge_client_auth(maps:from_list(Form), Req1),
    case cx_oauth:token(Params) of
        {ok, Response} -> reply_json(200, #{}, Response, Req1);
        {error, Error} -> reply_error(Error, Req1)
    end.

%% HTTP Basic credentials, when present, take precedence over any in the body.
merge_client_auth(Params, Req) ->
    case basic_credentials(cowboy_req:header(<<"authorization">>, Req)) of
        {ok, ClientId, Secret} ->
            Params#{<<"client_id">> => ClientId, <<"client_secret">> => Secret};
        none ->
            Params
    end.

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

reply_error(Error, Req) ->
    Status = cx_oauth_error:status(Error),
    Extra =
        case Status of
            401 -> #{<<"www-authenticate">> => <<"Basic">>};
            _ -> #{}
        end,
    reply_json(Status, Extra, cx_oauth_error:body(Error), Req).

reply_json(Status, Extra, Body, Req) ->
    Headers = maps:merge(headers(Extra), #{<<"content-type">> => <<"application/json">>}),
    cowboy_req:reply(Status, Headers, cx_json:encode(Body), Req).

headers(Extra) ->
    maps:merge(?NO_STORE, Extra).
