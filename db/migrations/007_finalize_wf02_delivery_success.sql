BEGIN;

CREATE OR REPLACE FUNCTION finalize_wf02_delivery_success(
    p_operation_id uuid,
    p_case_id uuid,
    p_token_id uuid,
    p_request_cycle_key text,
    p_lease_owner text,
    p_gmail_message_id text,
    p_gmail_thread_id text,
    p_message_marker text,
    p_template_key text,
    p_delivery_source text
)
RETURNS TABLE (
    finalization_outcome text,
    final_operation_status text,
    final_case_state text,
    final_step_status text,
    final_token_status text,
    final_external_id text
)
LANGUAGE plpgsql
AS $$
DECLARE
    operation_row external_operations%ROWTYPE;
    case_row onboarding_cases%ROWTYPE;
    step_row onboarding_steps%ROWTYPE;
    token_row onboarding_form_tokens%ROWTYPE;

    expected_case_state text;
    response_summary jsonb;
    success_applied boolean;
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

    IF p_gmail_message_id IS NULL
        OR btrim(p_gmail_message_id) = ''
    THEN
        RAISE EXCEPTION
            'gmail_message_id must not be blank';
    END IF;

    IF p_message_marker IS NULL
        OR btrim(p_message_marker) = ''
    THEN
        RAISE EXCEPTION
            'message_marker must not be blank';
    END IF;

    IF p_template_key IS NULL
        OR btrim(p_template_key) = ''
    THEN
        RAISE EXCEPTION
            'template_key must not be blank';
    END IF;

    IF p_delivery_source NOT IN (
        'gmail_send',
        'gmail_reconciliation'
    ) THEN
        RAISE EXCEPTION
            'delivery_source is invalid';
    END IF;

    IF p_request_cycle_key = 'initial' THEN
        expected_case_state :=
            'created';

        IF p_template_key
            IS DISTINCT FROM 'client_data_request_v1'
        THEN
            finalization_outcome :=
                'template_mismatch';

            RETURN NEXT;
            RETURN;
        END IF;

    ELSIF p_request_cycle_key LIKE 'validation_failed:%' THEN
        expected_case_state :=
            'validation_failed';

        IF p_template_key
            IS DISTINCT FROM 'client_data_correction_v1'
        THEN
            finalization_outcome :=
                'template_mismatch';

            RETURN NEXT;
            RETURN;
        END IF;

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

    final_external_id :=
        operation_row.external_id;

    IF operation_row.operation_type
            IS DISTINCT FROM 'send_client_data_request'
        OR operation_row.case_id
            IS DISTINCT FROM p_case_id
        OR operation_row.request_summary ->> 'token_id'
            IS DISTINCT FROM p_token_id::text
        OR operation_row.request_summary ->> 'request_cycle_key'
            IS DISTINCT FROM p_request_cycle_key
        OR operation_row.request_summary ->> 'message_marker'
            IS DISTINCT FROM p_message_marker
        OR operation_row.request_summary ->> 'template_key'
            IS DISTINCT FROM p_template_key
    THEN
        finalization_outcome :=
            'operation_identity_mismatch';

        RETURN NEXT;
        RETURN;
    END IF;

    IF operation_row.status = 'succeeded' THEN
        finalization_outcome :=
            'operation_already_succeeded';

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

    final_case_state :=
        case_row.state;

    IF case_row.state
        IS DISTINCT FROM expected_case_state
    THEN
        finalization_outcome :=
            'invalid_case_state';

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

    final_step_status :=
        step_row.status;

    IF step_row.status NOT IN (
        'in_progress',
        'failed_retryable'
    ) THEN
        finalization_outcome :=
            'invalid_collect_step_status';

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

    final_token_status :=
        token_row.status;

    IF token_row.status = 'delivered' THEN
        finalization_outcome :=
            'token_already_delivered';

        RETURN NEXT;
        RETURN;
    END IF;

    IF token_row.status <> 'issued' THEN
        finalization_outcome :=
            'invalid_token_status';

        RETURN NEXT;
        RETURN;
    END IF;

    IF token_row.expires_at <= v_now THEN
        finalization_outcome :=
            'token_expired';

        RETURN NEXT;
        RETURN;
    END IF;

    response_summary :=
        jsonb_strip_nulls(
            jsonb_build_object(
                'provider',
                'gmail',

                'message_id',
                p_gmail_message_id,

                'thread_id',
                NULLIF(
                    btrim(
                        COALESCE(
                            p_gmail_thread_id,
                            ''
                        )
                    ),
                    ''
                ),

                'message_marker',
                p_message_marker,

                'template_key',
                p_template_key,

                'delivery_source',
                p_delivery_source,

                'finalized_at',
                v_now
            )
        );

    success_applied :=
        complete_external_operation_success(
            p_operation_id,
            p_lease_owner,
            p_gmail_message_id,
            response_summary
        );

    IF success_applied IS NOT TRUE THEN
        finalization_outcome :=
            'lease_not_owned';

        RETURN NEXT;
        RETURN;
    END IF;

    UPDATE onboarding_form_tokens AS token
    SET
        status =
            'delivered',

        delivered_at =
            v_now,

        token_ciphertext =
            NULL,

        token_nonce =
            NULL,

        token_auth_tag =
            NULL,

        encryption_key_id =
            NULL

    WHERE token.id =
          token_row.id;

    UPDATE onboarding_cases AS onboarding_case
    SET
        state =
            'awaiting_client_data'

    WHERE onboarding_case.id =
          case_row.id
      AND onboarding_case.state =
          expected_case_state;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'The onboarding case state changed during delivery finalization';
    END IF;

    UPDATE onboarding_steps AS step
    SET
        status =
            'in_progress',

        completed_at =
            NULL,

        last_error_summary =
            NULL

    WHERE step.id =
          step_row.id;

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
            || ':client-data-request-delivered',

        'client_data_request_delivered',

        'workflow',

        'WF02',

        expected_case_state,

        'awaiting_client_data',

        jsonb_build_object(
            'token_id',
            p_token_id,

            'external_operation_id',
            p_operation_id,

            'request_cycle_key',
            p_request_cycle_key,

            'template_key',
            p_template_key,

            'provider',
            'gmail'
        ),

        case_row.correlation_id
    )
    ON CONFLICT (event_key)
    DO NOTHING;

    finalization_outcome :=
        'finalized';

    final_operation_status :=
        'succeeded';

    final_case_state :=
        'awaiting_client_data';

    final_step_status :=
        'in_progress';

    final_token_status :=
        'delivered';

    final_external_id :=
        p_gmail_message_id;

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION finalize_wf02_delivery_success(
    uuid,
    uuid,
    uuid,
    text,
    text,
    text,
    text,
    text,
    text,
    text
)
IS
'Atomically finalizes successful WF02 Gmail delivery or reconciliation.';

COMMIT;
