-module(cx_id).

-export([new/0]).

-spec new() -> binary().
new() ->
    <<A:48, _:4, B:12, _:2, C:62>> = crypto:strong_rand_bytes(16),
    <<TL:32, TM:16, TH:16, CS:16, N:48>> = <<A:48, 4:4, B:12, 2:2, C:62>>,
    iolist_to_binary(
        io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
                      [TL, TM, TH, CS, N])).
