-module(cx_rest_auth_middleware).

%% Cowboy middleware between router and handler: authenticates the Bearer
%% token and injects #auth_context{} into the handler opts. Handlers never see
%% unauthenticated requests (except cx_handler_health, which bypasses).

-behaviour(cowboy_middleware).

-export([execute/2]).

execute(Req, Env = #{handler := cx_handler_health}) ->
    {ok, Req, Env};
%% WebSocket handshakes cannot carry Authorization from browsers; the
%% socket authenticates in-band (first frame) through the same cx_auth
%% path — see cx_handler_socket.
execute(Req, Env = #{handler := cx_handler_socket}) ->
    {ok, Req, Env};
%% Docs surface (OpenAPI spec + Scalar UI) is public — cowboy_static is only
%% ever routed here (see cx_rest_routes:docs_routes/0). Do not mount a
%% data-serving cowboy_static route without revisiting this bypass.
execute(Req, Env = #{handler := cowboy_static}) ->
    {ok, Req, Env};
%% OpenID Provider discovery + JWKS are public by definition — no token.
execute(Req, Env = #{handler := cx_handler_jwks}) ->
    {ok, Req, Env};
execute(Req, Env = #{handler := cx_handler_oidc_metadata}) ->
    {ok, Req, Env};
%% The token endpoint authenticates its own client (Basic / client_secret_post).
execute(Req, Env = #{handler := cx_handler_token}) ->
    {ok, Req, Env};
execute(Req, Env = #{handler_opts := Opts}) ->
    Authorization = cowboy_req:header(<<"authorization">>, Req, <<>>),
    case cx_auth:authenticate(Authorization) of
        {ok, Context} ->
            {ok, Req, Env#{handler_opts => Opts#{context => Context}}};
        {error, unauthorized} ->
            {Status, Body} = cx_handler:problem(unauthorized),
            Req1 = cowboy_req:reply(
                Status,
                #{<<"content-type">> => <<"application/problem+json">>},
                cx_json:encode(Body),
                Req
            ),
            {stop, Req1}
    end.
