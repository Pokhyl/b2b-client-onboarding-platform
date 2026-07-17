\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
    v_case_id uuid;
    v_step_count integer;
BEGIN
    INSERT INTO onboarding_cases (
        source_system,
        source_event_id,
        source_deal_id,
        intake_company_name,
        intake_contact_email
    )
    VALUES (
        'test_crm',
        'event-foundation-001',
        'deal-foundation-001',
        'Foundation Test Company',
        'foundation@example.com'
    )
    RETURNING id INTO v_case_id;

    SELECT count(*)
    INTO v_step_count
    FROM onboarding_steps
    WHERE case_id = v_case_id;

    IF v_step_count <> 7 THEN
        RAISE EXCEPTION
            'Expected 7 onboarding steps, got %',
            v_step_count;
    END IF;

    RAISE NOTICE
        'PASS: onboarding case automatically created 7 steps';
END;
$$;
DO $$
BEGIN
    BEGIN
        INSERT INTO onboarding_cases (
            source_system,
            source_event_id,
            source_deal_id,
            intake_company_name,
            intake_contact_email
        )
        VALUES (
            'test_crm',
            'event-foundation-duplicate-deal',
            'deal-foundation-001',
            'Duplicate Deal Company',
            'duplicate@example.com'
        );

        RAISE EXCEPTION
            'Expected duplicate source deal to be rejected';
    EXCEPTION
        WHEN unique_violation THEN
            RAISE NOTICE
                'PASS: duplicate source deal was rejected';
    END;
END;
$$;
DO $$
BEGIN
    BEGIN
        INSERT INTO onboarding_cases (
            source_system,
            source_event_id,
            source_deal_id,
            intake_company_name,
            intake_contact_email
        )
        VALUES (
            'test_crm',
            'event-foundation-001',
            'deal-foundation-different',
            'Duplicate Event Company',
            'duplicate-event@example.com'
        );

        RAISE EXCEPTION
            'Expected duplicate source event to be rejected';
    EXCEPTION
        WHEN unique_violation THEN
            RAISE NOTICE
                'PASS: duplicate source event was rejected';
    END;
END;
$$;
DO $$
DECLARE
    v_actual_step_types text[];
    v_expected_step_types text[] := ARRAY[
        'collect_client_data',
        'create_drive_folder',
        'create_kickoff_event',
        'manual_approval',
        'notify_team',
        'provision_client',
        'validate_client_data'
    ];
BEGIN
    SELECT array_agg(step.step_type ORDER BY step.step_type)
    INTO v_actual_step_types
    FROM onboarding_steps AS step
    JOIN onboarding_cases AS onboarding_case
        ON onboarding_case.id = step.case_id
    WHERE onboarding_case.source_system = 'test_crm'
      AND onboarding_case.source_event_id = 'event-foundation-001';

    IF v_actual_step_types IS DISTINCT FROM v_expected_step_types THEN
        RAISE EXCEPTION
            'Expected step types %, got %',
            v_expected_step_types,
            v_actual_step_types;
    END IF;

    RAISE NOTICE
        'PASS: onboarding case created the correct step types';
END;
$$;
DO $$
DECLARE
    v_case_id uuid;
    v_state text;
    v_invalid_transition_rejected boolean := false;
BEGIN
    SELECT id
    INTO STRICT v_case_id
    FROM onboarding_cases
    WHERE source_system = 'test_crm'
      AND source_event_id = 'event-foundation-001';

    UPDATE onboarding_cases
    SET state = 'awaiting_client_data'
    WHERE id = v_case_id
    RETURNING state INTO v_state;

    IF v_state <> 'awaiting_client_data' THEN
        RAISE EXCEPTION
            'Expected state awaiting_client_data, got %',
            v_state;
    END IF;

    RAISE NOTICE
        'PASS: valid case transition was accepted';

    BEGIN
        UPDATE onboarding_cases
        SET state = 'validation_failed'
        WHERE id = v_case_id;
    EXCEPTION
        WHEN raise_exception THEN
            v_invalid_transition_rejected := true;
    END;

    IF NOT v_invalid_transition_rejected THEN
        RAISE EXCEPTION
            'Expected invalid case transition to be rejected';
    END IF;

    RAISE NOTICE
        'PASS: invalid case transition was rejected';
END;
$$;
DO $$
DECLARE
    v_case_id uuid;
    v_token_id uuid;
    v_token_status text;
    v_ciphertext_cleared boolean;
    v_second_active_token_rejected boolean := false;
