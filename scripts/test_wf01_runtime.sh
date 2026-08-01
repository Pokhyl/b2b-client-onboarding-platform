#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

cd "${PROJECT_DIR}"

: "${WF01_AUTH_HEADER:?Set WF01_AUTH_HEADER to the complete Header Auth value}"

WF01_WEBHOOK_URL=${WF01_WEBHOOK_URL:-http://127.0.0.1:5678/webhook/b2b-onboarding/deal-won}
WF01_POLL_TIMEOUT_SECONDS=${WF01_POLL_TIMEOUT_SECONDS:-60}

TEMP_DIR=$(mktemp -d /tmp/b2b-wf01-runtime.XXXXXX)
RESTORE_NEEDED=false

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local actual=$1
    local expected=$2
    local message=$3

    if [[ "${actual}" != "${expected}" ]]; then
        fail "${message}: expected '${expected}', got '${actual}'"
    fi
}

assert_json() {
    local json=$1
    local expression=$2
    local message=$3

    if ! jq -e "${expression}" >/dev/null <<<"${json}"; then
        fail "${message}: ${json}"
    fi
}

app_sql() {
    local sql=$1

    docker compose exec -T postgres sh -lc \
        'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d b2b_onboarding -At -F "|"' \
        <<<"${sql}"
}

n8n_sql() {
    local sql=$1

    docker compose exec -T postgres sh -lc \
        'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d n8n -At -F "|"' \
        <<<"${sql}"
}

restart_n8n_cluster() {
    local deadline
    local healthy

    docker compose restart n8n-main n8n-worker-1 n8n-worker-2 >/dev/null
    deadline=$((SECONDS + 60))

    while (( SECONDS < deadline )); do
        healthy=$(
            docker compose ps --format json \
                | jq -r '
                    select(
                        .Service == "n8n-main"
                        or .Service == "n8n-worker-1"
                        or .Service == "n8n-worker-2"
                    )
                    | .Health
                ' \
                | grep -c '^healthy$' \
                || true
        )

        if [[ "${healthy}" == "3" ]]; then
            return 0
        fi

        sleep 1
    done

    docker compose ps >&2
    fail 'n8n cluster did not become healthy within 60 seconds'
}

export_workflow() {
    local workflow_id=$1
    local container_path=$2
    local host_path=$3
    local attempt

    for attempt in $(seq 1 10); do
        if docker compose exec -T n8n-main n8n export:workflow \
            --id="${workflow_id}" \
            --pretty \
            --output="${container_path}" \
            >/dev/null; then
            break
        fi

        if [[ "${attempt}" == "10" ]]; then
            fail "could not export workflow ${workflow_id}"
        fi

        sleep 1
    done

    docker cp \
        "b2b-client-onboarding-platform-n8n-main-1:${container_path}" \
        "${host_path}" \
        >/dev/null
}

deploy_workflow() {
    local workflow_id=$1
    local host_path=$2
    local container_path=$3

    docker cp "${host_path}" \
        "b2b-client-onboarding-platform-n8n-main-1:${container_path}" \
        >/dev/null

    docker compose exec -T n8n-main n8n unpublish:workflow \
        --id="${workflow_id}" \
        >/dev/null \
        2>&1 \
        || true

    docker compose exec -T n8n-main n8n import:workflow \
        --input="${container_path}" \
        >/dev/null
}

execution_summary() {
    local execution_id=$1

    n8n_sql "SELECT data FROM execution_data WHERE \"executionId\" = ${execution_id};" \
        | docker compose exec -T n8n-main sh -lc '
            flatted_module=$(find /usr/local/lib/node_modules/n8n/node_modules/.pnpm -type d -path "*/node_modules/flatted" | head -1)
            node -e '\''
                const fs = require("fs");
                const { parse } = require(process.argv[1]);
                const execution = parse(fs.readFileSync(0, "utf8").trim());
                const runData = execution.resultData?.runData ?? {};
                const lastNode = execution.resultData?.lastNodeExecuted ?? null;
                const lastRuns = lastNode === null ? [] : (runData[lastNode] ?? []);
                const lastOutput = lastRuns.flatMap((run) =>
                    (run.data?.main ?? []).flatMap((items) =>
                        (items ?? []).map((item) => item.json),
                    ),
                );
                process.stdout.write(JSON.stringify({
                    lastNode,
                    runNodes: Object.keys(runData),
                    lastOutput,
                }));
            '\'' "${flatted_module}"
        '
}

