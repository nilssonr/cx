-module(cx_openapi_tests).

%% Drift guard: every /api route the router serves must be documented in
%% openapi.yaml. This proves path coverage only — not methods or field-level
%% schema, which stay hand-maintained and are anchored by cx_api_rest_SUITE.
%%
%% Dependency-free by design: rather than parse YAML, it asserts each derived
%% path template appears as a YAML mapping key (the path followed by ':').
%% A shorter path never matches inside a longer one because the longer path
%% has '/' where the shorter has its ':' terminator.

-include_lib("eunit/include/eunit.hrl").

every_api_route_is_documented_test() ->
    Spec = read_spec(),
    Templates = lists:flatmap(fun templates/1, api_paths()),
    Missing = [T || T <- Templates, binary:match(Spec, <<T/binary, ":">>) =:= nomatch],
    ?assertEqual([], Missing).

-spec read_spec() -> binary().
read_spec() ->
    case code:priv_dir(cx_api_rest) of
        Dir when is_list(Dir) ->
            {ok, Bin} = file:read_file(filename:join(Dir, "openapi.yaml")),
            Bin;
        _ ->
            error(priv_dir_unavailable)
    end.

%% Router path patterns under /api, excluding the WebSocket (in-band auth,
%% not expressible in OpenAPI). Health (/healthz) is excluded by the prefix.
-spec api_paths() -> [string()].
api_paths() ->
    [
        Path
     || {Path, Handler, _State} <- cx_rest_routes:routes(),
        lists:prefix("/api/", Path),
        Handler =/= cx_handler_socket
    ].

%% A cowboy path pattern -> one or two OpenAPI path templates. An optional
%% trailing segment "[/:id]" expands to both the collection and the item path.
-spec templates(string()) -> [binary()].
templates(Path0) ->
    Path = list_to_binary(Path0),
    case binary:split(Path, <<"[">>) of
        [Base, Rest] ->
            Inner = binary:part(Rest, 0, byte_size(Rest) - 1),
            [colonize(Base), colonize(<<Base/binary, Inner/binary>>)];
        [Whole] ->
            [colonize(Whole)]
    end.

%% ":name" path segments become "{name}"; everything else is verbatim.
-spec colonize(binary()) -> binary().
colonize(Bin) ->
    Segments = binary:split(Bin, <<"/">>, [global]),
    iolist_to_binary(lists:join(<<"/">>, [segment(S) || S <- Segments])).

-spec segment(binary()) -> binary().
segment(<<":", Name/binary>>) -> <<"{", Name/binary, "}">>;
segment(Segment) -> Segment.