BEGIN
    SELECT id
    INTO STRICT v_case_id
    FROM onboarding_cases
    WHERE source_system = 'test_crm'
      AND source_event_id = 'event-foundation-001';

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
        v_case_id,
        'cycle-foundation-001',
        digest('foundation-token-001', 'sha256'),
        decode('00112233', 'hex'),
        decode('00112233445566778899aabb', 'hex'),
        decode('00112233445566778899aabbccddeeff', 'hex'),
        'test-key-001',
        clock_timestamp() + interval '1 hour'
    )
    RETURNING id INTO v_token_id;

    RAISE NOTICE
        'PASS: active form token was created';

    BEGIN
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
            v_case_id,
            'cycle-foundation-002',
            digest('foundation-token-002', 'sha256'),
            decode('11223344', 'hex'),
            decode('112233445566778899aabbcc', 'hex'),
            decode('112233445566778899aabbccddeeff00', 'hex'),
            'test-key-001',
            clock_timestamp() + interval '1 hour'
        );
    EXCEPTION
        WHEN unique_violation THEN
            v_second_active_token_rejected := true;
    END;

    IF NOT v_second_active_token_rejected THEN
        RAISE EXCEPTION
            'Expected second active form token to be rejected';
    END IF;

    RAISE NOTICE
        'PASS: second active form token was rejected';

    UPDATE onboarding_form_tokens
    SET
        status = 'delivered',
        token_ciphertext = NULL,
        token_nonce = NULL,
        token_auth_tag = NULL,
        encryption_key_id = NULL,
        delivered_at = clock_timestamp()
    WHERE id = v_token_id
    RETURNING
        status,
        token_ciphertext IS NULL
    INTO
        v_token_status,
        v_ciphertext_cleared;

    IF v_token_status <> 'delivered'
       OR NOT v_ciphertext_cleared THEN
        RAISE EXCEPTION
            'Expected delivered token with cleared ciphertext';
    END IF;

    RAISE NOTICE
        'PASS: delivered token cleared encrypted material';
END;
$$;
DO $$
DECLARE
    v_expected_case_id uuid;
    v_returned_case_id uuid;
    v_submission_id uuid;
    v_submission_sequence integer;
    v_consume_outcome text;
    v_token_status text;
    v_submission_status text;
    v_case_state text;
BEGIN
    SELECT id
    INTO STRICT v_expected_case_id
    FROM onboarding_cases
    WHERE source_system = 'test_crm'
      AND source_event_id = 'event-foundation-001';

    SELECT
        consume_outcome,
        created_submission_id,
        onboarding_case_id,
        created_submission_sequence
    INTO
        v_consume_outcome,
        v_submission_id,
        v_returned_case_id,
        v_submission_sequence
    FROM consume_form_token_and_create_submission(
        digest('foundation-token-001', 'sha256'),
        '{
            "legal_name": "Foundation Test Company",
            "contact_email": "foundation@example.com"
        }'::jsonb,
        '{
            "legal_name": "Foundation Test Company",
            "contact_email": "foundation@example.com"
        }'::jsonb
    );

    SELECT status
    INTO STRICT v_token_status
    FROM onboarding_form_tokens
    WHERE token_hash = digest('foundation-token-001', 'sha256');

    SELECT validation_status
    INTO STRICT v_submission_status
    FROM onboarding_submissions
    WHERE id = v_submission_id;

    SELECT state
    INTO STRICT v_case_state
    FROM onboarding_cases
    WHERE id = v_expected_case_id;

    IF v_submission_id IS NULL
       OR v_returned_case_id IS DISTINCT FROM v_expected_case_id
       OR v_submission_sequence <> 1
       OR v_token_status <> 'consumed'
       OR v_submission_status <> 'pending'
       OR v_case_state <> 'data_received' THEN
        RAISE EXCEPTION
            'Token consumption failed: outcome=%, sequence=%, token=%, submission=%, case=%',
            v_consume_outcome,
            v_submission_sequence,
            v_token_status,
            v_submission_status,
            v_case_state;
    END IF;

    RAISE NOTICE
        'PASS: token consumption atomically created submission and advanced case';
END;
$$;
DO $$
DECLARE
    v_case_id uuid;
    v_submission_count_before integer;
    v_submission_count_after integer;
    v_token_status text;
    v_reuse_outcome text;
