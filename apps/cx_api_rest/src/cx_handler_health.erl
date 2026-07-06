-module(cx_handler_health).

-export([init/2]).

init(Req0, Opts) ->
    Req = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        cx_json:encode(#{<<"status">> => <<"ok">>}),
        Req0
    ),
    {ok, Req, Opts}.
