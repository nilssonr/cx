%%%-------------------------------------------------------------------
%% @doc cx public API
%% @end
%%%-------------------------------------------------------------------

-module(cx_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    cx_sup:start_link().

stop(_State) ->
    ok.

%% internal function
