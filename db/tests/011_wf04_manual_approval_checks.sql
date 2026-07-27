\set ON_ERROR_STOP on

BEGIN;

CREATE FUNCTION pg_temp.create_wf04_test_case(
    p_suffix text
)
RETURNS TABLE (
    created_case_id uuid,
    created_correlation_id uuid,
    created_submission_id uuid,
    created_client_id uuid
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_token_hash bytea;
BEGIN
    IF p_suffix IS NULL
        OR btrim(p_suffix) = ''
    THEN
        RAISE EXCEPTION
            'Test suffix must not be blank';
    END IF;

    INSERT INTO onboarding_cases (
        source_system,
        source_event_id,
        source_deal_id,
        intake_company_name,
        intake_contact_email
    )
    VALUES (
        'wf04_test',
        'event-wf04-' || p_suffix,
        'deal-wf04-' || p_suffix,
        'WF04 Test Company ' || p_suffix,
        'wf04-' || p_suffix || '@example.com'
    )
    RETURNING
        id,
        correlation_id
    INTO
        created_case_id,
        created_correlation_id;

    UPDATE onboarding_cases
    SET state = 'awaiting_client_data'
    WHERE id = created_case_id;

    v_token_hash :=
        digest(
            'wf04-token-' || p_suffix,
            'sha256'
        );

    INSERT INTO onboarding_form_tokens (
        case_id,
        request_cycle_key,
        token_hash,
        token_ciphertext,
        token_nonce,
        token_auth_tag,
        encryption_key_id,
        expires_at
    )
    VALUES (
        created_case_id,
        'initial',
        v_token_hash,
        decode('00112233', 'hex'),
        decode('00112233445566778899aabb', 'hex'),
        decode('00112233445566778899aabbccddeeff', 'hex'),
        'wf04-test-key',
        clock_timestamp() + interval '1 hour'
    );

    UPDATE onboarding_form_tokens
    SET
        status = 'delivered',
        delivered_at = clock_timestamp(),
        token_ciphertext = NULL,
        token_nonce = NULL,
        token_auth_tag = NULL,
        encryption_key_id = NULL
    WHERE token_hash = v_token_hash;

    SELECT result.created_submission_id
    INTO STRICT created_submission_id
    FROM consume_form_token_and_create_submission(
        v_token_hash,
        jsonb_build_object(
            'test_suffix',
            p_suffix
        ),
        jsonb_build_object(
            'company_identifier_country',
            'PL',
            'company_identifier_type',
            'nip',
            'company_identifier_value',
            substring(md5(p_suffix), 1, 10),
            'company_identifier_value_normalized',
            substring(md5(p_suffix), 1, 10),
            'legal_name',
            'WF04 Test Company ' || p_suffix,
            'primary_contact_first_name',
            'Manual',
            'primary_contact_last_name',
            'Approver',
            'primary_contact_email',
            'wf04-' || p_suffix || '@example.com',
            'primary_contact_phone',
            '+48111111111'
        )
    ) AS result
    WHERE result.consume_outcome = 'created';

    UPDATE onboarding_submissions
    SET
        validation_status = 'passed',
        validation_errors = '[]'::jsonb,
        validated_at = clock_timestamp()
    WHERE id = created_submission_id;

    INSERT INTO clients (
        company_identifier_country,
        company_identifier_type,
        company_identifier_value,
        company_identifier_value_normalized,
        legal_name,
        primary_contact_first_name,
        primary_contact_last_name,
        primary_contact_email,
        primary_contact_phone,
        source_submission_id
    )
    VALUES (
        'PL',
        'nip',
        substring(md5(p_suffix), 1, 10),
        substring(md5(p_suffix), 1, 10),
        'WF04 Test Company ' || p_suffix,
        'Manual',
        'Approver',
        'wf04-' || p_suffix || '@example.com',
        '+48111111111',
        created_submission_id
    )
    RETURNING id
    INTO created_client_id;

    UPDATE onboarding_steps
    SET
        status = 'completed',
        started_at = COALESCE(
            started_at,
            clock_timestamp()
        ),
        completed_at = clock_timestamp(),
        last_error_summary = NULL
    WHERE case_id = created_case_id
      AND step_type IN (
          'collect_client_data',
          'validate_client_data'
      );

    UPDATE onboarding_cases
    SET
        client_id = created_client_id,
        accepted_submission_id = created_submission_id,
        state = 'awaiting_approval'
    WHERE id = created_case_id;

    RETURN NEXT;
END;
$$;


CREATE FUNCTION pg_temp.run_wf04_decision_test(
    p_suffix text,
    p_decision text,
    p_marker text,
    p_execution_id text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_case_id uuid;
    v_correlation_id uuid;
    v_submission_id uuid;
    v_client_id uuid;

    v_prepare record;
    v_duplicate_prepare record;
    v_finalize record;
    v_duplicate_finalize record;

    v_expected_state text;
    v_step_status text;
    v_step_decision text;
    v_stored_execution_id text;
    v_operation_status text;
    v_operation_request jsonb;
    v_event_count integer;
BEGIN
    IF p_decision NOT IN (
        'approved',
        'rejected'
    ) THEN
        RAISE EXCEPTION
            'Test decision must be approved or rejected';
    END IF;

    SELECT fixture.*
    INTO
        v_case_id,
        v_correlation_id,
        v_submission_id,
        v_client_id
    FROM pg_temp.create_wf04_test_case(
        p_suffix
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
        p_execution_id,
        'Operator@Example.com',
        'manual_approval_v1',
        p_marker,
        168,
        608400,
        3
    ) AS result;

    IF v_prepare.preparation_outcome
            IS DISTINCT FROM 'ready_to_send'
        OR v_prepare.operation_claim_outcome
            IS DISTINCT FROM 'claimed'
        OR v_prepare.operation_status
            IS DISTINCT FROM 'in_progress'
        OR v_prepare.approval_step_status
            IS DISTINCT FROM 'waiting'
        OR v_prepare.recipient_email
            IS DISTINCT FROM 'operator@example.com'
        OR v_prepare.operation_attempt_count
            IS DISTINCT FROM 1
    THEN
        RAISE EXCEPTION
            'Unexpected WF04 preparation result: %',
            row_to_json(v_prepare);
    END IF;

    SELECT
        operation.status,
        operation.request_summary
    INTO STRICT
        v_operation_status,
        v_operation_request
    FROM external_operations AS operation
    WHERE operation.id = v_prepare.operation_id;

    IF v_operation_status <> 'in_progress'
        OR v_operation_request ? 'waiting_execution_id'
        OR v_operation_request ->> 'recipient_email'
            IS DISTINCT FROM 'operator@example.com'
        OR v_operation_request ->> 'message_marker'
            IS DISTINCT FROM p_marker
    THEN
        RAISE EXCEPTION
            'Approval operation request contract is invalid: %',
            v_operation_request;
    END IF;

    SELECT result.*
    INTO STRICT v_duplicate_prepare
    FROM prepare_wf04_approval_request(
        v_case_id,
        v_correlation_id,
        'wf03',
        v_submission_id,
        v_client_id,
        NULL,
        NULL,
        p_execution_id || '-duplicate',
        'operator@example.com',
        'manual_approval_v1',
        p_marker,
        168,
        608400,
        3
    ) AS result;

    IF v_duplicate_prepare.preparation_outcome
            IS DISTINCT FROM 'active_wait_exists'
        OR v_duplicate_prepare.operation_claim_outcome
            IS DISTINCT FROM 'busy'
        OR v_duplicate_prepare.waiting_execution_id
            IS DISTINCT FROM p_execution_id
    THEN
        RAISE EXCEPTION
            'Duplicate invocation replaced or lost the active wait: %',
            row_to_json(v_duplicate_prepare);
    END IF;

    SELECT step.n8n_wait_execution_id
    INTO STRICT v_stored_execution_id
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case_id
      AND step.step_type = 'manual_approval';

    IF v_stored_execution_id
        IS DISTINCT FROM p_execution_id
    THEN
        RAISE EXCEPTION
            'Duplicate invocation changed the stored execution id';
    END IF;

    SELECT result.*
    INTO STRICT v_finalize
    FROM finalize_wf04_approval_decision(
        v_case_id,
        v_prepare.operation_id,
        'WF04:' || p_execution_id,
        p_execution_id,
        'operator@example.com',
        p_decision,
        clock_timestamp(),
        'gmail-' || p_suffix,
        'thread-' || p_suffix,
        'Reviewed by integration test',
        'n8n_send_and_wait'
    ) AS result;

    v_expected_state :=
        CASE
            WHEN p_decision = 'approved'
                THEN 'approved'
            ELSE 'rejected'
        END;

    IF v_finalize.finalization_outcome
            IS DISTINCT FROM 'finalized'
        OR v_finalize.final_case_state
            IS DISTINCT FROM v_expected_state
        OR v_finalize.final_step_status
            IS DISTINCT FROM 'completed'
        OR v_finalize.final_decision
            IS DISTINCT FROM p_decision
        OR v_finalize.final_operation_status
            IS DISTINCT FROM 'succeeded'
    THEN
        RAISE EXCEPTION
            'Unexpected WF04 decision finalization: %',
            row_to_json(v_finalize);
    END IF;

    SELECT
        step.status,
        step.approval_decision,
        step.n8n_wait_execution_id
    INTO STRICT
        v_step_status,
        v_step_decision,
        v_stored_execution_id
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case_id
      AND step.step_type = 'manual_approval';

    SELECT operation.status
    INTO STRICT v_operation_status
    FROM external_operations AS operation
    WHERE operation.id = v_prepare.operation_id;

    IF v_step_status <> 'completed'
        OR v_step_decision
            IS DISTINCT FROM p_decision
        OR v_stored_execution_id
            IS DISTINCT FROM p_execution_id
        OR v_operation_status <> 'succeeded'
    THEN
        RAISE EXCEPTION
            'Persisted WF04 decision state is inconsistent';
    END IF;

    SELECT count(*)
    INTO v_event_count
    FROM onboarding_events AS event
    WHERE event.case_id = v_case_id
      AND event.event_type =
          CASE
              WHEN p_decision = 'approved'
                  THEN 'manual_approval_approved'
              ELSE 'manual_approval_rejected'
          END;

    IF v_event_count <> 1 THEN
        RAISE EXCEPTION
            'Expected one decision event, got %',
            v_event_count;
    END IF;

    SELECT result.*
    INTO STRICT v_duplicate_finalize
    FROM finalize_wf04_approval_decision(
        v_case_id,
        v_prepare.operation_id,
        'WF04:' || p_execution_id,
        p_execution_id,
        'operator@example.com',
        p_decision,
        clock_timestamp(),
        'gmail-' || p_suffix,
        'thread-' || p_suffix,
        NULL,
        'n8n_send_and_wait'
    ) AS result;

    IF v_duplicate_finalize.finalization_outcome
        IS DISTINCT FROM 'already_finalized'
    THEN
        RAISE EXCEPTION
            'Duplicate response was not idempotent: %',
            row_to_json(v_duplicate_finalize);
    END IF;

    RAISE NOTICE
        'PASS: WF04 % decision is atomic and idempotent',
        p_decision;
END;
$$;


DO $$
DECLARE
    v_case_id uuid;
    v_correlation_id uuid;
    v_submission_id uuid;
    v_client_id uuid;

    v_invalid_config_rejected boolean := false;
    v_step_status text;
    v_operation_count integer;
BEGIN
    SELECT fixture.*
    INTO
        v_case_id,
        v_correlation_id,
        v_submission_id,
        v_client_id
    FROM pg_temp.create_wf04_test_case(
        'invalid-config'
    ) AS fixture;

    BEGIN
        PERFORM *
        FROM prepare_wf04_approval_request(
            v_case_id,
            v_correlation_id,
            'wf03',
            v_submission_id,
            v_client_id,
            NULL,
            NULL,
            'wf04-invalid-config',
            'invalid-recipient',
            'manual_approval_v1',
            'b2b-approval-dddddddddddddddddddddddd',
            168,
            608400,
            3
        );
    EXCEPTION
        WHEN others THEN
            IF SQLERRM IS DISTINCT FROM
                'recipient_email is invalid'
            THEN
                RAISE;
            END IF;

            v_invalid_config_rejected :=
                true;
    END;

    SELECT step.status
    INTO STRICT v_step_status
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case_id
      AND step.step_type = 'manual_approval';

    SELECT count(*)
    INTO v_operation_count
    FROM external_operations AS operation
    WHERE operation.case_id = v_case_id
      AND operation.operation_type =
          'send_approval_request';

    IF NOT v_invalid_config_rejected
        OR v_step_status <> 'pending'
        OR v_operation_count <> 0
    THEN
        RAISE EXCEPTION
            'Invalid configuration left partial WF04 state';
    END IF;

    RAISE NOTICE
        'PASS: invalid WF04 configuration left no partial state';
END;
$$;


SELECT pg_temp.run_wf04_decision_test(
    'approved',
    'approved',
    'b2b-approval-aaaaaaaaaaaaaaaaaaaaaaaa',
    'wf04-approved-execution'
);

SELECT pg_temp.run_wf04_decision_test(
    'rejected',
    'rejected',
    'b2b-approval-bbbbbbbbbbbbbbbbbbbbbbbb',
    'wf04-rejected-execution'
);


DO $$
DECLARE
    v_case_id uuid;
    v_correlation_id uuid;
    v_submission_id uuid;
    v_client_id uuid;

    v_prepare record;
    v_failure record;
    v_not_due record;
    v_retry_prepare record;

    v_step_status text;
    v_stored_execution_id text;
    v_stored_recipient text;
    v_operation_status text;
    v_next_retry_at timestamptz;
BEGIN
    SELECT fixture.*
    INTO
        v_case_id,
        v_correlation_id,
        v_submission_id,
        v_client_id
    FROM pg_temp.create_wf04_test_case(
        'retry'
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
        'wf04-retry-execution-1',
        'operator@example.com',
        'manual_approval_v1',
        'b2b-approval-cccccccccccccccccccccccc',
        168,
        608400,
        3
    ) AS result;

    SELECT result.*
    INTO STRICT v_failure
    FROM finalize_wf04_approval_failure(
        v_case_id,
        v_prepare.operation_id,
        'WF04:wf04-retry-execution-1',
        'wf04-retry-execution-1',
        'operator@example.com',
        true,
        'temporary_gmail_failure',
        jsonb_build_object(
            'provider',
            'gmail',
            'status_code',
            503
        ),
        clock_timestamp() + interval '10 minutes'
    ) AS result;

    IF v_failure.finalization_outcome
            IS DISTINCT FROM 'finalized'
        OR v_failure.final_operation_status
            IS DISTINCT FROM 'failed_retryable'
        OR v_failure.final_step_status
            IS DISTINCT FROM 'failed_retryable'
        OR v_failure.final_case_state
            IS DISTINCT FROM 'awaiting_approval'
    THEN
        RAISE EXCEPTION
            'Unexpected retryable failure result: %',
            row_to_json(v_failure);
    END IF;

    SELECT
        step.status,
        step.n8n_wait_execution_id,
        step.approval_recipient_email
    INTO STRICT
        v_step_status,
        v_stored_execution_id,
        v_stored_recipient
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case_id
      AND step.step_type = 'manual_approval';

    SELECT
        operation.status,
        operation.next_retry_at
    INTO STRICT
        v_operation_status,
        v_next_retry_at
    FROM external_operations AS operation
    WHERE operation.id = v_prepare.operation_id;

    IF v_step_status <> 'failed_retryable'
        OR v_stored_execution_id IS NOT NULL
        OR v_stored_recipient IS NOT NULL
        OR v_operation_status <> 'failed_retryable'
        OR v_next_retry_at IS NULL
    THEN
        RAISE EXCEPTION
            'Retryable failure left a false active wait';
    END IF;

    SELECT result.*
    INTO STRICT v_not_due
    FROM prepare_wf04_approval_request(
        v_case_id,
        v_correlation_id,
        'wf98',
        NULL,
        NULL,
        v_prepare.operation_id,
        NULL,
        'wf04-retry-execution-2',
        'operator@example.com',
        'manual_approval_v1',
        'b2b-approval-cccccccccccccccccccccccc',
        168,
        608400,
        3
    ) AS result;

    IF v_not_due.preparation_outcome
            IS DISTINCT FROM 'not_due'
        OR v_not_due.operation_claim_outcome
            IS DISTINCT FROM 'not_due'
    THEN
        RAISE EXCEPTION
            'Future retry was not blocked: %',
            row_to_json(v_not_due);
    END IF;

    UPDATE external_operations
    SET next_retry_at =
        clock_timestamp() - interval '1 second'
    WHERE id = v_prepare.operation_id;

    SELECT result.*
    INTO STRICT v_retry_prepare
    FROM prepare_wf04_approval_request(
        v_case_id,
        v_correlation_id,
        'wf98',
        NULL,
        NULL,
        v_prepare.operation_id,
        NULL,
        'wf04-retry-execution-2',
        'operator@example.com',
        'manual_approval_v1',
        'b2b-approval-cccccccccccccccccccccccc',
        168,
        608400,
        3
    ) AS result;

    IF v_retry_prepare.preparation_outcome
            IS DISTINCT FROM 'ready_to_send'
        OR v_retry_prepare.operation_claim_outcome
            IS DISTINCT FROM 'claimed'
        OR v_retry_prepare.operation_attempt_count
            IS DISTINCT FROM 2
        OR v_retry_prepare.waiting_execution_id
            IS DISTINCT FROM 'wf04-retry-execution-2'
    THEN
        RAISE EXCEPTION
            'Due retry was not atomically prepared: %',
            row_to_json(v_retry_prepare);
    END IF;

    SELECT
        step.status,
        step.n8n_wait_execution_id,
        step.approval_recipient_email
    INTO STRICT
        v_step_status,
        v_stored_execution_id,
        v_stored_recipient
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case_id
      AND step.step_type = 'manual_approval';

    IF v_step_status <> 'waiting'
        OR v_stored_execution_id
            IS DISTINCT FROM 'wf04-retry-execution-2'
        OR v_stored_recipient
            IS DISTINCT FROM 'operator@example.com'
    THEN
        RAISE EXCEPTION
            'Due retry did not establish the new active wait';
    END IF;

    RAISE NOTICE
        'PASS: WF04 retry preparation is due-aware and atomic';
END;
$$;


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

ROLLBACK;
