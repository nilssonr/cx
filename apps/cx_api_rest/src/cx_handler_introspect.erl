-module(cx_handler_introspect).

%% POST /introspect — RFC 7662 token introspection. Reads a form body and
%% authenticates its own client (Basic / client_secret_post) — required, to
%% block token scanning — so it is exempt from cx_rest_auth_middleware. Returns
%% the token's `active` status plus its standard claims. Introspection logic
%% lives in cx_oauth. Cache-Control: no-store on every response (RFC 6749 §5.1).

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
    Params = cx_client_auth:params(maps:from_list(Form), Req1),
    case cx_oauth:introspect(Params) of
        {ok, Response} -> reply_json(200, #{}, Response, Req1);
        {error, Error} -> reply_error(Error, Req1)
    end.

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
