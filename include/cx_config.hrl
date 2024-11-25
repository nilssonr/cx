-record(cx_not_ready_reason, {
    id :: binary(),
    name :: binary(),
    tenant_id :: binary()
}).

-record(cx_service_group, {
    id :: binary(),
    name :: binary(),
    tenant_id :: binary()
}).

-record(cx_skill, {
    id :: binary(),
    name :: binary(),
    tenant_id :: binary()
}).

-record(cx_tenant, {
    id :: binary(),
    name :: binary()
}).

-record(cx_user, {
    id :: binary(),
    first_name :: binary(),
    last_name :: binary(),
    email_address :: binary(),
    password :: binary(),
    tenant_id :: binary()
}).
