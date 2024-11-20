-record(cx_not_ready_reason, {
    id,
    name,
    tenant_id
}).

-record(cx_service_group, {
    id,
    name,
    tenant_id
}).

-record(cx_skill, {
    id,
    name,
    tenant_id
}).

-record(cx_tenant, {
    id,
    name
}).

-record(cx_user, {
    id,
    first_name,
    last_name,
    email_address,
    password,
    tenant_id
}).