restore_workflow() {
    local current_export="${TEMP_DIR}/wf01-restored-check.json"
    local restored_target
    local restored_state
    local wf02_state_after

    if [[ "${RESTORE_NEEDED}" != true ]]; then
        return 0
    fi

    deploy_workflow \
        "${WF01_WORKFLOW_ID}" \
        "${WF01_BACKUP}" \
        /tmp/WF01-runtime-restore.json

    if [[ "${ORIGINAL_WF01_ACTIVE}" == "t" ]]; then
        docker compose exec -T n8n-main n8n publish:workflow \
            --id="${WF01_WORKFLOW_ID}" \
            >/dev/null
    else
        docker compose exec -T n8n-main n8n unpublish:workflow \
            --id="${WF01_WORKFLOW_ID}" \
            >/dev/null \
            2>&1 \
            || true
    fi

    restart_n8n_cluster

    export_workflow \
        "${WF01_WORKFLOW_ID}" \
        /tmp/WF01-runtime-restored-check.json \
        "${current_export}"

    restored_target=$(
        jq -r '
            .[0].nodes[]
            | select(.name == "Dispatch WF02")
            | .parameters.workflowId.value
        ' "${current_export}"
    )

    restored_state=$(
        n8n_sql "
            SELECT
                active::text || '|' ||
                CASE
                    WHEN \"activeVersionId\" IS NULL THEN 'unpublished'
                    ELSE 'published'
                END
            FROM workflow_entity
            WHERE id = '${WF01_WORKFLOW_ID}';
        "
    )

    wf02_state_after=$(
        n8n_sql "
            SELECT
                active::text || '|' ||
                COALESCE(\"activeVersionId\"::text, 'NULL') || '|' ||
                \"versionId\"::text
            FROM workflow_entity
            WHERE id = '${WF02_WORKFLOW_ID}';
        "
    )

    assert_equal "${restored_target}" "${WF02_WORKFLOW_ID}" \
        'real WF02 target was not restored'
    assert_equal "${restored_state}" "${ORIGINAL_WF01_STATE}" \
        'WF01 active/published state was not restored'
    assert_equal "${wf02_state_after}" "${ORIGINAL_WF02_STATE}" \
        'WF02 active/published state changed during runtime tests'

    RESTORE_NEEDED=false

    printf 'RESTORE target=%s wf01_state=%s wf02_state_unchanged=true\n' \
        "${restored_target}" \
        "${restored_state}"
}

cleanup() {
    local exit_code=$?

    if [[ "${RESTORE_NEEDED}" == true ]]; then
        restore_workflow || exit_code=1
    fi

    rm -rf -- "${TEMP_DIR}"
    exit "${exit_code}"
}

trap cleanup EXIT INT TERM

http_post() {
    local label=$1
    local content_type=$2
    local auth_value=$3
    local body=$4
    local response_file="${TEMP_DIR}/${label}.response"

    HTTP_STATUS=$(
        curl \
            --max-time 120 \
            --silent \
            --show-error \
            --output "${response_file}" \
            --write-out '%{http_code}' \
            --request POST \
            "${WF01_WEBHOOK_URL}" \
            --header "Authorization: ${auth_value}" \
            --header "Content-Type: ${content_type}" \
            --data-binary "${body}"
    )

    HTTP_BODY=$(tr -d '\n' <"${response_file}")
}

case_snapshot() {
    local case_id=$1

    app_sql "
        SELECT json_build_object(
            'case_state', onboarding_case.state,
            'correlation_id', onboarding_case.correlation_id,
            'case_count', (
                SELECT count(*)
                FROM onboarding_cases
                WHERE source_system = onboarding_case.source_system
                  AND source_deal_id = onboarding_case.source_deal_id
            ),
            'step_count', (
                SELECT count(*)
                FROM onboarding_steps
                WHERE case_id = onboarding_case.id
            ),
            'source_event_count', (
                SELECT count(*)
                FROM onboarding_events
                WHERE case_id = onboarding_case.id
                  AND event_type = 'crm_deal_won_received'
            ),
            'case_created_event_count', (
                SELECT count(*)
                FROM onboarding_events
                WHERE case_id = onboarding_case.id
                  AND event_type = 'onboarding_case_created'
            ),
            'business_event_count', (
                SELECT count(*)
                FROM onboarding_events
                WHERE case_id = onboarding_case.id
            ),
            'send_operation_count', (
                SELECT count(*)
                FROM external_operations
                WHERE case_id = onboarding_case.id
                  AND operation_type = 'send_client_data_request'
            ),
            'successful_send_operation_count', (
                SELECT count(*)
                FROM external_operations
                WHERE case_id = onboarding_case.id
                  AND operation_type = 'send_client_data_request'
                  AND status = 'succeeded'
            ),
            'client_link_count', (
                SELECT count(*)
                FROM clients
                WHERE id = onboarding_case.client_id
            )
        )
        FROM onboarding_cases AS onboarding_case
        WHERE onboarding_case.id = '${case_id}'::uuid;
    "
}

assert_no_business_writes() {
    local event_id=$1
    local deal_id=$2
    local snapshot

    snapshot=$(
        app_sql "
            SELECT json_build_object(
                'case_count', (
                    SELECT count(*)
                    FROM onboarding_cases
                    WHERE source_system = 'mock_crm'
                      AND (
                          source_event_id = '${event_id}'
                          OR source_deal_id = '${deal_id}'
                      )
                ),
                'event_count', (
                    SELECT count(*)
                    FROM onboarding_events
                    WHERE event_data ->> 'source_event_id' = '${event_id}'
                ),
                'operation_count', (
                    SELECT count(*)
                    FROM external_operations AS operation
                    JOIN onboarding_cases AS onboarding_case
                      ON onboarding_case.id = operation.case_id
                    WHERE onboarding_case.source_system = 'mock_crm'
                      AND (
                          onboarding_case.source_event_id = '${event_id}'
                          OR onboarding_case.source_deal_id = '${deal_id}'
                      )
                )
            );
        "
    )

    assert_json "${snapshot}" \
        '.case_count == 0 and .event_count == 0 and .operation_count == 0' \
        "business writes exist for rejected event ${event_id}"

    printf '%s' "${snapshot}"
}

WF01_WORKFLOW_ID=$(
    n8n_sql "
        SELECT id
        FROM workflow_entity
        WHERE name = 'WF01 - Intake Deal Won'
        ORDER BY \"updatedAt\" DESC
        LIMIT 1;
    "
)

WF02_WORKFLOW_ID=$(
    n8n_sql "
        SELECT id
        FROM workflow_entity
        WHERE name = 'WF02 - Request Client Data - Implementation Complete'
        ORDER BY \"updatedAt\" DESC
        LIMIT 1;
    "
)

WF99_WORKFLOW_ID=$(
    n8n_sql "
        SELECT id
        FROM workflow_entity
        WHERE name = 'WF99 - Central Error Handler'
        ORDER BY \"updatedAt\" DESC
        LIMIT 1;
    "
)

[[ -n "${WF01_WORKFLOW_ID}" ]] || fail 'WF01 workflow was not found'
[[ -n "${WF02_WORKFLOW_ID}" ]] || fail 'WF02 workflow was not found'
[[ -n "${WF99_WORKFLOW_ID}" ]] || fail 'WF99 workflow was not found'

WF01_BACKUP="${TEMP_DIR}/WF01-before-runtime.json"

ORIGINAL_WF01_ACTIVE=$(
    n8n_sql "SELECT active::text FROM workflow_entity WHERE id = '${WF01_WORKFLOW_ID}';"
)

ORIGINAL_WF01_STATE=$(
    n8n_sql "
        SELECT
            active::text || '|' ||
            CASE
                WHEN \"activeVersionId\" IS NULL THEN 'unpublished'
                ELSE 'published'
            END
        FROM workflow_entity
        WHERE id = '${WF01_WORKFLOW_ID}';
    "
)

ORIGINAL_WF02_STATE=$(
    n8n_sql "
        SELECT
            active::text || '|' ||
            COALESCE(\"activeVersionId\"::text, 'NULL') || '|' ||
            \"versionId\"::text
        FROM workflow_entity
        WHERE id = '${WF02_WORKFLOW_ID}';
    "
)

export_workflow \
    "${WF01_WORKFLOW_ID}" \
    /tmp/WF01-before-runtime.json \
    "${WF01_BACKUP}"

RESTORE_NEEDED=true

assert_json "$(jq -c '.[0].nodes[] | select(.name == "Dispatch WF02")' "${WF01_BACKUP}")" \
    ".parameters.workflowId.value == \"${WF02_WORKFLOW_ID}\" and .parameters.options.waitForSubWorkflow == true and .onError == \"continueErrorOutput\" and .alwaysOutputData == false" \
    'Dispatch WF02 configuration is invalid'

if [[ "${ORIGINAL_WF01_ACTIVE}" != "t" ]]; then
    docker compose exec -T n8n-main n8n publish:workflow \
        --id="${WF01_WORKFLOW_ID}" \
        >/dev/null
fi

restart_n8n_cluster

RUN_KEY="$(date -u +%Y%m%dT%H%M%S)-$$-${RANDOM}"
EVENT_A="evt-wf01-a-${RUN_KEY}"
DEAL_A="deal-wf01-a-${RUN_KEY}"
EVENT_C="evt-wf01-c-${RUN_KEY}"
DEAL_D="deal-wf01-d-${RUN_KEY}"
EVENT_E="evt-wf01-e-${RUN_KEY}"
DEAL_E="deal-wf01-e-${RUN_KEY}"
EVENT_F="evt-wf01-f-${RUN_KEY}"
DEAL_F="deal-wf01-f-${RUN_KEY}"
EVENT_G="evt-wf01-g-${RUN_KEY}"
DEAL_G="deal-wf01-g-${RUN_KEY}"
EVENT_H="evt-wf01-h-${RUN_KEY}"
DEAL_H="deal-wf01-h-${RUN_KEY}"
EVENT_I="evt-wf01-i-${RUN_KEY}"
DEAL_I="deal-wf01-i-${RUN_KEY}"

VALID_A=$(
    jq -cn \
        --arg event_id "${EVENT_A}" \
        --arg deal_id "${DEAL_A}" \
        '{
            event_type: "deal.won",
            event_id: $event_id,
            deal_id: $deal_id,
            company: {name: "WF01 Runtime Test Company"},
            contact: {
                first_name: "Runtime",
                last_name: "Tester",
                email: "wf01.runtime@example.com",
                phone: "+48000000000"
            },
            metadata: {
                pipeline_id: "wf01-runtime",
                owner_id: "automation"
            }
        }'
)

WF02_BEFORE_A=$(
    n8n_sql "SELECT COALESCE(max(id), 0) FROM execution_entity WHERE \"workflowId\" = '${WF02_WORKFLOW_ID}';"
)

http_post A application/json "${WF01_AUTH_HEADER}" "${VALID_A}"
assert_equal "${HTTP_STATUS}" 201 'scenario A HTTP status'
assert_json "${HTTP_BODY}" \
    '.status == "accepted" and .intake_result == "created" and .wf02_dispatch == "invoked" and .case_state == "created" and (.case_id | test("^[0-9a-f-]{36}$")) and (.correlation_id | test("^[0-9a-f-]{36}$"))' \
    'scenario A response'

CASE_ID=$(jq -r '.case_id' <<<"${HTTP_BODY}")
CORRELATION_ID=$(jq -r '.correlation_id' <<<"${HTTP_BODY}")

deadline=$((SECONDS + WF01_POLL_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
    SNAPSHOT_A=$(case_snapshot "${CASE_ID}")

    if jq -e '
        .case_state == "awaiting_client_data"
        and .successful_send_operation_count == 1
    ' >/dev/null <<<"${SNAPSHOT_A}"; then
        break
    fi

    sleep 1
done

assert_json "${SNAPSHOT_A}" \
    ".case_state == \"awaiting_client_data\" and .correlation_id == \"${CORRELATION_ID}\" and .case_count == 1 and .step_count == 7 and .source_event_count == 1 and .case_created_event_count == 1 and .send_operation_count == 1 and .successful_send_operation_count == 1 and .client_link_count == 0" \
    'scenario A PostgreSQL invariants'

WF02_AFTER_A=$(
    n8n_sql "SELECT COALESCE(max(id), 0) FROM execution_entity WHERE \"workflowId\" = '${WF02_WORKFLOW_ID}';"
)

(( WF02_AFTER_A > WF02_BEFORE_A )) \
    || fail 'scenario A did not create a WF02 execution'

printf 'SCENARIO A HTTP=%s RESPONSE=%s DB=%s WF02_EXECUTION=%s\n' \
    "${HTTP_STATUS}" "${HTTP_BODY}" "${SNAPSHOT_A}" "${WF02_AFTER_A}"

EVENTS_BEFORE_B=$(jq -r '.business_event_count' <<<"${SNAPSHOT_A}")
OPERATIONS_BEFORE_B=$(jq -r '.send_operation_count' <<<"${SNAPSHOT_A}")

http_post B application/json "${WF01_AUTH_HEADER}" "${VALID_A}"
assert_equal "${HTTP_STATUS}" 200 'scenario B HTTP status'
assert_json "${HTTP_BODY}" \
    ".status == \"accepted\" and .intake_result == \"duplicate_event\" and .case_id == \"${CASE_ID}\" and .correlation_id == \"${CORRELATION_ID}\" and .wf02_dispatch == \"not_required\"" \
    'scenario B response'

SNAPSHOT_B=$(case_snapshot "${CASE_ID}")
assert_json "${SNAPSHOT_B}" \
    ".case_count == 1 and .business_event_count == ${EVENTS_BEFORE_B} and .send_operation_count == ${OPERATIONS_BEFORE_B} and .successful_send_operation_count == 1" \
    'scenario B PostgreSQL invariants'

WF02_AFTER_B=$(
    n8n_sql "SELECT COALESCE(max(id), 0) FROM execution_entity WHERE \"workflowId\" = '${WF02_WORKFLOW_ID}';"
)
assert_equal "${WF02_AFTER_B}" "${WF02_AFTER_A}" \
    'scenario B unexpectedly dispatched WF02'

printf 'SCENARIO B HTTP=%s RESPONSE=%s DB=%s WF02_REDISPATCH=false\n' \
    "${HTTP_STATUS}" "${HTTP_BODY}" "${SNAPSHOT_B}"

VALID_C=$(
    jq -cn \
        --arg event_id "${EVENT_C}" \
        --arg deal_id "${DEAL_A}" \
        '{
            event_type: "deal.won",
            event_id: $event_id,
            deal_id: $deal_id,
            company: {name: "Ignored Existing Deal Company"},
            contact: {email: "ignored-existing@example.com"},
            metadata: {}
        }'
)

http_post C application/json "${WF01_AUTH_HEADER}" "${VALID_C}"
assert_equal "${HTTP_STATUS}" 200 'scenario C HTTP status'
assert_json "${HTTP_BODY}" \
    ".status == \"accepted\" and .intake_result == \"existing_deal\" and .case_id == \"${CASE_ID}\" and .correlation_id == \"${CORRELATION_ID}\" and .wf02_dispatch == \"not_required\"" \
    'scenario C response'

SNAPSHOT_C=$(case_snapshot "${CASE_ID}")
assert_json "${SNAPSHOT_C}" \
    ".case_count == 1 and .source_event_count == 2 and .case_created_event_count == 1 and .business_event_count == (${EVENTS_BEFORE_B} + 1) and .send_operation_count == ${OPERATIONS_BEFORE_B}" \
    'scenario C PostgreSQL invariants'

WF02_AFTER_C=$(
    n8n_sql "SELECT COALESCE(max(id), 0) FROM execution_entity WHERE \"workflowId\" = '${WF02_WORKFLOW_ID}';"
)
assert_equal "${WF02_AFTER_C}" "${WF02_AFTER_A}" \
    'scenario C unexpectedly dispatched WF02'

printf 'SCENARIO C HTTP=%s RESPONSE=%s DB=%s WF02_REDISPATCH=false\n' \
    "${HTTP_STATUS}" "${HTTP_BODY}" "${SNAPSHOT_C}"

VALID_D=$(
    jq -cn \
        --arg event_id "${EVENT_A}" \
        --arg deal_id "${DEAL_D}" \
        '{
            event_type: "deal.won",
            event_id: $event_id,
            deal_id: $deal_id,
            company: {name: "WF01 Conflict Company"},
            contact: {email: "wf01.conflict@example.com"},
            metadata: {}
        }'
)

http_post D application/json "${WF01_AUTH_HEADER}" "${VALID_D}"
assert_equal "${HTTP_STATUS}" 409 'scenario D HTTP status'
assert_json "${HTTP_BODY}" \
    '.status == "rejected" and .error_code == "source_identity_conflict"' \
    'scenario D response'

SNAPSHOT_D=$(case_snapshot "${CASE_ID}")
assert_json "${SNAPSHOT_D}" \
    ".case_count == 1 and .business_event_count == (${EVENTS_BEFORE_B} + 1) and .send_operation_count == ${OPERATIONS_BEFORE_B}" \
    'scenario D existing case changed'

CONFLICT_CASE_COUNT=$(
    app_sql "SELECT count(*) FROM onboarding_cases WHERE source_system = 'mock_crm' AND source_deal_id = '${DEAL_D}';"
)
assert_equal "${CONFLICT_CASE_COUNT}" 0 'scenario D created a conflicting case'

WF02_AFTER_D=$(
    n8n_sql "SELECT COALESCE(max(id), 0) FROM execution_entity WHERE \"workflowId\" = '${WF02_WORKFLOW_ID}';"
)
assert_equal "${WF02_AFTER_D}" "${WF02_AFTER_A}" \
    'scenario D unexpectedly dispatched WF02'

printf 'SCENARIO D HTTP=%s RESPONSE=%s DB=%s CONFLICT_CASES=%s WF02_REDISPATCH=false\n' \
    "${HTTP_STATUS}" "${HTTP_BODY}" "${SNAPSHOT_D}" "${CONFLICT_CASE_COUNT}"

INVALID_E=$(
    jq -cn \
        --arg event_id "${EVENT_E}" \
        --arg deal_id "${DEAL_E}" \
        '{
            event_type: "deal.won",
            event_id: $event_id,
            deal_id: $deal_id,
            company: {name: "WF01 Missing Email"},
            contact: {},
            metadata: {}
        }'
)

