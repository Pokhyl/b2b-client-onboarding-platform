BEGIN;

CREATE OR REPLACE FUNCTION finalize_wf02_exhausted_delivery(
    p_operation_id uuid,
    p_case_id uuid,
    p_token_id uuid,
    p_request_cycle_key text,
    p_error_summary jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
    finalization_outcome text,
    final_operation_status text,
    final_step_status text,
    final_token_status text,
    final_attempt_count integer
)
LANGUAGE plpgsql
AS $$
DECLARE
    operation_row external_operations%ROWTYPE;
    case_row onboarding_cases%ROWTYPE;
    step_row onboarding_steps%ROWTYPE;
    token_row onboarding_form_tokens%ROWTYPE;

    expected_case_state text;
    v_now timestamptz;
    safe_error_summary jsonb;
BEGIN
    IF p_operation_id IS NULL
        OR p_case_id IS NULL
        OR p_token_id IS NULL
    THEN
        RAISE EXCEPTION
            'operation_id, case_id, and token_id are required';
    END IF;

    IF p_request_cycle_key IS NULL
        OR btrim(p_request_cycle_key) = ''
    THEN
        RAISE EXCEPTION
            'request_cycle_key must not be blank';
    END IF;

    IF p_error_summary IS NULL
        OR jsonb_typeof(p_error_summary) <> 'object'
    THEN
        RAISE EXCEPTION
            'error_summary must be a JSON object';
    END IF;

    IF p_request_cycle_key = 'initial' THEN
        expected_case_state := 'created';

    ELSIF p_request_cycle_key LIKE 'validation_failed:%' THEN
        expected_case_state := 'validation_failed';

    ELSE
        finalization_outcome :=
            'invalid_request_cycle';

        RETURN NEXT;
        RETURN;
    END IF;

    v_now := clock_timestamp();

    SELECT operation.*
    INTO operation_row
    FROM external_operations AS operation
    WHERE operation.id = p_operation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        finalization_outcome :=
            'operation_not_found';

        RETURN NEXT;
        RETURN;
    END IF;

    IF operation_row.operation_type
            IS DISTINCT FROM 'send_client_data_request'
        OR operation_row.case_id
            IS DISTINCT FROM p_case_id
        OR operation_row.request_summary ->> 'token_id'
            IS DISTINCT FROM p_token_id::text
        OR operation_row.request_summary ->> 'request_cycle_key'
            IS DISTINCT FROM p_request_cycle_key
    THEN
        finalization_outcome :=
            'operation_identity_mismatch';

        final_operation_status :=
            operation_row.status;

        final_attempt_count :=
            operation_row.attempt_count;

        RETURN NEXT;
        RETURN;
    END IF;

    IF operation_row.status = 'succeeded' THEN
        finalization_outcome :=
            'operation_already_succeeded';

        final_operation_status :=
            operation_row.status;

        final_attempt_count :=
            operation_row.attempt_count;

        RETURN NEXT;
        RETURN;
    END IF;

    IF operation_row.status = 'in_progress'
        AND operation_row.lease_expires_at > v_now
    THEN
        finalization_outcome :=
            'active_lease';

        final_operation_status :=
            operation_row.status;

        final_attempt_count :=
            operation_row.attempt_count;

        RETURN NEXT;
        RETURN;
    END IF;

    IF operation_row.attempt_count
        < operation_row.max_attempts
    THEN
        finalization_outcome :=
            'attempts_remaining';

        final_operation_status :=
            operation_row.status;

        final_attempt_count :=
            operation_row.attempt_count;

        RETURN NEXT;
        RETURN;
    END IF;

    IF operation_row.status NOT IN (
        'in_progress',
        'failed_retryable',
        'failed_terminal'
    ) THEN
        finalization_outcome :=
            'invalid_operation_status';

        final_operation_status :=
            operation_row.status;

        final_attempt_count :=
            operation_row.attempt_count;

        RETURN NEXT;
        RETURN;
    END IF;

    SELECT onboarding_case.*
    INTO case_row
    FROM onboarding_cases AS onboarding_case
    WHERE onboarding_case.id = p_case_id
    FOR UPDATE;

    IF NOT FOUND THEN
        finalization_outcome :=
            'case_not_found';

        RETURN NEXT;
        RETURN;
    END IF;

    IF case_row.state
        IS DISTINCT FROM expected_case_state
    THEN
        finalization_outcome :=
            'invalid_case_state';

        final_operation_status :=
            operation_row.status;

        final_attempt_count :=
            operation_row.attempt_count;

        RETURN NEXT;
        RETURN;
    END IF;

    SELECT step.*
    INTO step_row
    FROM onboarding_steps AS step
    WHERE step.case_id = p_case_id
      AND step.step_type = 'collect_client_data'
    FOR UPDATE;

    IF NOT FOUND THEN
        finalization_outcome :=
            'collect_step_not_found';

        RETURN NEXT;
        RETURN;
    END IF;

    IF step_row.status NOT IN (
        'in_progress',
        'failed_retryable',
        'failed_terminal'
    ) THEN
        finalization_outcome :=
            'invalid_collect_step_status';

        final_operation_status :=
            operation_row.status;

        final_step_status :=
            step_row.status;

        final_attempt_count :=
            operation_row.attempt_count;

        RETURN NEXT;
        RETURN;
    END IF;

    SELECT token.*
    INTO token_row
    FROM onboarding_form_tokens AS token
    WHERE token.id = p_token_id
      AND token.case_id = p_case_id
      AND token.request_cycle_key = p_request_cycle_key
    FOR UPDATE;

    IF NOT FOUND THEN
        finalization_outcome :=
            'token_not_found';

        RETURN NEXT;
        RETURN;
    END IF;

    IF token_row.status IN (
        'delivered',
        'consumed'
    ) THEN
        finalization_outcome :=
            'token_already_delivered';

        final_operation_status :=
            operation_row.status;

        final_step_status :=
            step_row.status;

        final_token_status :=
            token_row.status;

        final_attempt_count :=
            operation_row.attempt_count;

        RETURN NEXT;
        RETURN;
    END IF;

    safe_error_summary :=
        p_error_summary
        || jsonb_build_object(
            'error_code',
            'maximum_attempts_exhausted',

            'attempt_count',
            operation_row.attempt_count,

            'max_attempts',
            operation_row.max_attempts
        );

    UPDATE external_operations AS operation
    SET
        status =
            'failed_terminal',

        lease_owner =
            NULL,

        lease_expires_at =
            NULL,

        next_retry_at =
            NULL,

        last_error_class =
            'maximum_attempts_exhausted',

        last_error_summary =
            safe_error_summary,

        completed_at =
            COALESCE(
                operation.completed_at,
                v_now
            )

    WHERE operation.id = operation_row.id;

    UPDATE onboarding_steps AS step
    SET
        status =
            'failed_terminal',

        attempt_count =
            GREATEST(
                step.attempt_count,
                operation_row.attempt_count
            ),

        completed_at =
            COALESCE(
                step.completed_at,
                v_now
            ),

        last_error_summary =
            safe_error_summary

    WHERE step.id = step_row.id;

    IF token_row.status = 'issued' THEN
        UPDATE onboarding_form_tokens AS token
        SET
            status =
                'revoked',

            token_ciphertext =
                NULL,

            token_nonce =
                NULL,

            token_auth_tag =
                NULL,

            encryption_key_id =
                NULL,

            revoked_at =
                v_now

        WHERE token.id = token_row.id;

        final_token_status :=
            'revoked';

    ELSE
        final_token_status :=
            token_row.status;
    END IF;

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
        p_case_id,

        'onboarding:'
            || p_case_id::text
            || ':form-token:'
            || p_token_id::text
            || ':client-data-request-delivery-failed',

        'client_data_request_delivery_failed',

        'workflow',

        'WF02',

        NULL,

        NULL,

        jsonb_build_object(
            'token_id',
            p_token_id,

            'external_operation_id',
            p_operation_id,

            'request_cycle_key',
            p_request_cycle_key,

            'error_class',
            'maximum_attempts_exhausted',

            'final_attempt_count',
            operation_row.attempt_count
        ),

        case_row.correlation_id
    )
    ON CONFLICT (event_key)
    DO NOTHING;

    finalization_outcome :=
        'finalized';

    final_operation_status :=
        'failed_terminal';

    final_step_status :=
        'failed_terminal';

    final_attempt_count :=
        operation_row.attempt_count;

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION finalize_wf02_exhausted_delivery(
    uuid,
    uuid,
    uuid,
    text,
    jsonb
)
IS
'Atomically finalizes an exhausted WF02 client-data delivery operation.';

COMMIT;
