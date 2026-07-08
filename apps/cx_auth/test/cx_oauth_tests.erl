-module(cx_oauth_tests).

-include_lib("eunit/include/eunit.hrl").

oauth_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            fun client_credentials_flow/0,
            fun refresh_flow/0,
            fun authorization_code_flow/0,
            fun reuse_burns_the_family/0,
            fun unsupported_grant/0,
            fun bad_client_secret/0
        ]
    end}.

setup() ->
    Dir =
        "_build/eunit-mnesia-oauth-" ++
            integer_to_list(erlang:system_time(microsecond)) ++
            "-" ++ integer_to_list(erlang:unique_integer([positive])),
    application:set_env(cx_core, mnesia_dir, Dir),
    application:set_env(cx_auth, issuer, <<"https://issuer.test">>),
    application:set_env(cx_auth, audiences, [<<"cx-api">>]),
    application:set_env(cx_auth, signing_alg, rs256),
    application:set_env(cx_auth, signing_source, cx_signing_key_generated),
    application:set_env(cx_auth, signing_source_opts, #{rsa_bits => 1024}),
    application:set_env(cx_auth, key_source, local),
    %% internal app (public) declared in config; integrator (confidential) in Mnesia
    application:set_env(cx_auth, first_party_clients, [
        #{
            client_id => <<"spa">>,
            type => public,
            grant_types => [<<"authorization_code">>, <<"refresh_token">>],
            redirect_uris => [<<"https://app/cb">>],
            scopes => [<<"openid">>]
        }
    ]),
    {ok, _} = application:ensure_all_started(jose),
    ok = jose:json_module(cx_jose_json),
    ok = cx_db:init(),
    {ok, Pid} = cx_signing_keys:start_link(),
    ok = cx_oauth_client:store(#{
        client_id => <<"svc">>,
        type => confidential,
        secret => <<"svc-secret">>,
        tenant_id => <<"t1">>,
        grant_types => [<<"client_credentials">>],
        scopes => [<<"interactions:read">>]
    }),
    Pid.

cleanup(Pid) ->
    gen_server:stop(Pid),
    application:unset_env(cx_auth, first_party_clients),
    mnesia:stop(),
    ok.

client_credentials_flow() ->
    {ok, Resp} = cx_oauth:token(#{
        <<"grant_type">> => <<"client_credentials">>,
        <<"client_id">> => <<"svc">>,
        <<"client_secret">> => <<"svc-secret">>
    }),
    ?assertEqual(<<"Bearer">>, maps:get(<<"token_type">>, Resp)),
    %% M2M gets no refresh token
    ?assertNot(maps:is_key(<<"refresh_token">>, Resp)),
    %% the access token verifies through the real path; sub = the client id
    {ok, Claims} = cx_auth_jwt:verify(maps:get(<<"access_token">>, Resp)),
    ?assertEqual(<<"svc">>, maps:get(<<"sub">>, Claims)),
    ?assertEqual(<<"t1">>, maps:get(<<"tenant_id">>, Claims)).

refresh_flow() ->
    {Handle, _} = cx_refresh_token:issue(#{
        subject => <<"u1">>, tenant_id => <<"t1">>, client_id => <<"spa">>, scope => [<<"openid">>]
    }),
    {ok, Resp} = cx_oauth:token(refresh_params(Handle)),
    ?assert(is_binary(maps:get(<<"access_token">>, Resp))),
    New = maps:get(<<"refresh_token">>, Resp),
    ?assertNotEqual(Handle, New),
    %% the spent handle is rejected
    ?assertEqual({error, invalid_grant}, cx_oauth:token(refresh_params(Handle))).

authorization_code_flow() ->
    Verifier = <<"verifier-string-that-is-plenty-long-1234567">>,
    Challenge = base64:encode(crypto:hash(sha256, Verifier), #{mode => urlsafe, padding => false}),
    Code = issue_code(Challenge),
    {ok, Resp} = cx_oauth:token(code_params(Code, Verifier)),
    ?assert(is_binary(maps:get(<<"access_token">>, Resp))),
    ?assert(is_binary(maps:get(<<"refresh_token">>, Resp))),
    %% openid scope -> an ID token is issued
    ?assert(is_binary(maps:get(<<"id_token">>, Resp))),
    %% a wrong PKCE verifier fails (fresh code, since consume is single-use)
    ?assertEqual(
        {error, invalid_grant},
        cx_oauth:token(code_params(issue_code(Challenge), <<"wrong-verifier">>))
    ).

reuse_burns_the_family() ->
    {Handle, _} = cx_refresh_token:issue(#{
        subject => <<"u2">>, tenant_id => <<"t1">>, client_id => <<"spa">>, scope => [<<"openid">>]
    }),
    {ok, Resp} = cx_oauth:token(refresh_params(Handle)),
    New = maps:get(<<"refresh_token">>, Resp),
    %% replay the OLD handle -> theft signal
    ?assertEqual({error, invalid_grant}, cx_oauth:token(refresh_params(Handle))),
    %% and the whole family, including the rotated-to token, is now dead
    ?assertEqual({error, invalid_grant}, cx_oauth:token(refresh_params(New))).

unsupported_grant() ->
    ?assertEqual(
        {error, unsupported_grant_type},
        cx_oauth:token(#{<<"grant_type">> => <<"password">>, <<"client_id">> => <<"spa">>})
    ).

bad_client_secret() ->
    ?assertEqual(
        {error, invalid_client},
        cx_oauth:token(#{
            <<"grant_type">> => <<"client_credentials">>,
            <<"client_id">> => <<"svc">>,
            <<"client_secret">> => <<"wrong">>
        })
    ).

%% ---- helpers ----

refresh_params(Handle) ->
    #{
        <<"grant_type">> => <<"refresh_token">>,
        <<"refresh_token">> => Handle,
        <<"client_id">> => <<"spa">>
    }.

issue_code(Challenge) ->
    cx_authorization_code:issue(#{
        client_id => <<"spa">>,
        subject => <<"u1">>,
        tenant_id => <<"t1">>,
        redirect_uri => <<"https://app/cb">>,
        code_challenge => Challenge,
        code_challenge_method => <<"S256">>,
        scope => [<<"openid">>]
    }).

code_params(Code, Verifier) ->
    #{
        <<"grant_type">> => <<"authorization_code">>,
        <<"code">> => Code,
        <<"code_verifier">> => Verifier,
        <<"redirect_uri">> => <<"https://app/cb">>,
        <<"client_id">> => <<"spa">>
    }.