http_post E application/json "${WF01_AUTH_HEADER}" "${INVALID_E}"
assert_equal "${HTTP_STATUS}" 400 'scenario E HTTP status'
assert_json "${HTTP_BODY}" \
    '.status == "rejected" and .error_code == "invalid_payload" and any(.errors[]; .field == "contact.email" and .code == "required")' \
    'scenario E response'
NO_WRITES_E=$(assert_no_business_writes "${EVENT_E}" "${DEAL_E}")
printf 'SCENARIO E HTTP=%s RESPONSE=%s DB=%s\n' \
    "${HTTP_STATUS}" "${HTTP_BODY}" "${NO_WRITES_E}"

PLAIN_F=$(
    jq -cn \
        --arg event_id "${EVENT_F}" \
        --arg deal_id "${DEAL_F}" \
        '{
            event_type: "deal.won",
            event_id: $event_id,
            deal_id: $deal_id,
            company: {name: "WF01 Text Plain"},
            contact: {email: "wf01.text@example.com"}
        }'
)

http_post F text/plain "${WF01_AUTH_HEADER}" "${PLAIN_F}"
assert_equal "${HTTP_STATUS}" 415 'scenario F HTTP status'
assert_json "${HTTP_BODY}" \
    '.status == "rejected" and .error_code == "unsupported_media_type"' \
    'scenario F response'
