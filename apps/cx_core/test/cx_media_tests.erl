-module(cx_media_tests).

-include_lib("eunit/include/eunit.hrl").

valid_test() ->
    ?assert(cx_media:is_valid(<<"voice">>)),
    ?assert(cx_media:is_valid(<<"open_media">>)),
    ?assertNot(cx_media:is_valid(<<"carrier_pigeon">>)),
    ?assertNot(cx_media:is_valid(voice)),
    ?assertNot(cx_media:is_valid(undefined)).

all_are_binaries_test() ->
    ?assert(lists:all(fun is_binary/1, cx_media:all())).
