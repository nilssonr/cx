-module(cx_presence_state).

%% The product's collaboration-presence vocabulary — sibling of cx_media
%% and under the same charter: states are hard-coded product concepts
%% (each drives distinct UI treatment in the agent app), never tenant
%% data. The free-text escape valve is the presence *message*, exactly
%% as properties are for open_media. online/away are also the automatic
%% outputs of the presence engine; all six are legal manual choices.

-export([all/0, is_valid/1]).

-spec all() -> [binary()].
all() ->
    [
        <<"online">>,
        <<"away">>,
        <<"busy">>,
        <<"dnd">>,
        <<"offline">>,
        <<"out_of_office">>
    ].

-spec is_valid(term()) -> boolean().
is_valid(State) ->
    lists:member(State, all()).