BEGIN
    SELECT id
    INTO STRICT v_case_id
    FROM onboarding_cases
    WHERE source_system = 'test_crm'
      AND source_event_id = 'event-foundation-001';

    SELECT count(*)
    INTO v_submission_count_before
    FROM onboarding_submissions
    WHERE case_id = v_case_id;

    SELECT consume_outcome
    INTO v_reuse_outcome
    FROM consume_form_token_and_create_submission(
        digest('foundation-token-001', 'sha256'),
        '{"attempt": "second"}'::jsonb,
        '{"attempt": "second"}'::jsonb
    );

    SELECT count(*)
    INTO v_submission_count_after
    FROM onboarding_submissions
    WHERE case_id = v_case_id;

    SELECT status
    INTO STRICT v_token_status
    FROM onboarding_form_tokens
    WHERE token_hash = digest('foundation-token-001', 'sha256');

    IF v_reuse_outcome IS DISTINCT FROM 'already_consumed'
       OR v_submission_count_before <> 1
       OR v_submission_count_after <> 1
       OR v_token_status <> 'consumed' THEN
        RAISE EXCEPTION
            'Unexpected token reuse result: outcome=%, before=%, after=%, status=%',
            v_reuse_outcome,
            v_submission_count_before,
            v_submission_count_after,
            v_token_status;
    END IF;

    RAISE NOTICE
        'PASS: consumed token returned already_consumed without a second submission';
END;
$$;
DO $$
DECLARE
    v_case_id uuid;
    v_submission_id uuid;
    v_client_id uuid;
    v_case_state text;
    v_pending_client_rejected boolean := false;
BEGIN
    SELECT id
    INTO STRICT v_case_id
    FROM onboarding_cases
    WHERE source_system = 'test_crm'
      AND source_event_id = 'event-foundation-001';

    SELECT id
    INTO STRICT v_submission_id
    FROM onboarding_submissions
    WHERE case_id = v_case_id
      AND submission_sequence = 1;

    BEGIN
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
            'NIP',
            '123-456-78-90',
            '1234567890',
            'Foundation Test Company',
            'Test',
            'Contact',
            'foundation@example.com',
            '+48123456789',
            v_submission_id
        );
    EXCEPTION
        WHEN raise_exception THEN
            v_pending_client_rejected := true;
    END;

    IF NOT v_pending_client_rejected THEN
        RAISE EXCEPTION
            'Expected pending submission to be rejected as client source';
    END IF;

    RAISE NOTICE
        'PASS: pending submission could not create canonical client';

    UPDATE onboarding_submissions
    SET
        validation_status = 'passed',
        validation_errors = '[]'::jsonb,
        validated_at = clock_timestamp()
    WHERE id = v_submission_id;

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
        'NIP',
        '123-456-78-90',
        '1234567890',
        'Foundation Test Company',
        'Test',
        'Contact',
        'foundation@example.com',
        '+48123456789',
        v_submission_id
    )
    RETURNING id INTO v_client_id;

    IF v_client_id IS NULL THEN
        RAISE EXCEPTION
            'Expected passed submission to create canonical client';
    END IF;

    RAISE NOTICE
        'PASS: passed submission created canonical client';

    UPDATE onboarding_cases
    SET
        client_id = v_client_id,
        accepted_submission_id = v_submission_id,
        state = 'awaiting_approval'
    WHERE id = v_case_id
    RETURNING state INTO v_case_state;

    IF v_case_state <> 'awaiting_approval' THEN
        RAISE EXCEPTION
            'Expected case state awaiting_approval, got %',
            v_case_state;
    END IF;

    RAISE NOTICE
        'PASS: validated client advanced case to awaiting_approval';
END;
$$;
DO $$
DECLARE
    v_submission_id uuid;
    v_update_rejected boolean := false;
    v_delete_rejected boolean := false;
BEGIN
    SELECT submission.id
    INTO STRICT v_submission_id
    FROM onboarding_submissions AS submission
    JOIN onboarding_cases AS onboarding_case
        ON onboarding_case.id = submission.case_id
    WHERE onboarding_case.source_system = 'test_crm'
      AND onboarding_case.source_event_id = 'event-foundation-001'
      AND submission.submission_sequence = 1;

    BEGIN
        UPDATE onboarding_submissions
        SET normalized_data = '{"tampered": true}'::jsonb
        WHERE id = v_submission_id;
    EXCEPTION
        WHEN raise_exception THEN
            v_update_rejected := true;
    END;

    IF NOT v_update_rejected THEN
        RAISE EXCEPTION
            'Expected passed submission update to be rejected';
    END IF;

    RAISE NOTICE
        'PASS: passed submission could not be modified';

    BEGIN
        DELETE FROM onboarding_submissions
        WHERE id = v_submission_id;
    EXCEPTION
        WHEN raise_exception THEN
            v_delete_rejected := true;
    END;

    IF NOT v_delete_rejected THEN
        RAISE EXCEPTION
            'Expected passed submission deletion to be rejected';
    END IF;

    RAISE NOTICE
        'PASS: passed submission could not be deleted';
