%%%-------------------------------------------------------------------
%% @doc cx public API
%% @end
%%%-------------------------------------------------------------------

-module(cx_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    start_cowboy(),
    cx_sup:start_link().

stop(_State) ->
    ok.

%%%-------------------------------------------------------------------
%% Internal functions
%%%-------------------------------------------------------------------

start_cowboy() ->
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/api/tenants", cx_tenant_handler, []},
            {"/api/tenants/[...]", cx_tenant_handler, []}
            % {"/api/users", user_handler, []},
            % {"/api/users/[...]", user_handler, []}
        ]}
    ]),
    {ok, _} = cowboy:start_clear(cx_api, [{port, 4000}], #{
        env => #{dispatch => Dispatch}
    }).
