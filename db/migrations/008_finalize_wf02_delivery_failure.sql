BEGIN;

CREATE OR REPLACE FUNCTION finalize_wf02_delivery_failure(
    p_operation_id uuid,
    p_case_id uuid,
    p_token_id uuid,
    p_request_cycle_key text,
    p_lease_owner text,
    p_transport_retryable boolean,
    p_error_class text,
    p_error_summary jsonb
)
RETURNS TABLE (
    finalization_outcome text,
    final_operation_status text,
    final_step_status text,
    final_token_status text,
    final_next_retry_at timestamptz,
    final_attempt_count integer,
    final_error_class text
)
LANGUAGE plpgsql
AS $$
DECLARE
    operation_row external_operations%ROWTYPE;
    case_row onboarding_cases%ROWTYPE;
    step_row onboarding_steps%ROWTYPE;
    token_row onboarding_form_tokens%ROWTYPE;

    expected_case_state text;
    effective_retryable boolean;
    effective_error_class text;
    effective_error_summary jsonb;
    computed_next_retry_at timestamptz;
    failure_outcome text;
    v_now timestamptz;
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

    IF p_lease_owner IS NULL
        OR btrim(p_lease_owner) = ''
    THEN
        RAISE EXCEPTION
            'lease_owner must not be blank';
    END IF;

    IF p_transport_retryable IS NULL THEN
        RAISE EXCEPTION
            'transport_retryable must not be null';
    END IF;

    IF p_error_class IS NULL
        OR btrim(p_error_class) = ''
    THEN
        RAISE EXCEPTION
            'error_class must not be blank';
    END IF;

    IF p_error_summary IS NULL
        OR jsonb_typeof(p_error_summary) <> 'object'
    THEN
        RAISE EXCEPTION
            'error_summary must be a JSON object';
    END IF;

    IF p_request_cycle_key = 'initial' THEN
        expected_case_state :=
            'created';

    ELSIF p_request_cycle_key LIKE 'validation_failed:%' THEN
        expected_case_state :=
            'validation_failed';

    ELSE
        finalization_outcome :=
            'invalid_request_cycle';

        RETURN NEXT;
        RETURN;
    END IF;

    v_now :=
        clock_timestamp();

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

    final_operation_status :=
        operation_row.status;

    final_attempt_count :=
        operation_row.attempt_count;

    final_next_retry_at :=
        operation_row.next_retry_at;

    final_error_class :=
        operation_row.last_error_class;

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

        RETURN NEXT;
        RETURN;
    END IF;

    IF operation_row.status = 'failed_retryable' THEN
        finalization_outcome :=
            'operation_already_failed_retryable';

        RETURN NEXT;
        RETURN;
    END IF;

    IF operation_row.status = 'failed_terminal' THEN
        finalization_outcome :=
            'operation_already_failed_terminal';

        RETURN NEXT;
        RETURN;
    END IF;

    IF operation_row.status <> 'in_progress'
        OR operation_row.lease_owner
            IS DISTINCT FROM p_lease_owner
        OR operation_row.lease_expires_at <= v_now
    THEN
        finalization_outcome :=
            'lease_not_owned';

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
        'failed_retryable'
    ) THEN
        finalization_outcome :=
            'invalid_collect_step_status';

        final_step_status :=
            step_row.status;

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

    IF token_row.status <> 'issued' THEN
        finalization_outcome :=
            'invalid_token_status';

        final_token_status :=
            token_row.status;

        RETURN NEXT;
        RETURN;
    END IF;

    effective_error_class :=
        p_error_class;

    effective_error_summary :=
        p_error_summary;

    /*
     * Retry scheduling is based exclusively on database time.
     *
     * attempt 1 -> 1 minute
     * attempt 2 -> 5 minutes
     * attempt 3 -> 15 minutes
     * attempt 4 -> 60 minutes
     * attempt 5 -> terminal when max_attempts = 5
     */
    effective_retryable :=
        p_transport_retryable
        AND token_row.expires_at > v_now
        AND operation_row.attempt_count
            < operation_row.max_attempts;

    IF token_row.expires_at <= v_now THEN
        effective_error_class :=
            'token_expiry';

        effective_error_summary :=
            effective_error_summary
            || jsonb_build_object(
                'token_expired_during_failure_finalization',
                true
            );
    END IF;

    computed_next_retry_at :=
        CASE
            WHEN effective_retryable IS NOT TRUE
                THEN NULL

            WHEN operation_row.attempt_count = 1
                THEN v_now + interval '1 minute'

            WHEN operation_row.attempt_count = 2
                THEN v_now + interval '5 minutes'

            WHEN operation_row.attempt_count = 3
                THEN v_now + interval '15 minutes'

            ELSE
                v_now + interval '1 hour'
        END;

    failure_outcome :=
        complete_external_operation_failure(
            p_operation_id,
            p_lease_owner,
            effective_retryable,
            effective_error_class,
            effective_error_summary,
            computed_next_retry_at
        );

    IF failure_outcome = 'lease_not_owned' THEN
        finalization_outcome :=
            'lease_not_owned';

        RETURN NEXT;
        RETURN;
    END IF;

    IF failure_outcome NOT IN (
        'failed_retryable',
        'failed_terminal'
    ) THEN
        finalization_outcome :=
            failure_outcome;

        RETURN NEXT;
        RETURN;
    END IF;

    UPDATE onboarding_steps AS step
    SET
        status =
            failure_outcome,

        last_error_summary =
            effective_error_summary,

        completed_at =
            CASE
                WHEN failure_outcome = 'failed_terminal'
                    THEN v_now
                ELSE NULL
            END

    WHERE step.id = step_row.id;

    IF failure_outcome = 'failed_terminal' THEN
        UPDATE onboarding_form_tokens AS token
        SET
            status =
                CASE
                    WHEN token.expires_at <= v_now
                        THEN 'expired'
                    ELSE 'revoked'
                END,

            revoked_at =
                CASE
                    WHEN token.expires_at > v_now
                        THEN v_now
                    ELSE token.revoked_at
                END,

            token_ciphertext =
                NULL,

            token_nonce =
                NULL,

            token_auth_tag =
                NULL,

            encryption_key_id =
                NULL

        WHERE token.id = token_row.id;

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

                'failure_class',
                effective_error_class,

                'final_attempt_count',
                operation_row.attempt_count
            ),

            case_row.correlation_id
        )
        ON CONFLICT (event_key)
        DO NOTHING;
    END IF;

    SELECT
        operation.status,
        operation.next_retry_at,
        operation.attempt_count,
        operation.last_error_class
    INTO
        final_operation_status,
        final_next_retry_at,
        final_attempt_count,
        final_error_class
    FROM external_operations AS operation
    WHERE operation.id = p_operation_id;

    SELECT step.status
    INTO final_step_status
    FROM onboarding_steps AS step
    WHERE step.id = step_row.id;

    SELECT token.status
    INTO final_token_status
    FROM onboarding_form_tokens AS token
    WHERE token.id = token_row.id;

    finalization_outcome :=
        failure_outcome;

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION finalize_wf02_delivery_failure(
    uuid,
    uuid,
    uuid,
    text,
    text,
    boolean,
    text,
    jsonb
)
IS
'Atomically finalizes retryable or terminal WF02 delivery activity failure using PostgreSQL retry time.';

COMMIT;