NO_WRITES_F=$(assert_no_business_writes "${EVENT_F}" "${DEAL_F}")
printf 'SCENARIO F HTTP=%s RESPONSE=%s DB=%s\n' \
    "${HTTP_STATUS}" "${HTTP_BODY}" "${NO_WRITES_F}"

MALFORMED_G="{\"event_type\":\"deal.won\",\"event_id\":\"${EVENT_G}\",\"deal_id\":\"${DEAL_G}\",\"company\":{\"name\":\"WF01 Malformed\"},\"contact\":{\"email\":\"wf01.malformed@example.com\"}"
http_post G application/json "${WF01_AUTH_HEADER}" "${MALFORMED_G}"
assert_equal "${HTTP_STATUS}" 422 'scenario G HTTP status'
assert_json "${HTTP_BODY}" \
    '.code == 422 and (.message | contains("Failed to parse request body"))' \
    'scenario G platform response'
NO_WRITES_G=$(assert_no_business_writes "${EVENT_G}" "${DEAL_G}")
printf 'SCENARIO G HTTP=%s RESPONSE=%s DB=%s\n' \
    "${HTTP_STATUS}" "${HTTP_BODY}" "${NO_WRITES_G}"

VALID_H=$(
    jq -cn \
        --arg event_id "${EVENT_H}" \
        --arg deal_id "${DEAL_H}" \
        '{
            event_type: "deal.won",
            event_id: $event_id,
            deal_id: $deal_id,
            company: {name: "WF01 Invalid Auth"},
            contact: {email: "wf01.auth@example.com"}
        }'
)