END;
$$;
DO $$
DECLARE
    v_case_id uuid;
    v_correlation_id uuid;
    v_event_id uuid;
    v_duplicate_rejected boolean := false;
    v_update_rejected boolean := false;
    v_delete_rejected boolean := false;
BEGIN
    SELECT id, correlation_id
    INTO STRICT v_case_id, v_correlation_id
    FROM onboarding_cases
    WHERE source_system = 'test_crm'
      AND source_event_id = 'event-foundation-001';

    INSERT INTO onboarding_events (
        case_id,
        event_key,
        event_type,
        actor_type,
        actor_identifier,
        previous_state,
        new_state,
        event_data,
        correlation_id
    )
    VALUES (
        v_case_id,
        'foundation:event:awaiting-approval',
        'case_awaiting_approval',
        'test',
        'foundation-checks',
        'data_received',
        'awaiting_approval',
        '{"source": "foundation-check"}'::jsonb,
        v_correlation_id
    )
    RETURNING id INTO v_event_id;

    RAISE NOTICE
        'PASS: onboarding event was created';

    BEGIN
        INSERT INTO onboarding_events (
            case_id,
            event_key,
            event_type,
            actor_type,
            previous_state,
            new_state,
            event_data,
            correlation_id
        )
        VALUES (
            v_case_id,
            'foundation:event:awaiting-approval',
            'duplicate_event',
            'test',
            'data_received',
            'awaiting_approval',
            '{}'::jsonb,
            v_correlation_id
        );
    EXCEPTION
        WHEN unique_violation THEN
            v_duplicate_rejected := true;
    END;

    IF NOT v_duplicate_rejected THEN
        RAISE EXCEPTION
            'Expected duplicate event key to be rejected';
    END IF;

    RAISE NOTICE
        'PASS: duplicate onboarding event key was rejected';

    BEGIN
        UPDATE onboarding_events
        SET event_data = '{"tampered": true}'::jsonb
        WHERE id = v_event_id;
    EXCEPTION
        WHEN raise_exception THEN
            v_update_rejected := true;
    END;

    BEGIN
        DELETE FROM onboarding_events
        WHERE id = v_event_id;
    EXCEPTION
        WHEN raise_exception THEN
            v_delete_rejected := true;
    END;

    IF NOT v_update_rejected OR NOT v_delete_rejected THEN
        RAISE EXCEPTION
            'Append-only event protection failed: update=%, delete=%',
            v_update_rejected,
            v_delete_rejected;
    END IF;

    RAISE NOTICE
        'PASS: onboarding event could not be modified or deleted';
END;
$$;
DO $$
DECLARE
    v_case_id uuid;
    v_operation_id uuid;
    v_second_operation_id uuid;
    v_reused_operation_id uuid;
    v_first_outcome text;
    v_second_outcome text;
    v_reuse_outcome text;
    v_operation_status text;
    v_attempt integer;
    v_completed boolean;
    v_external_id text;
