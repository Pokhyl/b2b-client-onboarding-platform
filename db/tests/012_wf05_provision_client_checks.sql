\set ON_ERROR_STOP on

BEGIN;

CREATE FUNCTION pg_temp.create_wf05_test_case(
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
    v_decided_at timestamptz;
BEGIN
    INSERT INTO onboarding_cases (
        source_system,
        source_event_id,
        source_deal_id,
        intake_company_name,
        intake_contact_email
    )
    VALUES (
        'wf05_test',
        'event-wf05-' || p_suffix,
        'deal-wf05-' || p_suffix,
        'WF05 Test Company ' || p_suffix,
        'wf05-' || p_suffix || '@example.com'
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
            'wf05-token-' || p_suffix,
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
        'wf05-test-key',
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
            'WF05 Test Company ' || p_suffix,
            'primary_contact_first_name',
            'Provision',
            'primary_contact_last_name',
            'Tester',
            'primary_contact_email',
            'wf05-' || p_suffix || '@example.com',
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
        'WF05 Test Company ' || p_suffix,
        'Provision',
        'Tester',
        'wf05-' || p_suffix || '@example.com',
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
            'wf05-test-wait-' || p_suffix,
        approval_recipient_email =
            'operator@example.com',
        approval_decision = 'approved',
        approval_decided_at = v_decided_at,
        approval_response_metadata =
            jsonb_build_object(
                'decision',
                'approved',
                'response_source',
                'wf05_test'
            )
    WHERE case_id = created_case_id
      AND step_type = 'manual_approval';

    UPDATE onboarding_cases
    SET
        approval_decision = 'approved',
        approval_decided_at = v_decided_at,
        state = 'approved'
    WHERE id = created_case_id;

    RETURN NEXT;
END;
$$;


DO $$
DECLARE
    v_case_id uuid;
    v_correlation_id uuid;
    v_submission_id uuid;
    v_client_id uuid;
    v_result jsonb;
    v_operation_count integer;
    v_case_state text;
BEGIN
    SELECT fixture.*
    INTO
        v_case_id,
        v_correlation_id,
        v_submission_id,
        v_client_id
    FROM pg_temp.create_wf05_test_case(
        'invalid-' || gen_random_uuid()::text
    ) AS fixture;

    SELECT prepare_wf05_provision_client(
        v_case_id,
        v_correlation_id,
        'wf04',
        gen_random_uuid(),
        v_submission_id,
        NULL,
        'invalid-execution',
        'success',
        300,
        5
    )
    INTO v_result;

    IF v_result ->> 'preparation_outcome'
            IS DISTINCT FROM
            'invalid_internal_invocation'
    THEN
        RAISE EXCEPTION
            'Unexpected invalid invocation result: %',
            v_result;
    END IF;

    SELECT COUNT(*)
    INTO v_operation_count
    FROM external_operations
    WHERE case_id = v_case_id
      AND operation_type =
          'provision_client';

    SELECT state
    INTO v_case_state
    FROM onboarding_cases
    WHERE id = v_case_id;

    IF v_operation_count <> 0
        OR v_case_state <> 'approved'
    THEN
        RAISE EXCEPTION
            'Invalid invocation left partial WF05 state';
    END IF;

    RAISE NOTICE
        'PASS: invalid WF05 invocation left no partial state';
END;
$$;


DO $$
DECLARE
    v_case_id uuid;
    v_correlation_id uuid;
    v_submission_id uuid;
    v_client_id uuid;

    v_prepare jsonb;
    v_busy jsonb;
    v_finalize jsonb;
    v_duplicate_finalize jsonb;

    v_operation_id uuid;
    v_lease_owner text;
    v_external_client_id text :=
        'mock_client_success_test';

    v_case_state text;
    v_case_external_id text;
    v_step_status text;
    v_operation_status text;
    v_operation_external_id text;
    v_success_event_count integer;
BEGIN
    SELECT fixture.*
    INTO
        v_case_id,
        v_correlation_id,
        v_submission_id,
        v_client_id
    FROM pg_temp.create_wf05_test_case(
        'success-' || gen_random_uuid()::text
    ) AS fixture;

    SELECT prepare_wf05_provision_client(
        v_case_id,
        v_correlation_id,
        'wf04',
        v_client_id,
        v_submission_id,
        NULL,
        'success-execution-1',
        'success',
        300,
        5
    )
    INTO v_prepare;

    IF v_prepare ->> 'preparation_outcome'
            IS DISTINCT FROM 'ready_to_call'
        OR v_prepare ->> 'operation_claim_outcome'
            IS DISTINCT FROM 'claimed'
        OR (v_prepare ->> 'operation_attempt_count')::integer
            IS DISTINCT FROM 1
        OR v_prepare ->> 'case_state'
            IS DISTINCT FROM 'provisioning'
        OR v_prepare ->> 'scenario'
            IS DISTINCT FROM 'success'
        OR (v_prepare -> 'request_summary')
            ? 'primary_contact_email'
    THEN
        RAISE EXCEPTION
            'Unexpected WF05 preparation result: %',
            v_prepare;
    END IF;

    v_operation_id :=
        (v_prepare ->> 'operation_id')::uuid;

    v_lease_owner :=
        v_prepare ->> 'lease_owner';

    SELECT prepare_wf05_provision_client(
        v_case_id,
        v_correlation_id,
        'wf04',
        v_client_id,
        v_submission_id,
        NULL,
        'success-execution-2',
        'success',
        300,
        5
    )
    INTO v_busy;

    IF v_busy ->> 'preparation_outcome'
            IS DISTINCT FROM 'busy'
    THEN
        RAISE EXCEPTION
            'Duplicate active WF05 invocation was not busy: %',
            v_busy;
    END IF;

    SELECT finalize_wf05_provision_success(
        v_case_id,
        v_operation_id,
        v_lease_owner,
        201,
        v_external_client_id,
        v_case_id,
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
        OR v_finalize ->> 'operation_status'
            IS DISTINCT FROM 'succeeded'
        OR v_finalize ->> 'provision_step_status'
            IS DISTINCT FROM 'completed'
    THEN
        RAISE EXCEPTION
            'Unexpected WF05 success finalization: %',
            v_finalize;
    END IF;

    SELECT finalize_wf05_provision_success(
        v_case_id,
        v_operation_id,
        v_lease_owner,
        201,
        v_external_client_id,
        v_case_id,
        v_prepare ->> 'company_name',
        v_prepare ->> 'company_identifier',
        'provisioned',
        1,
        false
    )
    INTO v_duplicate_finalize;

    IF v_duplicate_finalize
            ->> 'finalization_outcome'
            IS DISTINCT FROM
            'already_finalized'
    THEN
        RAISE EXCEPTION
            'WF05 success was not idempotent: %',
            v_duplicate_finalize;
    END IF;

    SELECT
        onboarding_case.state,
        onboarding_case.external_client_id
    INTO
        v_case_state,
        v_case_external_id
    FROM onboarding_cases AS onboarding_case
    WHERE onboarding_case.id = v_case_id;

    SELECT status
    INTO v_step_status
    FROM onboarding_steps
    WHERE case_id = v_case_id
      AND step_type = 'provision_client';

    SELECT
        status,
        external_id
    INTO
        v_operation_status,
        v_operation_external_id
    FROM external_operations
    WHERE id = v_operation_id;

    SELECT COUNT(*)
    INTO v_success_event_count
    FROM onboarding_events
    WHERE event_key =
        'onboarding:' ||
        v_case_id::text ||
        ':provision-client:succeeded';

    IF v_case_state <> 'provisioned'
        OR v_case_external_id
            IS DISTINCT FROM
            v_external_client_id
        OR v_step_status <> 'completed'
        OR v_operation_status <> 'succeeded'
        OR v_operation_external_id
            IS DISTINCT FROM
            v_external_client_id
        OR v_success_event_count <> 1
    THEN
        RAISE EXCEPTION
            'Persisted WF05 success state is inconsistent';
    END IF;

    RAISE NOTICE
        'PASS: WF05 success is atomic and idempotent';
END;
$$;


DO $$
DECLARE
    v_case_id uuid;
    v_correlation_id uuid;
    v_submission_id uuid;
    v_client_id uuid;

    v_prepare jsonb;
    v_failure jsonb;
    v_not_due jsonb;
    v_retry_prepare jsonb;
    v_success jsonb;

    v_operation_id uuid;
    v_first_request_summary jsonb;
    v_second_request_summary jsonb;
BEGIN
    SELECT fixture.*
    INTO
        v_case_id,
        v_correlation_id,
        v_submission_id,
        v_client_id
    FROM pg_temp.create_wf05_test_case(
        'retry-' || gen_random_uuid()::text
    ) AS fixture;

    SELECT prepare_wf05_provision_client(
        v_case_id,
        v_correlation_id,
        'wf04',
        v_client_id,
        v_submission_id,
        NULL,
        'retry-execution-1',
        'retryable_once',
        300,
        5
    )
    INTO v_prepare;

    v_operation_id :=
        (v_prepare ->> 'operation_id')::uuid;

    v_first_request_summary :=
        v_prepare -> 'request_summary';

    SELECT finalize_wf05_provision_failure(
        v_case_id,
        v_operation_id,
        v_prepare ->> 'lease_owner',
        true,
        'provider_temporary_failure',
        'PROVISIONING_TEMPORARILY_UNAVAILABLE',
        'The provisioning service is temporarily unavailable',
        503,
        1,
        1
    )
    INTO v_failure;

    IF v_failure ->> 'finalization_outcome'
            IS DISTINCT FROM 'finalized'
        OR v_failure ->> 'operation_status'
            IS DISTINCT FROM 'failed_retryable'
        OR v_failure ->> 'case_state'
            IS DISTINCT FROM 'provisioning_failed'
        OR v_failure ->> 'provision_step_status'
            IS DISTINCT FROM 'failed_retryable'
        OR v_failure ->> 'next_retry_at'
            IS NULL
    THEN
        RAISE EXCEPTION
            'Unexpected retryable failure result: %',
            v_failure;
    END IF;

    SELECT prepare_wf05_provision_client(
        v_case_id,
        v_correlation_id,
        'wf98',
        NULL,
        NULL,
        v_operation_id,
        'retry-execution-not-due',
        NULL,
        300,
        5
    )
    INTO v_not_due;

    IF v_not_due ->> 'preparation_outcome'
            IS DISTINCT FROM 'not_due'
    THEN
        RAISE EXCEPTION
            'WF05 retry ignored next_retry_at: %',
            v_not_due;
    END IF;

    UPDATE external_operations
    SET next_retry_at =
        clock_timestamp() -
        interval '1 second'
    WHERE id = v_operation_id;

    SELECT prepare_wf05_provision_client(
        v_case_id,
        v_correlation_id,
        'wf98',
        NULL,
        NULL,
        v_operation_id,
        'retry-execution-2',
        NULL,
        300,
        5
    )
    INTO v_retry_prepare;

    v_second_request_summary :=
        v_retry_prepare -> 'request_summary';

    IF v_retry_prepare ->> 'preparation_outcome'
            IS DISTINCT FROM 'ready_to_call'
        OR (v_retry_prepare
            ->> 'operation_attempt_count')::integer
            IS DISTINCT FROM 2
        OR v_second_request_summary
            IS DISTINCT FROM
            v_first_request_summary
    THEN
        RAISE EXCEPTION
            'Unexpected WF05 retry preparation: %',
            v_retry_prepare;
    END IF;

    SELECT finalize_wf05_provision_success(
        v_case_id,
        v_operation_id,
        v_retry_prepare ->> 'lease_owner',
        201,
        'mock_client_retry_test',
        v_case_id,
        v_retry_prepare ->> 'company_name',
        v_retry_prepare
            ->> 'company_identifier',
        'provisioned',
        2,
        false
    )
    INTO v_success;

    IF v_success ->> 'finalization_outcome'
            IS DISTINCT FROM 'finalized'
        OR v_success ->> 'case_state'
            IS DISTINCT FROM 'provisioned'
    THEN
        RAISE EXCEPTION
            'WF05 retry did not recover: %',
            v_success;
    END IF;

    RAISE NOTICE
        'PASS: WF05 retry is due-aware and reuses the immutable request';
END;
$$;


DO $$
DECLARE
    v_case_id uuid;
    v_correlation_id uuid;
    v_submission_id uuid;
    v_client_id uuid;

    v_prepare jsonb;
    v_failure jsonb;
    v_duplicate_failure jsonb;

    v_operation_id uuid;
    v_case_state text;
    v_step_status text;
    v_operation_status text;
    v_next_retry_at timestamptz;
BEGIN
    SELECT fixture.*
    INTO
        v_case_id,
        v_correlation_id,
        v_submission_id,
        v_client_id
    FROM pg_temp.create_wf05_test_case(
        'terminal-' || gen_random_uuid()::text
    ) AS fixture;

    SELECT prepare_wf05_provision_client(
        v_case_id,
        v_correlation_id,
        'wf04',
        v_client_id,
        v_submission_id,
        NULL,
        'terminal-execution-1',
        'terminal',
        300,
        5
    )
    INTO v_prepare;

    v_operation_id :=
        (v_prepare ->> 'operation_id')::uuid;

    SELECT finalize_wf05_provision_failure(
        v_case_id,
        v_operation_id,
        v_prepare ->> 'lease_owner',
        false,
        'provider_terminal_failure',
        'PROVISIONING_REJECTED',
        'The provisioning request was permanently rejected',
        422,
        1,
        NULL
    )
    INTO v_failure;

    IF v_failure ->> 'finalization_outcome'
            IS DISTINCT FROM 'finalized'
        OR v_failure ->> 'operation_status'
            IS DISTINCT FROM 'failed_terminal'
        OR v_failure ->> 'case_state'
            IS DISTINCT FROM 'provisioning_failed'
        OR v_failure
            ->> 'provision_step_status'
            IS DISTINCT FROM 'failed_terminal'
        OR (v_failure
            ->> 'requires_intervention')::boolean
            IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION
            'Unexpected terminal failure result: %',
            v_failure;
    END IF;

    SELECT finalize_wf05_provision_failure(
        v_case_id,
        v_operation_id,
        v_prepare ->> 'lease_owner',
        false,
        'provider_terminal_failure',
        'PROVISIONING_REJECTED',
        'The provisioning request was permanently rejected',
        422,
        1,
        NULL
    )
    INTO v_duplicate_failure;

    IF v_duplicate_failure
            ->> 'finalization_outcome'
            IS DISTINCT FROM
            'already_finalized'
    THEN
        RAISE EXCEPTION
            'WF05 terminal failure was not idempotent: %',
            v_duplicate_failure;
    END IF;

    SELECT state
    INTO v_case_state
    FROM onboarding_cases
    WHERE id = v_case_id;

    SELECT status
    INTO v_step_status
    FROM onboarding_steps
    WHERE case_id = v_case_id
      AND step_type = 'provision_client';

    SELECT
        status,
        next_retry_at
    INTO
        v_operation_status,
        v_next_retry_at
    FROM external_operations
    WHERE id = v_operation_id;

    IF v_case_state <> 'provisioning_failed'
        OR v_step_status <> 'failed_terminal'
        OR v_operation_status <> 'failed_terminal'
        OR v_next_retry_at IS NOT NULL
    THEN
        RAISE EXCEPTION
            'Persisted terminal WF05 state is inconsistent';
    END IF;

    RAISE NOTICE
        'PASS: WF05 terminal failure is atomic and idempotent';
END;
$$;


DO $$
DECLARE
    v_case_id uuid;
    v_correlation_id uuid;
    v_submission_id uuid;
    v_client_id uuid;
    v_prepare jsonb;
    v_failure jsonb;
BEGIN
    SELECT fixture.*
    INTO
        v_case_id,
        v_correlation_id,
        v_submission_id,
        v_client_id
    FROM pg_temp.create_wf05_test_case(
        'exhausted-' || gen_random_uuid()::text
    ) AS fixture;

    SELECT prepare_wf05_provision_client(
        v_case_id,
        v_correlation_id,
        'wf04',
        v_client_id,
        v_submission_id,
        NULL,
        'exhausted-execution-1',
        'retryable_always',
        300,
        1
    )
    INTO v_prepare;

    SELECT finalize_wf05_provision_failure(
        v_case_id,
        (v_prepare ->> 'operation_id')::uuid,
        v_prepare ->> 'lease_owner',
        true,
        'provider_temporary_failure',
        'PROVISIONING_TEMPORARILY_UNAVAILABLE',
        'The provisioning service is temporarily unavailable',
        503,
        1,
        1
    )
    INTO v_failure;

    IF v_failure ->> 'operation_status'
            IS DISTINCT FROM 'failed_terminal'
        OR v_failure ->> 'next_retry_at'
            IS NOT NULL
        OR (v_failure
            ->> 'requires_intervention')::boolean
            IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION
            'WF05 max-attempt handling failed: %',
            v_failure;
    END IF;

    RAISE NOTICE
        'PASS: WF05 attempt exhaustion becomes terminal';
END;
$$;

ROLLBACK;