http_post H application/json 'Bearer invalid-wf01-runtime-value' "${VALID_H}"
assert_equal "${HTTP_STATUS}" 403 'scenario H HTTP status'
[[ "${HTTP_BODY}" == *'Authorization data is wrong'* ]] \
    || fail "scenario H platform response: ${HTTP_BODY}"
NO_WRITES_H=$(assert_no_business_writes "${EVENT_H}" "${DEAL_H}")
printf 'SCENARIO H HTTP=%s RESPONSE=%s DB=%s\n' \
    "${HTTP_STATUS}" "${HTTP_BODY}" "${NO_WRITES_H}"

FAULT_WORKFLOW="${TEMP_DIR}/WF01-fault-injection.json"

jq '
    (.[0].nodes[]
        | select(.name == "Dispatch WF02")
        | .parameters.workflowId.value) = "WF02_MISSING_TEST"
    |
    (.[0].nodes[]
        | select(.name == "Dispatch WF02")
        | .parameters.workflowId.cachedResultUrl) = "/workflow/WF02_MISSING_TEST"
    |
    (.[0].nodes[]
        | select(.name == "Dispatch WF02")
        | .parameters.workflowId.cachedResultName) = "WF02 Missing Fault Injection"
' "${WF01_BACKUP}" >"${FAULT_WORKFLOW}"

