-module(cx_auth_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ok = jose:json_module(cx_jose_json),
    case application:get_env(cx_auth, platform_admin_subjects, []) of
        [] ->
            %% legitimate for an established deployment, fatal-in-effect
            %% for a fresh one: without a platform admin the first
            %% tenant can never be created — say so at boot
            logger:warning(
                "cx_auth: platform_admin_subjects is empty — no platform "
                "admin exists; a fresh deployment cannot create its first "
                "tenant until one is configured (config/sys.config)"
            );
        _ ->
            ok
    end,
    cx_auth_sup:start_link().

stop(_State) ->
    ok.
