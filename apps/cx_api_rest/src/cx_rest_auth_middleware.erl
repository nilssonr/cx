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
execute(Req, Env = #{handler_opts := Opts}) ->
    Authorization = cowboy_req:header(<<"authorization">>, Req, <<>>),
    case cx_auth:authenticate(Authorization) of
        {ok, Context} ->
            {ok, Req, Env#{handler_opts => Opts#{context => Context}}};
        {error, unauthorized} ->
            Req1 = cowboy_req:reply(
                401,
                #{<<"content-type">> => <<"application/json">>},
                cx_json:encode(#{<<"error">> => <<"unauthorized">>}),
                Req
            ),
            {stop, Req1}
    end.
