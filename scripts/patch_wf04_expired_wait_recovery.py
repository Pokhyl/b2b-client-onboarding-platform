#!/usr/bin/env python3

from pathlib import Path

MIGRATION_PATH = Path("db/migrations/011_wf04_manual_approval.sql")
TEST_PATH = Path("db/tests/011_wf04_manual_approval_checks.sql")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one {label}, found {count}")
    return text.replace(old, new, 1)


migration = MIGRATION_PATH.read_text(encoding="utf-8")

migration = replace_once(
    migration,
    """    v_lease_owner text;\n    v_request_summary jsonb;\nBEGIN\n""",
    """    v_lease_owner text;\n    v_request_summary jsonb;\n    v_recover_expired_wait boolean := false;\nBEGIN\n""",
    "WF04 declaration block",
)

old_wait_block = """    IF step_row.status = 'waiting' THEN
        IF FOUND
            AND existing_operation_row.operation_type =
                'send_approval_request'
            AND existing_operation_row.case_id =
                case_row.id
            AND existing_operation_row.status =
                'in_progress'
            AND existing_operation_row.lease_owner =
                'WF04:'
                || step_row.n8n_wait_execution_id
            AND existing_operation_row.lease_expires_at >
                v_now
            AND existing_operation_row.request_summary =
                v_request_summary
            AND lower(
                    btrim(
                        step_row.approval_recipient_email
                    )
                ) = v_recipient_email
            AND (
                p_external_operation_id IS NULL
                OR existing_operation_row.id =
                    p_external_operation_id
            )
        THEN
            preparation_outcome :=
                'active_wait_exists';

            operation_claim_outcome :=
                'busy';

            operation_id :=
                existing_operation_row.id;

            operation_status :=
                existing_operation_row.status;

            operation_attempt_count :=
                existing_operation_row.attempt_count;

            operation_max_attempts :=
                existing_operation_row.max_attempts;

            operation_lease_expires_at :=
                existing_operation_row.lease_expires_at;

            waiting_execution_id :=
                step_row.n8n_wait_execution_id;

            approval_step_status :=
                step_row.status;
        ELSE
            preparation_outcome :=
                'inconsistent_active_wait';
        END IF;

        RETURN NEXT;
        RETURN;
    END IF;
"""

new_wait_block = """    IF step_row.status = 'waiting' THEN
        IF FOUND
            AND existing_operation_row.operation_type =
                'send_approval_request'
            AND existing_operation_row.case_id =
                case_row.id
            AND existing_operation_row.status =
                'in_progress'
            AND existing_operation_row.lease_owner =
                'WF04:'
                || step_row.n8n_wait_execution_id
            AND existing_operation_row.lease_expires_at >
                v_now
            AND existing_operation_row.request_summary =
                v_request_summary
            AND lower(
                    btrim(
                        step_row.approval_recipient_email
                    )
                ) = v_recipient_email
            AND (
                p_external_operation_id IS NULL
                OR existing_operation_row.id =
                    p_external_operation_id
            )
        THEN
            preparation_outcome :=
                'active_wait_exists';

            operation_claim_outcome :=
                'busy';

            operation_id :=
                existing_operation_row.id;

            operation_status :=
                existing_operation_row.status;

            operation_attempt_count :=
                existing_operation_row.attempt_count;

            operation_max_attempts :=
                existing_operation_row.max_attempts;

            operation_lease_expires_at :=
                existing_operation_row.lease_expires_at;

            waiting_execution_id :=
                step_row.n8n_wait_execution_id;

            approval_step_status :=
                step_row.status;

            RETURN NEXT;
            RETURN;

        ELSIF FOUND
            AND p_trigger_source = 'wf98'
            AND p_external_operation_id =
                existing_operation_row.id
            AND existing_operation_row.operation_type =
                'send_approval_request'
            AND existing_operation_row.case_id =
                case_row.id
            AND existing_operation_row.status =
                'in_progress'
            AND existing_operation_row.lease_owner =
                'WF04:'
                || step_row.n8n_wait_execution_id
            AND existing_operation_row.lease_expires_at <=
                v_now
            AND existing_operation_row.request_summary =
                v_request_summary
            AND lower(
                    btrim(
                        step_row.approval_recipient_email
                    )
                ) = v_recipient_email
        THEN
            v_recover_expired_wait :=
                true;

        ELSE
            preparation_outcome :=
                'inconsistent_active_wait';

            RETURN NEXT;
            RETURN;
        END IF;
    END IF;
"""

