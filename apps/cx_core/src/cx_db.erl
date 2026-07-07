-module(cx_db).

%% Mnesia bootstrap. Everything single-node about cx lives in this module:
%% clustering later means create_schema/extra_db_nodes/add_table_copy changes
%% here and nowhere else.

-include("cx_core.hrl").

-export([init/0, tables/0]).

-define(WAIT_MS, 30000).

-spec init() -> ok.
init() ->
    Dir = cx_config:get(cx_core, mnesia_dir, "data/mnesia"),
    ok = filelib:ensure_path(Dir),
    ok = ensure_loaded(),
    %% If some environment (rebar3 shell, test runner) already started
    %% mnesia, stop it: the dir must be set and the schema created before
    %% mnesia runs, or it silently uses a ram-only schema elsewhere.
    _ = application:stop(mnesia),
    application:set_env(mnesia, dir, Dir),
    ok = ensure_schema(),
    ok = mnesia:start(),
    lists:foreach(fun ensure_table/1, table_specs()),
    case mnesia:wait_for_tables(tables(), ?WAIT_MS) of
        ok -> ok;
        {timeout, Missing} -> error({mnesia_tables_timeout, Missing});
        {error, Reason} -> error({mnesia_tables_error, Reason})
    end,
    %% after wait_for_tables: add_table_index needs the table LOADED,
    %% not merely known (a pre-existing disc table is not loaded right
    %% after create_table returns already_exists)
    lists:foreach(fun ensure_indexes/1, table_specs()),
    ok.

-spec tables() -> [atom()].
tables() ->
    [Name || {Name, _} <- table_specs()].

ensure_loaded() ->
    case application:load(mnesia) of
        ok -> ok;
        {error, {already_loaded, mnesia}} -> ok
    end.

%% create_schema requires mnesia to be stopped; mnesia is {mnesia, load}
%% in the release (and only loaded above) precisely so this can run first.
ensure_schema() ->
    case mnesia:create_schema([node()]) of
        ok -> ok;
        {error, {_Node, {already_exists, _}}} -> ok;
        {error, Reason} -> error({mnesia_schema_error, Reason})
    end.

ensure_table({Name, Opts}) ->
    case mnesia:create_table(Name, Opts) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, Name}} -> ok;
        {aborted, Reason} -> error({mnesia_table_error, Name, Reason})
    end.

%% create_table is a no-op for a pre-existing table, so an index added
%% to a spec would be silently absent on an existing data dir — and
%% index_read on a missing index crashes. Ensuring indexes separately
%% is schema-additive and idempotent; row-shape migration stays
%% deliberately unsupported.
ensure_indexes({Name, Opts}) ->
    lists:foreach(
        fun(Attribute) ->
            case mnesia:add_table_index(Name, Attribute) of
                {atomic, ok} -> ok;
                {aborted, {already_exists, _, _}} -> ok;
                {aborted, Reason} -> error({mnesia_index_error, Name, Attribute, Reason})
            end
        end,
        proplists:get_value(index, Opts, [])
    ).

table_specs() ->
    Disc = {disc_copies, [node()]},
    Ram = {ram_copies, [node()]},
    [
        {cx_tenant, [{attributes, record_info(fields, cx_tenant)}, {type, set}, Disc]},
        {cx_user, [
            {attributes, record_info(fields, cx_user)},
            {type, set},
            Disc,
            {index, [#cx_user.subject]}
        ]},
        {cx_role, [{attributes, record_info(fields, cx_role)}, {type, set}, Disc]},
        {cx_skill, [{attributes, record_info(fields, cx_skill)}, {type, set}, Disc]},
        {cx_queue, [{attributes, record_info(fields, cx_queue)}, {type, set}, Disc]},
        {cx_routing_profile, [
            {attributes, record_info(fields, cx_routing_profile)}, {type, set}, Disc
        ]},
        {cx_not_ready_reason, [
            {attributes, record_info(fields, cx_not_ready_reason)}, {type, set}, Disc
        ]},
        {cx_qualification_code, [
            {attributes, record_info(fields, cx_qualification_code)}, {type, set}, Disc
        ]},
        {cx_interaction, [
            {attributes, record_info(fields, cx_interaction)},
            {type, set},
            Disc,
            {index, [#cx_interaction.queue_key, #cx_interaction.agent_id]}
        ]},
        {cx_agent_snapshot, [
            {attributes, record_info(fields, cx_agent_snapshot)}, {type, set}, Ram
        ]},
        {cx_presence_declaration, [
            {attributes, record_info(fields, cx_presence_declaration)}, {type, set}, Disc
        ]},
        {cx_presence_effective, [
            {attributes, record_info(fields, cx_presence_effective)}, {type, set}, Ram
        ]},

        %% Issuer-level auth tables (OAuth2/OIDC provider): bare-keyed, not
        %% {TenantId, Id} — the identity/issuer layer above tenants (see
        %% cx_core.hrl). Authorization codes are ephemeral (Ram); provider
        %% sessions are Disc so Remember-me survives a restart.
        {cx_identity, [
            {attributes, record_info(fields, cx_identity)},
            {type, set},
            Disc,
            {index, [#cx_identity.email]}
        ]},
        {cx_oauth_client, [
            {attributes, record_info(fields, cx_oauth_client)},
            {type, set},
            Disc,
            {index, [#cx_oauth_client.tenant_id]}
        ]},
        {cx_signing_key, [
            {attributes, record_info(fields, cx_signing_key)}, {type, set}, Disc
        ]},
        {cx_refresh_token, [
            {attributes, record_info(fields, cx_refresh_token)},
            {type, set},
            Disc,
            {index, [#cx_refresh_token.subject, #cx_refresh_token.session_id]}
        ]},
        {cx_authorization_code, [
            {attributes, record_info(fields, cx_authorization_code)}, {type, set}, Ram
        ]},
        {cx_provider_session, [
            {attributes, record_info(fields, cx_provider_session)},
            {type, set},
            Disc,
            {index, [#cx_provider_session.subject]}
        ]}
    ].
