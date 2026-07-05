-module(cx_core_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Schema and tables must exist before anything supervised can touch
    %% them; a failure here must fail the boot, loudly.
    ok = cx_db:init(),
    cx_core_sup:start_link().

stop(_State) ->
    ok.
