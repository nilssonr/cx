-module(cx_auth_jwt).

%% JWT verification with jose: signature against the configured key set,
%% issuer, audience, exp/nbf with leeway. Any malformed input is simply
%% unauthorized — never a crash.

-export([verify/1]).

-define(LEEWAY_S, 30).
-define(ALLOWED_ALGS, [
    <<"RS256">>,
    <<"PS256">>,
    <<"ES256">>,
    <<"ES384">>,
    <<"EdDSA">>
]).

-spec verify(binary()) -> {ok, map()} | {error, unauthorized}.
verify(Token) ->
    try
        Protected = jose:decode(jose_jws:peek_protected(Token)),
        Alg = maps:get(<<"alg">>, Protected, undefined),
        true = lists:member(Alg, ?ALLOWED_ALGS),
        Kid = maps:get(<<"kid">>, Protected, undefined),
        case verify_with_keys(candidate_keys(Kid), Alg, Token) of
            {ok, Claims} -> validate_claims(Claims);
            error -> {error, unauthorized}
        end
    catch
        _:_ -> {error, unauthorized}
    end.

%% Keys matching the token's kid; a kid nobody knows forces one refetch
%% (key rotation), a token without kid tries every key.
candidate_keys(Kid) ->
    Keys = cx_auth_keys:get_keys(),
    case select(Kid, Keys) of
        [] when Kid =/= undefined ->
            ok = cx_auth_keys:refresh(),
            select(Kid, cx_auth_keys:get_keys());
        Selected ->
            Selected
    end.

select(undefined, Keys) -> [JWK || {_, JWK} <- Keys];
select(Kid, Keys) -> [JWK || {K, JWK} <- Keys, K =:= Kid].

verify_with_keys([], _Alg, _Token) ->
    error;
verify_with_keys([JWK | Rest], Alg, Token) ->
    case jose_jwt:verify_strict(JWK, [Alg], Token) of
        {true, {jose_jwt, Claims}, _} -> {ok, Claims};
        {false, _, _} -> verify_with_keys(Rest, Alg, Token)
    end.

validate_claims(Claims) ->
    Now = erlang:system_time(second),
    {ok, Issuer} = application:get_env(cx_auth, issuer),
    {ok, Audiences} = application:get_env(cx_auth, audiences),
    Checks = [
        maps:get(<<"iss">>, Claims, undefined) =:= Issuer,
        audience_ok(maps:get(<<"aud">>, Claims, undefined), Audiences),
        expiry_ok(maps:get(<<"exp">>, Claims, undefined), Now),
        not_before_ok(maps:get(<<"nbf">>, Claims, undefined), Now)
    ],
    case lists:all(fun(C) -> C end, Checks) of
        true -> {ok, Claims};
        false -> {error, unauthorized}
    end.

audience_ok(Aud, Audiences) when is_binary(Aud) ->
    lists:member(Aud, Audiences);
audience_ok(Auds, Audiences) when is_list(Auds) ->
    lists:any(fun(A) -> lists:member(A, Audiences) end, Auds);
audience_ok(_, _) ->
    false.

expiry_ok(Exp, Now) when is_integer(Exp) -> Now < Exp + ?LEEWAY_S;
expiry_ok(_, _) -> false.

not_before_ok(undefined, _Now) -> true;
not_before_ok(Nbf, Now) when is_integer(Nbf) -> Now >= Nbf - ?LEEWAY_S;
not_before_ok(_, _) -> false.
