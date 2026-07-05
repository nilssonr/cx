-module(cx_media).

%% The product's media vocabulary. Media types are hard-coded product
%% concepts — each implies a distinct agent-app UI and product behavior
%% (voice gets a softphone, chat gets a thread view, ...). Customers
%% never define them: integrator/customer extensibility happens through
%% open_media + interaction properties. Adding an entry here is a
%% product decision that ships together with its UI and adapter.

-export([all/0, is_valid/1]).

-spec all() -> [binary()].
all() ->
    [
        <<"voice">>,
        <<"chat">>,
        <<"sms">>,
        <<"email">>,
        <<"open_media">>,
        <<"social_media">>
    ].

-spec is_valid(term()) -> boolean().
is_valid(Media) ->
    lists:member(Media, all()).