deploy_workflow \
    "${WF01_WORKFLOW_ID}" \
    "${FAULT_WORKFLOW}" \
    /tmp/WF01-runtime-fault.json

docker compose exec -T n8n-main n8n publish:workflow \
    --id="${WF01_WORKFLOW_ID}" \
    >/dev/null

restart_n8n_cluster

EXECUTION_BEFORE_I=$(
    n8n_sql 'SELECT COALESCE(max(id), 0) FROM execution_entity;'
)

VALID_I=$(
    jq -cn \
        --arg event_id "${EVENT_I}" \
        --arg deal_id "${DEAL_I}" \
        '{
            event_type: "deal.won",
            event_id: $event_id,
            deal_id: $deal_id,
            company: {name: "WF01 Fault Injection"},
            contact: {email: "wf01.fault@example.com"},
            metadata: {}
        }'
)

http_post I application/json "${WF01_AUTH_HEADER}" "${VALID_I}"
assert_equal "${HTTP_STATUS}" 500 'scenario I HTTP status'
assert_json "${HTTP_BODY}" \
    '.status == "error" and .error_code == "wf02_dispatch_failed"' \
    'scenario I response'

CASE_I_ROW=$(
    app_sql "
        SELECT id::text || '|' || correlation_id::text
        FROM onboarding_cases
        WHERE source_system = 'mock_crm'
          AND source_event_id = '${EVENT_I}';
    "
)

