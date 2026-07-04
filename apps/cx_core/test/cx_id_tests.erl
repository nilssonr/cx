-module(cx_id_tests).

-include_lib("eunit/include/eunit.hrl").

format_test() ->
    Id = cx_id:new(),
    ?assertMatch({match, _},
                 re:run(Id, <<"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
                              "[89ab][0-9a-f]{3}-[0-9a-f]{12}$">>)).

uniqueness_test() ->
    Ids = [cx_id:new() || _ <- lists:seq(1, 1000)],
    ?assertEqual(1000, length(lists:usort(Ids))).
