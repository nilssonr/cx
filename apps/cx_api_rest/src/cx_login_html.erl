-module(cx_login_html).

%% Server-rendered login + tenant-picker pages for /authorize. Minimal,
%% unbranded HTML built as iolists (cx serves no other HTML). Every dynamic
%% value — the carried authorize params, tenant names, error text — is HTML-
%% escaped: they originate from the client and must never be injected raw.

-export([login_page/3, tenant_picker/3, error_page/1]).

%% The authorize request carried through the forms as hidden fields.
-define(CARRIED, [
    <<"client_id">>,
    <<"redirect_uri">>,
    <<"state">>,
    <<"scope">>,
    <<"code_challenge">>,
    <<"code_challenge_method">>,
    <<"nonce">>,
    <<"response_type">>
]).

-spec login_page(map(), binary(), binary() | undefined) -> iodata().
login_page(AuthReq, Csrf, Error) ->
    page(<<"Sign in">>, [
        error_banner(Error),
        <<"<form method=\"post\" action=\"/authorize\">">>,
        hidden_fields(AuthReq),
        csrf_field(Csrf),
        text_field(<<"email">>, <<"Email">>, <<"email">>),
        text_field(<<"password">>, <<"Password">>, <<"password">>),
        <<"<label class=\"cb\"><input type=\"checkbox\" name=\"remember_me\" value=\"1\"> Remember me</label>">>,
        submit(<<"Sign in">>),
        <<"</form>">>
    ]).

-spec tenant_picker(map(), binary(), [{binary(), binary()}]) -> iodata().
tenant_picker(AuthReq, Csrf, Tenants) ->
    page(<<"Choose tenant">>, [
        <<"<form method=\"post\" action=\"/authorize\">">>,
        <<"<input type=\"hidden\" name=\"step\" value=\"select_tenant\">">>,
        hidden_fields(AuthReq),
        csrf_field(Csrf),
        <<"<label>Tenant</label><select name=\"tenant_id\">">>,
        [tenant_option(Id, Name) || {Id, Name} <- Tenants],
        <<"</select>">>,
        submit(<<"Continue">>),
        <<"</form>">>
    ]).

-spec error_page(binary()) -> iodata().
error_page(Message) ->
    page(<<"Error">>, [<<"<p class=\"err\">">>, escape(Message), <<"</p>">>]).

%% ---- internals ----

page(Title, Body) ->
    [
        <<"<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">">>,
        <<"<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">">>,
        <<"<title>">>,
        escape(Title),
        <<"</title><style>">>,
        css(),
        <<"</style></head><body><main><h1>">>,
        escape(Title),
        <<"</h1>">>,
        Body,
        <<"</main></body></html>">>
    ].

css() ->
    <<
        "body{font-family:system-ui,sans-serif;background:#f4f5f7;margin:0}"
        "main{max-width:22rem;margin:4rem auto;background:#fff;padding:2rem;"
        "border-radius:.5rem;box-shadow:0 1px 4px rgba(0,0,0,.1)}"
        "h1{font-size:1.25rem;margin:0 0 1rem}label{display:block;margin:.75rem 0 .25rem}"
        "input[type=text],input[type=password],select{width:100%;padding:.5rem;"
        "box-sizing:border-box;border:1px solid #ccc;border-radius:.25rem}"
        "label.cb{font-weight:400}label.cb input{width:auto}"
        "button{margin-top:1.25rem;width:100%;padding:.6rem;border:0;border-radius:.25rem;"
        "background:#2563eb;color:#fff;font-size:1rem;cursor:pointer}"
        ".err{background:#fee2e2;color:#991b1b;padding:.6rem;border-radius:.25rem}"
    >>.

error_banner(undefined) -> <<>>;
error_banner(Message) -> [<<"<p class=\"err\">">>, escape(Message), <<"</p>">>].

text_field(Name, Label, Type) ->
    [
        <<"<label for=\"">>,
        Name,
        <<"\">">>,
        Label,
        <<"</label><input type=\"">>,
        Type,
        <<"\" id=\"">>,
        Name,
        <<"\" name=\"">>,
        Name,
        <<"\" required>">>
    ].

csrf_field(Csrf) ->
    [<<"<input type=\"hidden\" name=\"csrf\" value=\"">>, escape(Csrf), <<"\">">>].

hidden_fields(AuthReq) ->
    lists:filtermap(
        fun(Key) ->
            case maps:get(Key, AuthReq, undefined) of
                Value when is_binary(Value) -> {true, hidden(Key, Value)};
                _ -> false
            end
        end,
        ?CARRIED
    ).

hidden(Name, Value) ->
    [
        <<"<input type=\"hidden\" name=\"">>,
        escape(Name),
        <<"\" value=\"">>,
        escape(Value),
        <<"\">">>
    ].

tenant_option(Id, Name) ->
    [<<"<option value=\"">>, escape(Id), <<"\">">>, escape(Name), <<"</option>">>].

submit(Label) ->
    [<<"<button type=\"submit\">">>, escape(Label), <<"</button>">>].

-spec escape(binary()) -> binary().
escape(Bin) ->
    <<<<(escape_char(Char))/binary>> || <<Char>> <= Bin>>.

escape_char($&) -> <<"&amp;">>;
escape_char($<) -> <<"&lt;">>;
escape_char($>) -> <<"&gt;">>;
escape_char($") -> <<"&quot;">>;
escape_char($') -> <<"&#39;">>;
escape_char(Char) -> <<Char>>.
