-module(cx_auth_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ok = jose:json_module(cx_jose_json),
    cx_auth_sup:start_link().

stop(_State) ->
    ok.
