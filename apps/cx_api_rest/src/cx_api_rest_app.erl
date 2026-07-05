-module(cx_api_rest_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    cx_api_rest_sup:start_link().

stop(_State) ->
    ok.
