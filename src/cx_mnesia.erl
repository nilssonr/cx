-module(cx_mnesia).

-include("include/cx_config.hrl").

-export([initialize/0, create_id/0]).

initialize() ->
    mnesia:create_schema([node()]),
    mnesia:start(),
    create_table(cx_not_ready_reason, record_info(fields, cx_not_ready_reason)),
    create_table(cx_service_group, record_info(fields, cx_service_group)),
    create_table(cx_skill, record_info(fields, cx_skill)),
    create_table(cx_tenant, record_info(fields, cx_tenant)),
    create_table(cx_user, record_info(fields, cx_user)).

create_table(Name, Attributes) ->
    case mnesia:create_table(Name, [{attributes, Attributes}, {disc_copies, [node()]}]) of
        {atomic, ok} -> {ok, created};
        {aborted, {already_exists, Name}} -> {ok, already_exists};
        {aborted, Reason} -> {error, Reason}
    end.

create_id() ->
    uuid:uuid_to_string(uuid:get_v4()).