CASE_I=${CASE_I_ROW%%|*}
CORRELATION_I=${CASE_I_ROW#*|}
[[ -n "${CASE_I}" && -n "${CORRELATION_I}" ]] \
    || fail 'scenario I did not persist the intake case'

SNAPSHOT_I=$(case_snapshot "${CASE_I}")
assert_json "${SNAPSHOT_I}" \
    ".case_state == \"created\" and .correlation_id == \"${CORRELATION_I}\" and .case_count == 1 and .step_count == 7 and .source_event_count == 1 and .case_created_event_count == 1 and .business_event_count == 2 and .send_operation_count == 0" \
    'scenario I PostgreSQL case invariants'

ERROR_I=$(
    app_sql "
        SELECT json_build_object(
            'count', count(*),
            'error_class', min(error_class),
            'error_code', min(error_code),
            'case_id', min(case_id::text),
            'correlation_id', min(correlation_id::text)
        )
        FROM error_log
        WHERE case_id = '${CASE_I}'::uuid
          AND error_class = 'dispatch_acceptance_failure'
          AND error_code = 'wf02_dispatch_failed';
    "
)

assert_json "${ERROR_I}" \
    ".count == 1 and .error_class == \"dispatch_acceptance_failure\" and .error_code == \"wf02_dispatch_failed\" and .case_id == \"${CASE_I}\" and .correlation_id == \"${CORRELATION_I}\"" \
    'scenario I error_log invariants'

WF01_EXECUTION_I=$(
    n8n_sql "
        SELECT id
        FROM execution_entity
        WHERE id > ${EXECUTION_BEFORE_I}
          AND \"workflowId\" = '${WF01_WORKFLOW_ID}'
        ORDER BY id DESC
        LIMIT 1;
    "
)

WF99_EXECUTION_I=$(
    n8n_sql "
        SELECT id
        FROM execution_entity
        WHERE id > ${EXECUTION_BEFORE_I}
          AND \"workflowId\" = '${WF99_WORKFLOW_ID}'
        ORDER BY id DESC
        LIMIT 1;
    "
)

[[ -n "${WF01_EXECUTION_I}" ]] || fail 'scenario I WF01 execution was not found'
[[ -n "${WF99_EXECUTION_I}" ]] || fail 'scenario I WF99 execution was not found'

WF01_EXECUTION_SUMMARY=$(execution_summary "${WF01_EXECUTION_I}")
WF99_EXECUTION_SUMMARY=$(execution_summary "${WF99_EXECUTION_I}")

assert_json "${WF01_EXECUTION_SUMMARY}" '
    (.runNodes | index("Dispatch WF02") != null)
    and (.runNodes | index("Build WF99 Dispatch Failure") != null)
    and (.runNodes | index("Dispatch WF99") != null)
    and (.runNodes | index("Reject WF02 Dispatch Failure") != null)
    and (.runNodes | index("Accept Intake - WF02 Invoked") == null)
' 'scenario I executed the wrong Dispatch WF02 branch'

assert_json "${WF01_EXECUTION_SUMMARY}" '
    any(.lastOutput[]; .handler_status == "completed")
' 'scenario I did not receive completed WF99 output'

assert_json "${WF99_EXECUTION_SUMMARY}" '
    .lastNode == "Build Non-Delivery Outcome"
    and any(.lastOutput[]; .handler_status == "completed")
' 'scenario I WF99 handler did not complete'

printf 'SCENARIO I HTTP=%s RESPONSE=%s DB=%s ERROR_LOG=%s WF01_EXECUTION=%s WF99_EXECUTION=%s HANDLER_STATUS=completed SUCCESS_BRANCH_EXECUTED=false\n' \
    "${HTTP_STATUS}" \
    "${HTTP_BODY}" \
    "${SNAPSHOT_I}" \
    "${ERROR_I}" \
    "${WF01_EXECUTION_I}" \
    "${WF99_EXECUTION_I}"

restore_workflow

printf 'PASS: WF01 runtime scenarios A-I completed successfully\n'
