-module(cx_config).

%% Typed boundary for application env: config values are dynamic by
%% nature (sys.config is untyped data), so one dynamic() seam here beats
%% scattering term() coercions through every module.

-export([get/3]).

-spec get(atom(), atom(), term()) -> eqwalizer:dynamic().
get(App, Key, Default) ->
    application:get_env(App, Key, Default).
