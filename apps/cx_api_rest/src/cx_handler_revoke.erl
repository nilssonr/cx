-module(cx_handler_revoke).

%% POST /revoke — RFC 7009 token revocation. Reads a form body and authenticates
%% its own client (Basic / client_secret_post), so it is exempt from
%% cx_rest_auth_middleware. A client may revoke only its own refresh token;
%% revoking an unknown or already-dead token still returns 200. Revocation logic
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
    case cx_oauth:revoke(Params) of
        {ok, _} -> cowboy_req:reply(200, headers(#{}), <<>>, Req1);
        {error, Error} -> reply_error(Error, Req1)
    end.

reply_error(Error, Req) ->
    Status = cx_oauth_error:status(Error),
    Extra =
        case Status of
            401 -> #{<<"www-authenticate">> => <<"Basic">>};
            _ -> #{}
        end,
    Headers = maps:merge(headers(Extra), #{<<"content-type">> => <<"application/json">>}),
    cowboy_req:reply(Status, Headers, cx_json:encode(cx_oauth_error:body(Error)), Req).

headers(Extra) ->
    maps:merge(?NO_STORE, Extra).
