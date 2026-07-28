\set ON_ERROR_STOP on

BEGIN;

CREATE FUNCTION pg_temp.wf06_test_configuration()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT jsonb_build_object(
        'drive_parent_folder_id',
        'wf06-test-parent',
        'drive_folder_name_template',
        '{legal_name} Onboarding',
        'drive_use_shared_drive',
        false,
        'calendar_id',
        'wf06-test-calendar@example.com',
        'kickoff_timezone',
        'Europe/Warsaw',
        'kickoff_delay_days',
        2,
        'kickoff_start_local_time',
        '10:00',
        'kickoff_duration_minutes',
        60,
        'kickoff_internal_attendee_email',
        'onboarding@example.com',
        'team_notification_recipients',
        jsonb_build_array(
            'sales@example.com',
            'operations@example.com'
        ),
        'team_notification_sender_name',
        'B2B Onboarding',
        'team_notification_template_key',
        'wf06-finalized-v1'
    );
$$;

CREATE FUNCTION pg_temp.create_wf06_test_case(
    p_suffix text
)
RETURNS TABLE (
    created_case_id uuid,
    created_correlation_id uuid,
    created_submission_id uuid,
    created_client_id uuid,
    created_external_client_id text
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_token_hash bytea;
    v_decided_at timestamptz;
    v_prepare jsonb;
    v_finalize jsonb;
BEGIN
    INSERT INTO onboarding_cases (
        source_system,
        source_event_id,
        source_deal_id,
        intake_company_name,
        intake_contact_email
    )
    VALUES (
        'wf06_test',
        'event-wf06-' || p_suffix,
        'deal-wf06-' || p_suffix,
        'WF06 Test Company ' || p_suffix,
        'wf06-' || p_suffix || '@example.com'
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
            'wf06-token-' || p_suffix,
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
        decode(
            '00112233445566778899aabb',
            'hex'
        ),
        decode(
            '00112233445566778899aabbccddeeff',
            'hex'
        ),
        'wf06-test-key',
        clock_timestamp() +
            interval '1 hour'
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
            'WF06 Test Company ' || p_suffix,
            'primary_contact_first_name',
            'Finalize',
            'primary_contact_last_name',
            'Tester',
            'primary_contact_email',
            'wf06-' || p_suffix || '@example.com',
            'primary_contact_phone',
            '+48222222222'
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
        'WF06 Test Company ' || p_suffix,
        'Finalize',
        'Tester',
        'wf06-' || p_suffix || '@example.com',
        '+48222222222',
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
        accepted_submission_id =
            created_submission_id,
        state = 'awaiting_approval'
    WHERE id = created_case_id;

    v_decided_at := clock_timestamp();

    UPDATE onboarding_steps
    SET
        status = 'completed',
        attempt_count = 1,
        started_at = COALESCE(
            started_at,
            v_decided_at
        ),
        completed_at = v_decided_at,
        n8n_wait_execution_id =
            'wf06-test-wait-' || p_suffix,
        approval_recipient_email =
            'operator@example.com',
        approval_decision = 'approved',
        approval_decided_at = v_decided_at,
        approval_response_metadata =
            jsonb_build_object(
                'decision',
                'approved',
                'response_source',
                'wf06_test'
            )
    WHERE case_id = created_case_id
      AND step_type = 'manual_approval';

    UPDATE onboarding_cases
    SET
        approval_decision = 'approved',
        approval_decided_at = v_decided_at,
        state = 'approved'
    WHERE id = created_case_id;

    SELECT prepare_wf05_provision_client(
        created_case_id,
        created_correlation_id,
        'wf04',
        created_client_id,
        created_submission_id,
        NULL,
        'wf06-fixture-' || p_suffix,
        'success',
        300,
        5
    )
    INTO v_prepare;

    IF v_prepare ->> 'preparation_outcome'
            IS DISTINCT FROM 'ready_to_call'
    THEN
        RAISE EXCEPTION
            'WF06 fixture provisioning preparation failed: %',
            v_prepare;
    END IF;

    created_external_client_id :=
        'wf06-client-' ||
        substring(md5(p_suffix), 1, 16);

    SELECT finalize_wf05_provision_success(
        created_case_id,
        (v_prepare ->> 'operation_id')::uuid,
        v_prepare ->> 'lease_owner',
        201,
        created_external_client_id,
        created_case_id,
        v_prepare ->> 'company_name',
        v_prepare ->> 'company_identifier',
        'provisioned',
        1,
        false
    )
    INTO v_finalize;

    IF v_finalize ->> 'finalization_outcome'
            IS DISTINCT FROM 'finalized'
        OR v_finalize ->> 'case_state'
            IS DISTINCT FROM 'provisioned'
    THEN
        RAISE EXCEPTION
            'WF06 fixture provisioning finalization failed: %',
            v_finalize;
    END IF;

    RETURN NEXT;
END;
$$;

DO $$
DECLARE
    v_case_id uuid;
    v_correlation_id uuid;
    v_submission_id uuid;
    v_client_id uuid;
    v_external_client_id text;
    v_result jsonb;
    v_operation_count integer;
    v_case_state text;
BEGIN
    SELECT fixture.*
    INTO
        v_case_id,
        v_correlation_id,
        v_submission_id,
        v_client_id,
        v_external_client_id
    FROM pg_temp.create_wf06_test_case(
        'invalid-' || gen_random_uuid()::text
    ) AS fixture;

    SELECT prepare_wf06_finalization_operation(
        v_case_id,
        v_correlation_id,
        'wf98',
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        'invalid-recovery',
        pg_temp.wf06_test_configuration(),
        300,
        5
    )
    INTO v_result;

    IF v_result ->> 'preparation_outcome'
            IS DISTINCT FROM
            'invalid_internal_invocation'
        OR v_result ->> 'error_code'
            IS DISTINCT FROM
            'invalid_wf98_recovery_invocation'
    THEN
        RAISE EXCEPTION
            'WF06 accepted an incomplete WF98 invocation: %',
            v_result;
    END IF;

    SELECT COUNT(*)
    INTO v_operation_count
    FROM external_operations
    WHERE case_id = v_case_id
      AND operation_type IN (
          'create_drive_folder',
          'create_kickoff_event',
          'notify_team'
      );

    SELECT state
    INTO v_case_state
    FROM onboarding_cases
    WHERE id = v_case_id;

    IF v_operation_count <> 0
        OR v_case_state <> 'provisioned'
    THEN
        RAISE EXCEPTION
            'Invalid WF98 invocation left partial WF06 state';
    END IF;

    RAISE NOTICE
        'PASS: invalid WF98 invocation leaves no partial WF06 state';
END;
$$;

DO $$
DECLARE
    v_case_id uuid;
    v_correlation_id uuid;
    v_submission_id uuid;
    v_client_id uuid;
    v_external_client_id text;

    v_drive_prepare jsonb;
    v_busy jsonb;
    v_drive_success jsonb;
    v_calendar_prepare jsonb;
    v_calendar_success jsonb;
    v_notification_prepare jsonb;
    v_notification_success jsonb;
    v_ready jsonb;
    v_completion jsonb;
    v_duplicate_completion jsonb;

    v_drive_operation_id uuid;
    v_calendar_operation_id uuid;
    v_notification_operation_id uuid;

    v_case_state text;
    v_completed_at timestamptz;
    v_operation_count integer;
    v_completed_step_count integer;
    v_completion_event_count integer;
    v_unexpected_response_field_count integer;
BEGIN
    SELECT fixture.*
    INTO
        v_case_id,
        v_correlation_id,
        v_submission_id,
        v_client_id,
        v_external_client_id
    FROM pg_temp.create_wf06_test_case(
        'success-' || gen_random_uuid()::text
    ) AS fixture;

    SELECT prepare_wf06_finalization_operation(
        v_case_id,
        v_correlation_id,
        'wf05',
        v_client_id,
        v_submission_id,
        v_external_client_id,
        NULL,
        NULL,
        'success-drive-1',
        pg_temp.wf06_test_configuration(),
        300,
        5
    )
    INTO v_drive_prepare;

    IF v_drive_prepare ->> 'preparation_outcome'
            IS DISTINCT FROM 'claimed'
        OR v_drive_prepare ->> 'operation_type'
            IS DISTINCT FROM 'create_drive_folder'
        OR v_drive_prepare ->> 'case_state'
            IS DISTINCT FROM 'finalizing'
        OR v_drive_prepare
            -> 'request_summary'
            ->> 'onboarding_case_id'
            IS DISTINCT FROM v_case_id::text
    THEN
        RAISE EXCEPTION
            'Unexpected WF06 Drive preparation: %',
            v_drive_prepare;
    END IF;

    v_drive_operation_id :=
        (v_drive_prepare
            ->> 'operation_id')::uuid;

    SELECT prepare_wf06_finalization_operation(
        v_case_id,
        v_correlation_id,
        'wf05',
        v_client_id,
        v_submission_id,
        v_external_client_id,
        NULL,
        NULL,
        'success-drive-duplicate',
        pg_temp.wf06_test_configuration(),
        300,
        5
    )
    INTO v_busy;

    IF v_busy ->> 'preparation_outcome'
            IS DISTINCT FROM 'busy'
    THEN
        RAISE EXCEPTION
            'Duplicate active WF06 operation was not busy: %',
            v_busy;
    END IF;

    SELECT finalize_wf06_operation_success(
        v_case_id,
        v_drive_operation_id,
        v_drive_prepare ->> 'lease_owner',
        'wf06-drive-folder-success',
        'google_drive',
        false,
        jsonb_build_object(
            'marker_verified',
            true,
            'created',
            true,
            'web_view_link',
            'https://drive.google.com/drive/folders/wf06-drive-folder-success',
            'provider_payload',
            'must-not-be-persisted'
        )
    )
    INTO v_drive_success;

    IF v_drive_success ->> 'finalization_outcome'
            IS DISTINCT FROM 'finalized'
        OR v_drive_success ->> 'operation_status'
            IS DISTINCT FROM 'succeeded'
    THEN
        RAISE EXCEPTION
            'Unexpected WF06 Drive success: %',
            v_drive_success;
    END IF;

    SELECT prepare_wf06_finalization_operation(
        v_case_id,
        v_correlation_id,
        'wf98',
        NULL,
        NULL,
        NULL,
        NULL,
        'resume_finalization',
        'success-calendar-1',
        pg_temp.wf06_test_configuration(),
        300,
        5
    )
    INTO v_calendar_prepare;

    IF v_calendar_prepare ->> 'preparation_outcome'
            IS DISTINCT FROM 'claimed'
        OR v_calendar_prepare ->> 'operation_type'
            IS DISTINCT FROM 'create_kickoff_event'
        OR v_calendar_prepare
            -> 'request_summary'
            ->> 'drive_folder_id'
            IS DISTINCT FROM
            'wf06-drive-folder-success'
    THEN
        RAISE EXCEPTION
            'Unexpected WF06 Calendar recovery preparation: %',
            v_calendar_prepare;
    END IF;

    v_calendar_operation_id :=
        (v_calendar_prepare
            ->> 'operation_id')::uuid;

    SELECT finalize_wf06_operation_success(
        v_case_id,
        v_calendar_operation_id,
        v_calendar_prepare ->> 'lease_owner',
        'wf06-calendar-event-success',
        'google_calendar',
        false,
        jsonb_build_object(
            'marker_verified',
            true,
            'created',
            true,
            'html_link',
            'https://calendar.google.com/calendar/event?eid=wf06'
        )
    )
    INTO v_calendar_success;

    IF v_calendar_success ->> 'finalization_outcome'
            IS DISTINCT FROM 'finalized'
    THEN
        RAISE EXCEPTION
            'Unexpected WF06 Calendar success: %',
            v_calendar_success;
    END IF;

    SELECT prepare_wf06_finalization_operation(
        v_case_id,
        v_correlation_id,
        'wf05',
        v_client_id,
        v_submission_id,
        v_external_client_id,
        NULL,
        NULL,
        'success-notification-1',
        pg_temp.wf06_test_configuration(),
        300,
        5
    )
    INTO v_notification_prepare;

    IF v_notification_prepare
            ->> 'preparation_outcome'
            IS DISTINCT FROM 'claimed'
        OR v_notification_prepare
            ->> 'operation_type'
            IS DISTINCT FROM 'notify_team'
        OR NULLIF(
            btrim(
                v_notification_prepare
                    -> 'request_summary'
                    ->> 'message_marker'
            ),
            ''
        ) IS NULL
    THEN
        RAISE EXCEPTION
            'Unexpected WF06 notification preparation: %',
            v_notification_prepare;
    END IF;

    v_notification_operation_id :=
        (v_notification_prepare
            ->> 'operation_id')::uuid;

    SELECT finalize_wf06_operation_success(
        v_case_id,
        v_notification_operation_id,
        v_notification_prepare ->> 'lease_owner',
        'wf06-gmail-message-success',
        'gmail',
        false,
        jsonb_build_object(
            'marker_verified',
            true,
            'created',
            true,
            'thread_id',
            'wf06-gmail-thread-success'
        )
    )
    INTO v_notification_success;

    IF v_notification_success
            ->> 'finalization_outcome'
            IS DISTINCT FROM 'finalized'
    THEN
        RAISE EXCEPTION
            'Unexpected WF06 notification success: %',
            v_notification_success;
    END IF;

    SELECT prepare_wf06_finalization_operation(
        v_case_id,
        v_correlation_id,
        'wf98',
        NULL,
        NULL,
        NULL,
        NULL,
        'complete_finalization',
        'success-completion-recovery',
        pg_temp.wf06_test_configuration(),
        300,
        5
    )
    INTO v_ready;

    IF v_ready ->> 'preparation_outcome'
            IS DISTINCT FROM 'ready_to_complete'
    THEN
        RAISE EXCEPTION
            'WF98 completion recovery was not ready: %',
            v_ready;
    END IF;

    SELECT complete_wf06_onboarding(
        v_case_id,
        v_correlation_id
    )
    INTO v_completion;

    SELECT complete_wf06_onboarding(
        v_case_id,
        v_correlation_id
    )
    INTO v_duplicate_completion;

    IF v_completion ->> 'completion_outcome'
            IS DISTINCT FROM 'completed'
        OR v_completion ->> 'case_state'
            IS DISTINCT FROM 'completed'
        OR v_duplicate_completion
            ->> 'completion_outcome'
            IS DISTINCT FROM 'already_completed'
    THEN
        RAISE EXCEPTION
            'WF06 completion was not atomic and idempotent: %, %',
            v_completion,
            v_duplicate_completion;
    END IF;

    SELECT
        state,
        completed_at
    INTO
        v_case_state,
        v_completed_at
    FROM onboarding_cases
    WHERE id = v_case_id;

    SELECT COUNT(*)
    INTO v_operation_count
    FROM external_operations
    WHERE case_id = v_case_id
      AND operation_type IN (
          'create_drive_folder',
          'create_kickoff_event',
          'notify_team'
      )
      AND status = 'succeeded';

    SELECT COUNT(*)
    INTO v_completed_step_count
    FROM onboarding_steps
    WHERE case_id = v_case_id
      AND step_type IN (
          'create_drive_folder',
          'create_kickoff_event',
          'notify_team'
      )
      AND status = 'completed';

    SELECT COUNT(*)
    INTO v_completion_event_count
    FROM onboarding_events
    WHERE event_key =
          'onboarding:' ||
          v_case_id::text ||
          ':completed';

    SELECT COUNT(*)
    INTO v_unexpected_response_field_count
    FROM external_operations
    WHERE id = v_drive_operation_id
      AND response_summary
          ? 'provider_payload';

    IF v_case_state <> 'completed'
        OR v_completed_at IS NULL
        OR v_operation_count <> 3
        OR v_completed_step_count <> 3
        OR v_completion_event_count <> 1
        OR v_unexpected_response_field_count <> 0
    THEN
        RAISE EXCEPTION
            'Persisted WF06 success state is inconsistent';
    END IF;

    RAISE NOTICE
        'PASS: WF06 fixed-order success and completion are atomic and idempotent';
END;
$$;

DO $$
DECLARE
    v_case_id uuid;
    v_correlation_id uuid;
    v_submission_id uuid;
    v_client_id uuid;
    v_external_client_id text;
    v_prepare jsonb;
    v_failure jsonb;
    v_not_due jsonb;
    v_retry_prepare jsonb;
    v_success jsonb;
    v_first_request_summary jsonb;
    v_operation_id uuid;
BEGIN
    SELECT fixture.*
    INTO
        v_case_id,
        v_correlation_id,
        v_submission_id,
        v_client_id,
        v_external_client_id
    FROM pg_temp.create_wf06_test_case(
        'retry-' || gen_random_uuid()::text
    ) AS fixture;

    SELECT prepare_wf06_finalization_operation(
        v_case_id,
        v_correlation_id,
        'wf98',
        NULL,
        NULL,
        NULL,
        NULL,
        'missing_initial_dispatch',
        'retry-drive-1',
        pg_temp.wf06_test_configuration(),
        300,
        5
    )
    INTO v_prepare;

    v_operation_id :=
        (v_prepare ->> 'operation_id')::uuid;
    v_first_request_summary :=
        v_prepare -> 'request_summary';

    SELECT finalize_wf06_operation_failure(
        v_case_id,
        v_operation_id,
        v_prepare ->> 'lease_owner',
        true,
        'google_drive',
        'provider_temporary_failure',
        'DRIVE_TEMPORARILY_UNAVAILABLE',
        'The Drive API is temporarily unavailable',
        503,
        1
    )
    INTO v_failure;

    IF v_failure ->> 'finalization_outcome'
            IS DISTINCT FROM 'finalized'
        OR v_failure ->> 'operation_status'
            IS DISTINCT FROM 'failed_retryable'
        OR v_failure ->> 'case_state'
            IS DISTINCT FROM 'finalization_failed'
        OR v_failure ->> 'next_retry_at'
            IS NULL
    THEN
        RAISE EXCEPTION
            'Unexpected WF06 retryable failure: %',
            v_failure;
    END IF;

    SELECT prepare_wf06_finalization_operation(
        v_case_id,
        v_correlation_id,
        'wf98',
        NULL,
        NULL,
        NULL,
        v_operation_id,
        NULL,
        'retry-drive-not-due',
        pg_temp.wf06_test_configuration(),
        300,
        5
    )
    INTO v_not_due;

    IF v_not_due ->> 'preparation_outcome'
            IS DISTINCT FROM 'not_due'
    THEN
        RAISE EXCEPTION
            'WF06 retry ignored next_retry_at: %',
            v_not_due;
    END IF;

    UPDATE external_operations
    SET next_retry_at =
        clock_timestamp() -
        interval '1 second'
    WHERE id = v_operation_id;

    SELECT prepare_wf06_finalization_operation(
        v_case_id,
        v_correlation_id,
        'wf98',
        NULL,
        NULL,
        NULL,
        v_operation_id,
        NULL,
        'retry-drive-2',
        pg_temp.wf06_test_configuration(),
        300,
        5
    )
    INTO v_retry_prepare;

    IF v_retry_prepare ->> 'preparation_outcome'
            IS DISTINCT FROM 'claimed'
        OR (
            v_retry_prepare
                ->> 'operation_attempt_count'
        )::integer IS DISTINCT FROM 2
        OR v_retry_prepare
            -> 'request_summary'
            IS DISTINCT FROM
            v_first_request_summary
        OR v_retry_prepare ->> 'case_state'
            IS DISTINCT FROM 'finalizing'
    THEN
        RAISE EXCEPTION
            'Unexpected WF06 retry preparation: %',
            v_retry_prepare;
    END IF;

    SELECT finalize_wf06_operation_success(
        v_case_id,
        v_operation_id,
        v_retry_prepare ->> 'lease_owner',
        'wf06-drive-folder-retry',
        'google_drive',
        true,
        jsonb_build_object(
            'marker_verified',
            true,
            'created',
            false,
            'web_view_link',
            'https://drive.google.com/drive/folders/wf06-drive-folder-retry'
        )
    )
    INTO v_success;

    IF v_success ->> 'finalization_outcome'
            IS DISTINCT FROM 'finalized'
        OR v_success ->> 'operation_status'
            IS DISTINCT FROM 'succeeded'
    THEN
        RAISE EXCEPTION
            'WF06 retry did not recover: %',
            v_success;
    END IF;

    RAISE NOTICE
        'PASS: WF06 retry is due-aware and reuses its immutable request';
END;
$$;

DO $$
DECLARE
    v_case_id uuid;
    v_correlation_id uuid;
    v_submission_id uuid;
    v_client_id uuid;
    v_external_client_id text;
    v_prepare jsonb;
    v_failure jsonb;
    v_operation_status text;
    v_step_status text;
    v_case_state text;
BEGIN
    SELECT fixture.*
    INTO
        v_case_id,
        v_correlation_id,
        v_submission_id,
        v_client_id,
        v_external_client_id
    FROM pg_temp.create_wf06_test_case(
        'terminal-' || gen_random_uuid()::text
    ) AS fixture;

    SELECT prepare_wf06_finalization_operation(
        v_case_id,
        v_correlation_id,
        'wf05',
        v_client_id,
        v_submission_id,
        v_external_client_id,
        NULL,
        NULL,
        'terminal-drive-1',
        pg_temp.wf06_test_configuration(),
        300,
        1
    )
    INTO v_prepare;

    SELECT finalize_wf06_operation_failure(
        v_case_id,
        (v_prepare ->> 'operation_id')::uuid,
        v_prepare ->> 'lease_owner',
        true,
        'google_drive',
        'provider_temporary_failure',
        'DRIVE_TEMPORARILY_UNAVAILABLE',
        'The Drive API is still unavailable',
        503,
        NULL
    )
    INTO v_failure;

    IF v_failure ->> 'operation_status'
            IS DISTINCT FROM 'failed_terminal'
        OR v_failure ->> 'next_retry_at'
            IS NOT NULL
        OR (
            v_failure
                ->> 'requires_intervention'
        )::boolean IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION
            'WF06 max-attempt handling failed: %',
            v_failure;
    END IF;

    SELECT
        operation.status,
        step.status,
        onboarding_case.state
    INTO
        v_operation_status,
        v_step_status,
        v_case_state
    FROM external_operations AS operation
    JOIN onboarding_cases AS onboarding_case
      ON onboarding_case.id = operation.case_id
    JOIN onboarding_steps AS step
      ON step.case_id = onboarding_case.id
     AND step.step_type =
         operation.operation_type
    WHERE operation.id =
          (v_prepare
              ->> 'operation_id')::uuid;

    IF v_operation_status <> 'failed_terminal'
        OR v_step_status <> 'failed_terminal'
        OR v_case_state <> 'finalization_failed'
    THEN
        RAISE EXCEPTION
            'Persisted WF06 terminal state is inconsistent';
    END IF;

    RAISE NOTICE
        'PASS: WF06 attempt exhaustion becomes terminal';
END;
$$;

ROLLBACK;
