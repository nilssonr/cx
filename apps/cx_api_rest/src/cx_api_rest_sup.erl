-module(cx_api_rest_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Port = application:get_env(cx_api_rest, port, 8080),
    Ip = application:get_env(cx_api_rest, ip, {0, 0, 0, 0}),
    Acceptors = application:get_env(cx_api_rest, acceptors, 10),
    TransOpts = #{
        socket_opts => [{port, Port}, {ip, Ip}],
        num_acceptors => Acceptors
    },
    ProtoOpts = #{
        env => #{dispatch => cx_rest_routes:dispatch()},
        middlewares => [
            cowboy_router,
            cx_rest_auth_mw,
            cowboy_handler
        ]
    },
    %% ranch child spec directly under our tree: deterministic shutdown
    %% ordering, no detached listener
    Listener = ranch:child_spec(
        cx_http,
        ranch_tcp,
        TransOpts,
        cowboy_clear,
        ProtoOpts
    ),
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    {ok, {SupFlags, [Listener]}}.
