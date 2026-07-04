-module(cx_jose_json).

%% jose_json adapter backed by OTP's stdlib json module — jose 1.11.x
%% only autodetects third-party JSON libs (jsx, jiffy, thoas, ...) and we
%% carry none. Installed via jose:json_module/1 in cx_auth_app.

-behaviour(jose_json).

-export([decode/1, encode/1]).

decode(Binary) ->
    json:decode(Binary).

encode(Term) ->
    iolist_to_binary(json:encode(Term)).
