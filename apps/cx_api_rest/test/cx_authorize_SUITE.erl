-module(cx_authorize_SUITE).

%% Full-stack e2e for the interactive login: GET /authorize renders the login
%% page, POST authenticates + issues a code (single-tenant auto-select), and
%% the code is exchanged at /token for tokens — proving authorization_code end
%% to end. Real httpc with manual cookie handling; key_source = local.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("cx_core/include/cx_core.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([login_page_renders/1, unknown_client_renders_error/1, login_to_code_to_token/1]).

-define(VERIFIER, <<"test-verifier-0123456789-abcdefghijklmnopqrst">>).

all() ->
    [login_page_renders, unknown_client_renders_error, login_to_code_to_token].

init_per_suite(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    set(cx_core, mnesia_dir, filename:join(PrivDir, "mnesia")),
    set(cx_api_rest, port, 0),
    set(cx_auth, issuer, <<"https://issuer.test">>),
    set(cx_auth, audiences, [<<"cx-api">>]),
    set(cx_auth, allow_insecure_jwks, true),
    set(cx_auth, key_source, local),
    set(cx_auth, signing_alg, rs256),
    set(cx_auth, signing_source, cx_signing_key_generated),
    set(cx_auth, signing_source_opts, #{rsa_bits => 1024}),
    set(cx_auth, platform_admin_subjects, []),
    set(cx_auth, first_party_clients, [
        #{
            client_id => <<"spa">>,
            type => public,
            grant_types => [<<"authorization_code">>, <<"refresh_token">>],
            redirect_uris => [<<"https://app/cb">>],
            scopes => [<<"openid">>]
        }
    ]),
    {ok, _} = application:ensure_all_started(cx_api_rest),
    {ok, _} = application:ensure_all_started(inets),
    %% a normal user (not a platform admin) with exactly one tenant membership
    ok = cx_identity:ensure_seed(#{
        subject => <<"alice-sub">>, email => <<"alice@example.test">>, password => <<"pw-alice">>
    }),
    Now = cx_time:now_ms(),
    ok = cx_store:tx(fun() ->
        mnesia:write(#cx_tenant{
            id = <<"t1">>,
            name = <<"Tenant One">>,
            status = active,
            created_at = Now,
            updated_at = Now
        }),
        mnesia:write(#cx_user{
            key = {<<"t1">>, cx_id:new()},
            subject = <<"alice-sub">>,
            name = <<"Alice">>,
            email = <<"alice@example.test">>,
            role_ids = [],
            skills = #{},
            routing_profile_id = undefined,
            status = active,
            created_at = Now,
            updated_at = Now
        })
    end),
    Port = ranch:get_port(cx_http),
    [{port, Port} | Config].

end_per_suite(_Config) ->
    application:stop(cx_api_rest),
    application:stop(cx_router),
    application:stop(cx_auth),
    application:stop(cx_core),
    application:stop(mnesia),
    ok.

set(App, Key, Value) ->
    ok = application:set_env(App, Key, Value, [{persistent, true}]).

