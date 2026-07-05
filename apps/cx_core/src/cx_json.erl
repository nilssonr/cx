-module(cx_json).

%% Thin wrapper over OTP's stdlib json module (OTP 27+). One place for
%% cx's JSON conventions: binary keys everywhere, decode errors become a
%% value instead of an exception, encode accepts the atoms produced by
%% our to_map functions (null, true, false).

-export([encode/1, decode/1, undef_to_null/1]).

%% dynamic(): callers pass maps built from records; json:encode's
%% encode_value() is structurally satisfied but not provable for term().
-spec encode(eqwalizer:dynamic()) -> binary().
encode(Term) ->
    iolist_to_binary(json:encode(Term)).

%% Accepts term() (callers hand us whatever arrived off the wire) and
%% returns dynamic() so decoded maps destructure without ceremony.
-spec decode(term()) -> {ok, eqwalizer:dynamic()} | {error, {invalid, json}}.
decode(Bin) when is_binary(Bin) ->
    try
        {ok, json:decode(Bin)}
    catch
        _:_ -> {error, {invalid, json}}
    end;
decode(_) ->
    {error, {invalid, json}}.

%% JSON-map convention: absent optional values encode as null.
-spec undef_to_null(T | undefined) -> T | null.
undef_to_null(undefined) -> null;
undef_to_null(V) -> V.
