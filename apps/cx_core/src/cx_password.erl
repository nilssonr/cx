-module(cx_password).

%% Password hashing for local identities. PBKDF2-HMAC-SHA512 via the OTP
%% crypto NIF (crypto:pbkdf2_hmac/5) — native, FIPS-approved, no new
%% dependency and nothing hand-rolled: we iterate a vetted primitive, we do
%% not invent one. Hashes are stored as a self-describing PHC string so the
%% cost — or the whole algorithm, e.g. argon2id later (design D3/§4) — can
%% change without a data migration: verify/2 re-derives from the parameters
%% carried in the stored hash. Lives in cx_core (not cx_auth) so the
%% identity domain can use it without a cx_core -> cx_auth cycle.

-export([hash/1, verify/2, verify_dummy/1]).

-define(DIGEST, sha512).
-define(SALT_BYTES, 16).
-define(DERIVE_BYTES, 64).
-define(DEFAULT_ITERATIONS, 210000).

-spec hash(binary()) -> binary().
hash(Password) when is_binary(Password) ->
    Iterations = iterations(),
    Salt = crypto:strong_rand_bytes(?SALT_BYTES),
    Derived = crypto:pbkdf2_hmac(?DIGEST, Password, Salt, Iterations, ?DERIVE_BYTES),
    encode(Iterations, Salt, Derived).

-spec verify(binary(), binary()) -> boolean().
verify(Password, Phc) when is_binary(Password), is_binary(Phc) ->
    case parse(Phc) of
        {ok, Iterations, Salt, Expected} ->
            Actual = crypto:pbkdf2_hmac(?DIGEST, Password, Salt, Iterations, byte_size(Expected)),
            crypto:hash_equals(Actual, Expected);
        error ->
            false
    end.

%% Run one derivation and return false, so authenticating a non-existent
%% identity costs the same time as a wrong password — no email-enumeration
%% oracle (design §12). Also the sink for a federated identity that has no
%% local credential.
-spec verify_dummy(binary()) -> false.
verify_dummy(Password) when is_binary(Password) ->
    _ = crypto:pbkdf2_hmac(?DIGEST, Password, <<0:(?SALT_BYTES * 8)>>, iterations(), ?DERIVE_BYTES),
    false.

%% ---- internals ----

-spec encode(pos_integer(), binary(), binary()) -> binary().
encode(Iterations, Salt, Derived) ->
    iolist_to_binary([
        <<"$pbkdf2-sha512$i=">>,
        integer_to_binary(Iterations),
        <<"$">>,
        base64:encode(Salt),
        <<"$">>,
        base64:encode(Derived)
    ]).

-spec parse(binary()) -> {ok, pos_integer(), binary(), binary()} | error.
parse(Phc) ->
    case binary:split(Phc, <<"$">>, [global]) of
        [<<>>, <<"pbkdf2-sha512">>, <<"i=", IterBin/binary>>, Salt64, Hash64] ->
            try
                Iterations = binary_to_integer(IterBin),
                true = Iterations > 0,
                {ok, Iterations, base64:decode(Salt64), base64:decode(Hash64)}
            catch
                _:_ -> error
            end;
        _ ->
            error
    end.

-spec iterations() -> pos_integer().
iterations() ->
    cx_config:get(cx_core, password_pbkdf2_iterations, ?DEFAULT_ITERATIONS).
