-module(cx_time).

-export([now_ms/0]).

-spec now_ms() -> integer().
now_ms() ->
    erlang:system_time(millisecond).
