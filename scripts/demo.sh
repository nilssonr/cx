#!/usr/bin/env bash
# End-to-end Open Media walkthrough against a running cx node.
#
# Needs three Bearer tokens (see README "Trying the flow without Zitadel"
# for minting them in the dev shell; tenant claim must be $TENANT_ID for
# the agent/integrator, anything for the boss):
#
#   BOSS_TOKEN        subject in platform_admin_subjects
#   AGENT_TOKEN       subject "demo-agent"
#   INTEGRATOR_TOKEN  subject "demo-integrator"
#   TENANT_ID         the tenant id the agent/integrator tokens carry
#
# Usage: HOST=http://localhost:8080 TENANT_ID=demo-tenant \
#        BOSS_TOKEN=... AGENT_TOKEN=... INTEGRATOR_TOKEN=... scripts/demo.sh
set -euo pipefail

HOST=${HOST:-http://localhost:8080}
: "${TENANT_ID:?}" "${BOSS_TOKEN:?}" "${AGENT_TOKEN:?}" "${INTEGRATOR_TOKEN:?}"

req() { # req TOKEN METHOD PATH [JSON]
    local token=$1 method=$2 path=$3 body=${4:-}
    if [ -n "$body" ]; then
        curl -sfS -X "$method" -H "Authorization: Bearer $token" \
             -H "Content-Type: application/json" -d "$body" "$HOST$path"
    else
        curl -sfS -X "$method" -H "Authorization: Bearer $token" "$HOST$path"
    fi
}

field() { python3 -c "import sys,json;print(json.load(sys.stdin)[\"$1\"])"; }

echo "== health";               curl -sfS "$HOST/healthz"; echo
echo "== create tenant $TENANT_ID"
req "$BOSS_TOKEN" POST /api/v1/tenants \
    "{\"name\":\"Demo\",\"id\":\"$TENANT_ID\"}"; echo

BASE=/api/v1/tenants/$TENANT_ID

echo "== skill + queue (wrapup 3s)"
MEDIA=open_media
SKILL=$(req "$BOSS_TOKEN" POST "$BASE/skills" \
    '{"name":"Permits","levels":[{"rank":1,"name":"trainee"},{"rank":2,"name":"expert"}]}' | field id)
QUEUE=$(req "$BOSS_TOKEN" POST "$BASE/queues" \
    "{\"name\":\"Building permits\",\"wrapup_duration_ms\":3000,
      \"skill_reqs\":[{\"skill_id\":\"$SKILL\",\"min_rank\":1}]}" | field id)
echo "media=$MEDIA skill=$SKILL queue=$QUEUE"

echo "== roles + users (agent and integrator)"
AGENT_ROLE=$(req "$BOSS_TOKEN" POST "$BASE/roles" \
    '{"name":"Agent","permissions":["agent:session:self","agent:ready:self","agent:offers:self","agent:wrapup:self"]}' | field id)
INT_ROLE=$(req "$BOSS_TOKEN" POST "$BASE/roles" \
    '{"name":"Integrator","permissions":["interactions:create","interactions:cancel","interactions:read"]}' | field id)
req "$BOSS_TOKEN" POST "$BASE/users" \
    "{\"name\":\"Demo Agent\",\"email\":\"agent@demo\",\"subject\":\"demo-agent\",
      \"role_ids\":[\"$AGENT_ROLE\"],\"skills\":{\"$SKILL\":2}}" >/dev/null
req "$BOSS_TOKEN" POST "$BASE/users" \
    "{\"name\":\"Demo Integrator\",\"email\":\"int@demo\",\"subject\":\"demo-integrator\",
      \"role_ids\":[\"$INT_ROLE\"]}" >/dev/null
echo ok

echo "== agent session + ready for open_media"
req "$AGENT_TOKEN" POST /api/v1/agent/session '{}'; echo
req "$AGENT_TOKEN" PUT "/api/v1/agent/media/$MEDIA/state" '{"state":"ready"}'

echo "== integrator: put a request on the queue"
IID=$(req "$INTEGRATOR_TOKEN" POST /api/v1/interactions \
    "{\"queue_id\":\"$QUEUE\",\"media_type\":\"$MEDIA\",
      \"properties\":{\"sap_case\":\"0815\",\"note\":\"call me maybe\"}}" | field id)
echo "interaction=$IID"

echo "== agent polls for the offer"
OFFER=""
for _ in $(seq 1 50); do
    OFFER=$(req "$AGENT_TOKEN" GET /api/v1/agent/session \
        | python3 -c 'import sys,json;o=json.load(sys.stdin)["pending_offers"];print(o[0] if o else "")')
    [ -n "$OFFER" ] && break
    sleep 0.1
done
[ -n "$OFFER" ] || { echo "no offer arrived"; exit 1; }
echo "offer=$OFFER"

echo "== accept, verify active, complete"
req "$AGENT_TOKEN" POST "/api/v1/agent/offers/$OFFER/accept"
req "$INTEGRATOR_TOKEN" GET "/api/v1/interactions/$IID"; echo
req "$AGENT_TOKEN" POST "/api/v1/agent/interactions/$IID/complete"
req "$INTEGRATOR_TOKEN" GET "/api/v1/interactions/$IID"; echo

echo "== wrap-up gates the next offer"
IID2=$(req "$INTEGRATOR_TOKEN" POST /api/v1/interactions \
    "{\"queue_id\":\"$QUEUE\",\"media_type\":\"$MEDIA\"}" | field id)
sleep 1
PENDING=$(req "$AGENT_TOKEN" GET /api/v1/agent/session \
    | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["pending_offers"]))')
echo "offers during wrap-up: $PENDING (expected 0)"
[ "$PENDING" = "0" ] || exit 1

echo "== cancel wrap-up -> offer flows"
req "$AGENT_TOKEN" DELETE /api/v1/agent/wrapup
OFFER2=""
for _ in $(seq 1 50); do
    OFFER2=$(req "$AGENT_TOKEN" GET /api/v1/agent/session \
        | python3 -c 'import sys,json;o=json.load(sys.stdin)["pending_offers"];print(o[0] if o else "")')
    [ -n "$OFFER2" ] && break
    sleep 0.1
done
[ -n "$OFFER2" ] || { echo "no offer after wrap-up cancel"; exit 1; }
req "$AGENT_TOKEN" POST "/api/v1/agent/offers/$OFFER2/accept"
req "$AGENT_TOKEN" POST "/api/v1/agent/interactions/$IID2/complete"

echo
echo "demo complete: $IID and $IID2 routed, accepted, completed."