migration = replace_once(
    migration,
    old_wait_block,
    new_wait_block,
    "WF04 active-wait block",
)

migration = replace_once(
    migration,
    """    IF step_row.status NOT IN (
        'pending',
        'failed_retryable'
    ) THEN
""",
    """    IF step_row.status NOT IN (
        'pending',
        'failed_retryable'
    )
        AND NOT v_recover_expired_wait
    THEN
""",
    "WF04 allowed-step-status block",
)

MIGRATION_PATH.write_text(migration, encoding="utf-8")


test_sql = TEST_PATH.read_text(encoding="utf-8")

expired_wait_test = r'''

DO $$
DECLARE
    v_case_id uuid;
    v_correlation_id uuid;
    v_submission_id uuid;
    v_client_id uuid;

    v_prepare record;
    v_recovered record;

    v_step_status text;
    v_stored_execution_id text;
    v_operation_status text;
    v_operation_attempt_count integer;
    v_operation_lease_owner text;
BEGIN
    SELECT fixture.*
    INTO
        v_case_id,
        v_correlation_id,
        v_submission_id,
        v_client_id
    FROM pg_temp.create_wf04_test_case(
        'expired-wait'
    ) AS fixture;

    SELECT result.*
    INTO STRICT v_prepare
    FROM prepare_wf04_approval_request(
        v_case_id,
        v_correlation_id,
        'wf03',
        v_submission_id,
        v_client_id,
        NULL,
        NULL,
        'wf04-expired-execution-1',
        'operator@example.com',
        'manual_approval_v1',
        'b2b-approval-eeeeeeeeeeeeeeeeeeeeeeee',
        168,
        608400,
        3
    ) AS result;

    UPDATE external_operations
    SET lease_expires_at =
        clock_timestamp() - interval '1 second'
    WHERE id = v_prepare.operation_id;

    SELECT result.*
    INTO STRICT v_recovered
    FROM prepare_wf04_approval_request(
        v_case_id,
        v_correlation_id,
        'wf98',
        NULL,
        NULL,
        v_prepare.operation_id,
        NULL,
        'wf04-expired-execution-2',
        'operator@example.com',
        'manual_approval_v1',
        'b2b-approval-eeeeeeeeeeeeeeeeeeeeeeee',
        168,
        608400,
        3
    ) AS result;

    IF v_recovered.preparation_outcome
            IS DISTINCT FROM 'ready_to_send'
        OR v_recovered.operation_claim_outcome
            IS DISTINCT FROM 'claimed'
        OR v_recovered.operation_attempt_count
            IS DISTINCT FROM 2
        OR v_recovered.waiting_execution_id
            IS DISTINCT FROM 'wf04-expired-execution-2'
    THEN
        RAISE EXCEPTION
            'Expired WF04 wait was not reclaimed: %',
            row_to_json(v_recovered);
    END IF;

    SELECT
        step.status,
        step.n8n_wait_execution_id
    INTO STRICT
        v_step_status,
        v_stored_execution_id
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case_id
      AND step.step_type = 'manual_approval';

    SELECT
        operation.status,
        operation.attempt_count,
        operation.lease_owner
    INTO STRICT
        v_operation_status,
        v_operation_attempt_count,
        v_operation_lease_owner
    FROM external_operations AS operation
    WHERE operation.id = v_prepare.operation_id;

    IF v_step_status <> 'waiting'
        OR v_stored_execution_id
            IS DISTINCT FROM 'wf04-expired-execution-2'
        OR v_operation_status <> 'in_progress'
        OR v_operation_attempt_count <> 2
        OR v_operation_lease_owner
            IS DISTINCT FROM
                'WF04:wf04-expired-execution-2'
    THEN
        RAISE EXCEPTION
            'Expired WF04 wait recovery persisted inconsistent state';
    END IF;

    RAISE NOTICE
        'PASS: WF04 expired active wait is atomically reclaimed';
END;
$$;
'''

rollback_marker = "\nROLLBACK;\n"
if test_sql.count(rollback_marker) != 1:
    raise SystemExit("Expected exactly one final ROLLBACK marker")

if "PASS: WF04 expired active wait is atomically reclaimed" not in test_sql:
    test_sql = test_sql.replace(
        rollback_marker,
        expired_wait_test + rollback_marker,
        1,
    )

TEST_PATH.write_text(test_sql, encoding="utf-8")

print("PASS: WF04 expired-wait recovery patch applied")
