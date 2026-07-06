-module(cx_params).

%% Validation helpers for params maps (binary keys, as produced by JSON
%% decoding). All errors are {error, {invalid, FieldName}} → 422 upstream.

-export([
    require_binary/2,
    optional_binary/3,
    optional_boolean/3,
    optional_integer/3,
    optional_atom/4,
    optional_map/3,
    optional_list/3
]).

-spec require_binary(map(), binary()) -> {ok, binary()} | {error, {invalid, binary()}}.
require_binary(Params, Key) ->
    case Params of
        #{Key := V} when is_binary(V), V =/= <<>> -> {ok, V};
        _ -> {error, {invalid, Key}}
    end.

-spec optional_binary(map(), binary(), Default) ->
    {ok, binary() | Default} | {error, {invalid, binary()}}.
optional_binary(Params, Key, Default) ->
    case Params of
        #{Key := V} when is_binary(V) -> {ok, V};
        #{Key := _} -> {error, {invalid, Key}};
        _ -> {ok, Default}
    end.

-spec optional_boolean(map(), binary(), Default) ->
    {ok, boolean() | Default} | {error, {invalid, binary()}}.
optional_boolean(Params, Key, Default) ->
    case Params of
        #{Key := V} when is_boolean(V) -> {ok, V};
        #{Key := _} -> {error, {invalid, Key}};
        _ -> {ok, Default}
    end.

-spec optional_integer(map(), binary(), Default) ->
    {ok, non_neg_integer() | Default} | {error, {invalid, binary()}}.
optional_integer(Params, Key, Default) ->
    case Params of
        #{Key := V} when is_integer(V), V >= 0 -> {ok, V};
        #{Key := _} -> {error, {invalid, Key}};
        _ -> {ok, Default}
    end.

%% Accepts a binary naming one of Allowed atoms, e.g. <<"open">> -> open.
%% The unconstrained type variable preserves the caller's literal union
%% ('open' | 'closed') through the filter — hence the comparison via
%% binary_to_existing_atom instead of converting the candidates.
-spec optional_atom(map(), binary(), [A], Default) ->
    {ok, A | Default} | {error, {invalid, binary()}}.
optional_atom(Params, Key, Allowed, Default) ->
    case Params of
        #{Key := V} when is_binary(V) ->
            try binary_to_existing_atom(V, utf8) of
                Atom ->
                    case lists:filter(fun(A) -> A =:= Atom end, Allowed) of
                        [A] -> {ok, A};
                        [] -> {error, {invalid, Key}}
                    end
            catch
                error:badarg -> {error, {invalid, Key}}
            end;
        #{Key := _} ->
            {error, {invalid, Key}};
        _ ->
            {ok, Default}
    end.

-spec optional_map(map(), binary(), Default) ->
    {ok, map() | Default} | {error, {invalid, binary()}}.
optional_map(Params, Key, Default) ->
    case Params of
        #{Key := V} when is_map(V) -> {ok, V};
        #{Key := _} -> {error, {invalid, Key}};
        _ -> {ok, Default}
    end.

-spec optional_list(map(), binary(), Default) ->
    {ok, list() | Default} | {error, {invalid, binary()}}.
optional_list(Params, Key, Default) ->
    case Params of
        #{Key := V} when is_list(V) -> {ok, V};
        #{Key := _} -> {error, {invalid, Key}};
        _ -> {ok, Default}
    end.