login_page_renders(Config) ->
    {Status, Headers, Body} = req(get, "/authorize?" ++ authorize_query(#{}), [], <<>>, Config),
    ?assertEqual(200, Status),
    ?assertEqual("text/html; charset=utf-8", header("content-type", Headers)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Sign in">>)),
    ?assertNotEqual(undefined, cookie("cx_csrf", Headers)).

unknown_client_renders_error(Config) ->
    %% a bad client_id must render an error page, never redirect
    {Status, _Headers, Body} =
        req(
            get,
            "/authorize?" ++ authorize_query(#{<<"client_id">> => <<"ghost">>}),
            [],
            <<>>,
            Config
        ),
    ?assertEqual(400, Status),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Unknown client">>)).

login_to_code_to_token(Config) ->
    %% 1. GET the login page, capture the CSRF cookie
    {200, GetHeaders, _} = req(get, "/authorize?" ++ authorize_query(#{}), [], <<>>, Config),
    Csrf = cookie("cx_csrf", GetHeaders),
    ?assert(is_binary(Csrf)),
    %% 2. POST credentials — single tenant auto-selects -> 302 with the code
    Form = qs(
        [
            {<<"email">>, <<"alice@example.test">>},
            {<<"password">>, <<"pw-alice">>},
            {<<"csrf">>, Csrf}
            | authorize_pairs(#{})
        ]
    ),
    Cookie = [{"cookie", "cx_csrf=" ++ binary_to_list(Csrf)}],
    {302, RedirHeaders, _} = req(post, "/authorize", Cookie, Form, Config),
    Location = list_to_binary(header("location", RedirHeaders)),
    #{query := Query} = uri_string:parse(Location),
    Pairs = uri_string:dissect_query(Query),
    true = is_list(Pairs),
    Returned = maps:from_list(Pairs),
    ?assertEqual(<<"xyz-state">>, maps:get(<<"state">>, Returned)),
    ?assertEqual(<<"https://issuer.test">>, maps:get(<<"iss">>, Returned)),
    Code = maps:get(<<"code">>, Returned),
    ?assert(is_binary(Code)),
    %% 3. exchange the code at /token
    Token = qs([
        {<<"grant_type">>, <<"authorization_code">>},
        {<<"code">>, Code},
        {<<"code_verifier">>, ?VERIFIER},
        {<<"redirect_uri">>, <<"https://app/cb">>},
        {<<"client_id">>, <<"spa">>}
    ]),
    {TokenStatus, _, TokenBody} = req(post, "/token", [], Token, Config),
    ?assertEqual(200, TokenStatus),
    {ok, TokenMap} = cx_json:decode(TokenBody),
    ?assert(is_binary(maps:get(<<"access_token">>, TokenMap))),
    ?assert(is_binary(maps:get(<<"id_token">>, TokenMap))),
    ?assert(is_binary(maps:get(<<"refresh_token">>, TokenMap))).

%% ---- helpers ----

authorize_query(Overrides) ->
    binary_to_list(qs(authorize_pairs(Overrides))).

%% compose_query returns iodata for valid pairs; narrow it to a binary.
qs(Pairs) ->
    case uri_string:compose_query(Pairs) of
        {error, _, _} -> <<>>;
        Encoded -> iolist_to_binary(Encoded)
    end.

authorize_pairs(Overrides) ->
    Challenge = base64:encode(crypto:hash(sha256, ?VERIFIER), #{mode => urlsafe, padding => false}),
    Defaults = #{
        <<"client_id">> => <<"spa">>,
        <<"redirect_uri">> => <<"https://app/cb">>,
        <<"response_type">> => <<"code">>,
        <<"scope">> => <<"openid">>,
        <<"state">> => <<"xyz-state">>,
        <<"code_challenge">> => Challenge,
        <<"code_challenge_method">> => <<"S256">>,
        <<"nonce">> => <<"n-1">>
    },
    maps:to_list(maps:merge(Defaults, Overrides)).

req(Method, Path, Headers, Body, Config) ->
    Port = proplists:get_value(port, Config),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
    Request =
        case Method of
            get -> {Url, Headers};
            post -> {Url, Headers, "application/x-www-form-urlencoded", Body}
        end,
    {ok, {{_, Status, _}, RespHeaders, RespBody}} =
        httpc:request(Method, Request, [{autoredirect, false}], [{body_format, binary}]),
    {Status, RespHeaders, RespBody}.

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> Value;
        false -> undefined
    end.

%% Extract a cookie value from the Set-Cookie response headers.
cookie(Name, Headers) ->
    find_cookie(Name, [V || {"set-cookie", V} <- Headers]).

find_cookie(_Name, []) ->
    undefined;
find_cookie(Name, [Setter | Rest]) ->
    case string:split(Setter, "=") of
        [Cookie, ValueAttrs] when Cookie =:= Name ->
            [Value | _] = string:split(ValueAttrs, ";"),
            list_to_binary(Value);
        _ ->
            find_cookie(Name, Rest)
    end.