BEGIN
    SELECT id
    INTO STRICT v_case_id
    FROM onboarding_cases
    WHERE source_system = 'test_crm'
      AND source_event_id = 'event-foundation-001';

    SELECT
        operation_id,
        claim_outcome,
        operation_status,
        current_attempt_count
    INTO
        v_operation_id,
        v_first_outcome,
        v_operation_status,
        v_attempt
    FROM claim_external_operation(
        'foundation:send-approval-request',
        'send_approval_request',
        v_case_id,
        'worker-a',
        300,
        3,
        '{"recipient": "approver@example.com"}'::jsonb
    );

    IF v_first_outcome IS DISTINCT FROM 'claimed'
       OR v_operation_status <> 'in_progress'
       OR v_attempt <> 1 THEN
        RAISE EXCEPTION
            'First claim failed: outcome=%, status=%, attempt=%',
            v_first_outcome,
            v_operation_status,
            v_attempt;
    END IF;

    RAISE NOTICE
        'PASS: first worker claimed external operation';

    SELECT
        operation_id,
        claim_outcome
    INTO
        v_second_operation_id,
        v_second_outcome
    FROM claim_external_operation(
        'foundation:send-approval-request',
        'send_approval_request',
        v_case_id,
        'worker-b',
        300,
        3,
        '{"recipient": "approver@example.com"}'::jsonb
    );

    IF v_second_operation_id IS DISTINCT FROM v_operation_id
       OR v_second_outcome IS DISTINCT FROM 'busy' THEN
        RAISE EXCEPTION
            'Concurrent claim was not blocked: operation=%, outcome=%',
            v_second_operation_id,
            v_second_outcome;
    END IF;

    RAISE NOTICE
        'PASS: second worker received busy for leased operation';

    SELECT complete_external_operation_success(
        v_operation_id,
        'worker-a',
        'message-foundation-001',
        '{"delivery": "accepted"}'::jsonb
    )
    INTO v_completed;

    IF v_completed IS DISTINCT FROM true THEN
        RAISE EXCEPTION
            'Lease owner could not complete external operation';
    END IF;

    SELECT
        operation_id,
        claim_outcome,
        operation_status,
        current_external_id
    INTO
        v_reused_operation_id,
        v_reuse_outcome,
        v_operation_status,
        v_external_id
    FROM claim_external_operation(
        'foundation:send-approval-request',
        'send_approval_request',
        v_case_id,
        'worker-c',
        300,
        3,
        '{"recipient": "approver@example.com"}'::jsonb
    );

    IF v_reused_operation_id IS DISTINCT FROM v_operation_id
       OR v_reuse_outcome IS DISTINCT FROM 'reuse_succeeded'
       OR v_operation_status <> 'succeeded'
       OR v_external_id <> 'message-foundation-001' THEN
        RAISE EXCEPTION
            'Succeeded operation was not reused: outcome=%, status=%, external_id=%',
            v_reuse_outcome,
            v_operation_status,
            v_external_id;
    END IF;

    RAISE NOTICE
        'PASS: succeeded external operation was reused without duplication';
END;
$$;
DO $$
DECLARE
    v_case_id uuid;
    v_step_id uuid;
    v_submission_id uuid;
    v_external_operation_id uuid;
    v_correlation_id uuid;
    v_error_id uuid;
    v_invalid_details_rejected boolean := false;
BEGIN
    SELECT id, correlation_id
    INTO STRICT v_case_id, v_correlation_id
    FROM onboarding_cases
    WHERE source_system = 'test_crm'
      AND source_event_id = 'event-foundation-001';

    SELECT id
    INTO STRICT v_step_id
    FROM onboarding_steps
    WHERE case_id = v_case_id
      AND step_type = 'manual_approval';

    SELECT id
    INTO STRICT v_submission_id
    FROM onboarding_submissions
    WHERE case_id = v_case_id
      AND submission_sequence = 1;

    SELECT id
    INTO STRICT v_external_operation_id
    FROM external_operations
    WHERE idempotency_key = 'foundation:send-approval-request';

    INSERT INTO error_log (
        case_id,
        step_id,
        submission_id,
        external_operation_id,
        workflow_name,
        workflow_id,
        execution_id,
        error_class,
        error_code,
        error_message,
        retryable,
        severity,
        error_details,
        correlation_id
    )
    VALUES (
        v_case_id,
        v_step_id,
        v_submission_id,
        v_external_operation_id,
        'WF04 Manual Approval',
        'wf04-foundation',
        'execution-foundation-001',
        'ExternalApiError',
        'APPROVAL_EMAIL_FAILED',
        'Test approval email delivery failure',
        true,
        'error',
        '{"provider": "test", "safe": true}'::jsonb,
        v_correlation_id
    )
    RETURNING id INTO v_error_id;

    IF v_error_id IS NULL THEN
        RAISE EXCEPTION
            'Expected technical error to be logged';
    END IF;

    RAISE NOTICE
        'PASS: technical error was logged with related records';

    BEGIN
        INSERT INTO error_log (
            workflow_name,
            error_class,
            error_message,
            retryable,
            severity,
            error_details
        )
        VALUES (
            'WF00 Invalid Error Test',
            'InvalidDetailsError',
            'Details must be an object',
            false,
            'warning',
            '[]'::jsonb
        );
    EXCEPTION
        WHEN check_violation THEN
            v_invalid_details_rejected := true;
    END;

    IF NOT v_invalid_details_rejected THEN
        RAISE EXCEPTION
            'Expected non-object error details to be rejected';
    END IF;

    RAISE NOTICE
        'PASS: invalid error details were rejected';
END;
$$;

ROLLBACK;