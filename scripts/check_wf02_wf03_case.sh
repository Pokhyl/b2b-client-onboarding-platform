#!/usr/bin/env bash
set -euo pipefail

CASE_ID="${1:-}"

if [[ -z "$CASE_ID" ]]; then
  CASE_ID="$({
    docker compose exec -T postgres sh -lc \
      'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$APP_DB_NAME" -Atc "
        SELECT id
        FROM onboarding_cases
        WHERE source_system = '\''runtime_test'\''
        ORDER BY created_at DESC
        LIMIT 1;
      "'
  } | tr -d '[:space:]')"
fi

if [[ ! "$CASE_ID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  echo "FAIL: invalid or missing case_id: $CASE_ID" >&2
  exit 2
fi

ROW="$({
  docker compose exec -T postgres sh -lc \
    'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$APP_DB_NAME" -AtF "|"' <<SQL
SELECT
    oc.id,
    oc.state,
    collect_step.status,
    validate_step.status,
    COALESCE(submission.validation_status, ''),
    COALESCE(correction_token.status, ''),
    COALESCE(correction_operation.status, ''),
    COALESCE(latest_error.error_code, ''),
    COALESCE(correction_operation.external_id, '')
FROM onboarding_cases AS oc
LEFT JOIN onboarding_steps AS collect_step
    ON collect_step.case_id = oc.id
   AND collect_step.step_type = 'collect_client_data'
LEFT JOIN onboarding_steps AS validate_step
    ON validate_step.case_id = oc.id
   AND validate_step.step_type = 'validate_client_data'
LEFT JOIN LATERAL (
    SELECT osub.*
    FROM onboarding_submissions AS osub
    WHERE osub.case_id = oc.id
    ORDER BY osub.submission_sequence DESC
    LIMIT 1
) AS submission ON true
LEFT JOIN LATERAL (
    SELECT oft.*
    FROM onboarding_form_tokens AS oft
    WHERE oft.case_id = oc.id
      AND submission.id IS NOT NULL
      AND oft.request_cycle_key =
          'validation_failed:' || submission.id::text
    ORDER BY oft.issued_at DESC
    LIMIT 1
) AS correction_token ON true
LEFT JOIN LATERAL (
    SELECT eo.*
    FROM external_operations AS eo
    WHERE eo.case_id = oc.id
      AND eo.operation_type = 'send_client_data_request'
      AND submission.id IS NOT NULL
      AND eo.request_summary ->> 'request_cycle_key' =
          'validation_failed:' || submission.id::text
    ORDER BY eo.created_at DESC
    LIMIT 1
) AS correction_operation ON true
LEFT JOIN LATERAL (
    SELECT el.*
    FROM error_log AS el
    WHERE el.case_id = oc.id
    ORDER BY el.occurred_at DESC
    LIMIT 1
) AS latest_error ON true
WHERE oc.id = '$CASE_ID'::uuid;
SQL
} | tail -n 1)"

if [[ -z "$ROW" ]]; then
  echo "FAIL: case not found: $CASE_ID" >&2
  exit 3
fi

IFS='|' read -r \
  ACTUAL_CASE_ID \
  CASE_STATE \
  COLLECT_STATUS \
  VALIDATE_STATUS \
  SUBMISSION_STATUS \
  TOKEN_STATUS \
  OPERATION_STATUS \
  LATEST_ERROR_CODE \
  EXTERNAL_ID <<< "$ROW"

printf '%-28s %s\n' "case_id" "$ACTUAL_CASE_ID"
printf '%-28s %s\n' "case_state" "$CASE_STATE"
printf '%-28s %s\n' "collect_step_status" "$COLLECT_STATUS"
printf '%-28s %s\n' "validate_step_status" "$VALIDATE_STATUS"
printf '%-28s %s\n' "submission_validation" "$SUBMISSION_STATUS"
printf '%-28s %s\n' "correction_token_status" "$TOKEN_STATUS"
printf '%-28s %s\n' "correction_operation_status" "$OPERATION_STATUS"
printf '%-28s %s\n' "correction_message_id" "$EXTERNAL_ID"
printf '%-28s %s\n' "latest_error_code" "$LATEST_ERROR_CODE"

if [[ "$LATEST_ERROR_CODE" == "unsupported_wf02_result" ]]; then
  echo "FAIL: WF03 did not receive the WF02 return contract" >&2
  exit 10
fi

if [[ 
  "$CASE_STATE" == "awaiting_client_data" &&
  "$COLLECT_STATUS" == "in_progress" &&
  "$VALIDATE_STATUS" == "pending" &&
  "$SUBMISSION_STATUS" == "failed" &&
  "$TOKEN_STATUS" == "delivered" &&
  "$OPERATION_STATUS" == "succeeded"
]]; then
  echo "PASS: WF02 -> WF03 correction cycle is consistent"
  exit 0
fi

echo "WAIT/FAIL: correction cycle has not reached the expected state" >&2
exit 11
