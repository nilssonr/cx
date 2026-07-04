-module(cx_rest_auth_mw).

%% Cowboy middleware between router and handler: authenticates the Bearer
%% token and injects #auth_ctx{} into the handler opts. Handlers never see
%% unauthenticated requests (except cx_h_health, which bypasses).

-behaviour(cowboy_middleware).

-export([execute/2]).

execute(Req, Env = #{handler := cx_h_health}) ->
    {ok, Req, Env};
execute(Req, Env = #{handler_opts := Opts}) ->
    Authorization = cowboy_req:header(<<"authorization">>, Req, <<>>),
    case cx_auth:authenticate(Authorization) of
        {ok, Ctx} ->
            {ok, Req, Env#{handler_opts => Opts#{ctx => Ctx}}};
        {error, unauthorized} ->
            Req1 = cowboy_req:reply(
                401,
                #{<<"content-type">> => <<"application/json">>},
                cx_json:encode(#{<<"error">> => <<"unauthorized">>}),
                Req
            ),
            {stop, Req1}
    end.
