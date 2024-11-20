-module(cx_config_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 1,
        period => 5
    },
    ChildSpecs = [
        {
            cx_not_ready_reason_server,
            {cx_not_ready_reason_server, start_link, []},
            permanent,
            5000,
            worker,
            [cx_not_ready_reason_server]
        },
        {
            cx_tenant_server,
            {cx_tenant_server, start_link, []},
            permanent,
            5000,
            worker,
            [cx_tenant_server]
        },
        {
            cx_skill_server,
            {cx_skill_server, start_link, []},
            permanent,
            5000,
            worker,
            [cx_skill_server]
        },
        {
            cx_user_server,
            {cx_user_server, start_link, []},
            permanent,
            5000,
            worker,
            [cx_user_server]
        },
        {
            cx_service_group_server,
            {cx_service_group_server, start_link, []},
            permanent,
            5000,
            worker,
            [cx_service_group_server]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
