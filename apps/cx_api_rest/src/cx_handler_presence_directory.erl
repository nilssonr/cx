-module(cx_handler_presence_directory).

%% GET /api/v1/presence/directory — effective presence for every active
%% tenant member. Fetch once, then maintain from presence_changed events
%% over the socket.

-export([init/2]).

init(Req0, Opts = #{ctx := Ctx}) ->
    Result =
        case cowboy_req:method(Req0) of
            <<"GET">> -> cx_presence:directory(Ctx);
            _ -> {error, method_not_allowed}
        end,
    {ok, cx_handler:reply(Result, Req0), Opts}.
