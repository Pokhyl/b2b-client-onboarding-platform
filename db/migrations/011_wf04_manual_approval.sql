BEGIN;

CREATE OR REPLACE FUNCTION prepare_wf04_approval_request(
    p_case_id uuid,
    p_correlation_id uuid,
    p_trigger_source text,
    p_accepted_submission_id uuid,
    p_client_id uuid,
    p_external_operation_id uuid,
    p_recovery_reason text,
    p_waiting_execution_id text,
    p_recipient_email text,
    p_template_key text,
    p_message_marker text,
    p_response_timeout_hours integer,
    p_lease_seconds integer,
    p_max_attempts integer
)
RETURNS TABLE (
    preparation_outcome text,
    operation_claim_outcome text,
    operation_id uuid,
    operation_status text,
    operation_attempt_count integer,
    operation_max_attempts integer,
    operation_lease_expires_at timestamptz,
    case_id uuid,
    correlation_id uuid,
    case_state text,
    accepted_submission_id uuid,
    client_id uuid,
    approval_step_id uuid,
    approval_step_status text,
    waiting_execution_id text,
    recipient_email text,
    response_timeout_hours integer,
    legal_name text,
    company_identifier_country text,
    company_identifier_type text,
    company_identifier_value text,
    primary_contact_first_name text,
    primary_contact_last_name text,
    primary_contact_email text,
    primary_contact_phone text,
    case_created_at timestamptz,
    message_marker text,
    template_key text
)
LANGUAGE plpgsql
AS $$
DECLARE
    case_row onboarding_cases%ROWTYPE;
    step_row onboarding_steps%ROWTYPE;
    submission_row onboarding_submissions%ROWTYPE;
    client_row clients%ROWTYPE;
    existing_operation_row external_operations%ROWTYPE;
    claim_row record;

    v_now timestamptz;
    v_recipient_email text;
    v_idempotency_key text;
    v_lease_owner text;
    v_request_summary jsonb;
    v_recover_expired_wait boolean := false;
BEGIN
    IF p_case_id IS NULL
        OR p_correlation_id IS NULL
    THEN
        RAISE EXCEPTION
            'case_id and correlation_id are required';
    END IF;

    IF p_trigger_source NOT IN (
        'wf03',
        'wf98'
    ) THEN
        RAISE EXCEPTION
            'trigger_source must be wf03 or wf98';
    END IF;

    IF p_trigger_source = 'wf03' THEN
        IF p_accepted_submission_id IS NULL
            OR p_client_id IS NULL
            OR p_external_operation_id IS NOT NULL
            OR p_recovery_reason IS NOT NULL
        THEN
            RAISE EXCEPTION
                'WF03 invocation requires accepted_submission_id and client_id only';
        END IF;
    ELSE
        IF p_accepted_submission_id IS NOT NULL
            OR p_client_id IS NOT NULL
        THEN
            RAISE EXCEPTION
                'WF98 invocation must load submission and client references from PostgreSQL';
        END IF;

        IF p_external_operation_id IS NULL
            AND p_recovery_reason
                IS DISTINCT FROM 'missing_initial_dispatch'
        THEN
            RAISE EXCEPTION
                'WF98 invocation requires external_operation_id or missing_initial_dispatch recovery';
        END IF;

        IF p_external_operation_id IS NOT NULL
            AND p_recovery_reason IS NOT NULL
        THEN
            RAISE EXCEPTION
                'WF98 operation retry and state-gap recovery are mutually exclusive';
        END IF;
    END IF;

    IF p_waiting_execution_id IS NULL
        OR btrim(p_waiting_execution_id) = ''
    THEN
        RAISE EXCEPTION
            'waiting_execution_id must not be blank';
    END IF;

    v_recipient_email :=
        lower(
            btrim(
                COALESCE(
                    p_recipient_email,
                    ''
                )
            )
        );

    IF v_recipient_email = ''
        OR v_recipient_email !~
            '^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$'::text
                COLLATE "C"
    THEN
        RAISE EXCEPTION
            'recipient_email is invalid';
    END IF;

    IF p_template_key
        IS DISTINCT FROM 'manual_approval_v1'
    THEN
        RAISE EXCEPTION
            'template_key must be manual_approval_v1';
    END IF;

    IF p_message_marker IS NULL
        OR p_message_marker !~
            '^b2b-approval-[0-9a-f]{24}$'
    THEN
        RAISE EXCEPTION
            'message_marker is invalid';
    END IF;

    IF p_response_timeout_hours IS NULL
        OR p_response_timeout_hours <= 0
        OR p_response_timeout_hours > 720
    THEN
        RAISE EXCEPTION
            'response_timeout_hours must be between 1 and 720';
    END IF;

    IF p_lease_seconds IS NULL
        OR p_lease_seconds <=
            p_response_timeout_hours * 3600
    THEN
        RAISE EXCEPTION
            'lease_seconds must exceed the response timeout';
    END IF;

    IF p_max_attempts IS NULL
        OR p_max_attempts <= 0
        OR p_max_attempts > 20
    THEN
        RAISE EXCEPTION
            'max_attempts must be between 1 and 20';
    END IF;

    v_now :=
        clock_timestamp();

    SELECT onboarding_case.*
    INTO case_row
    FROM onboarding_cases AS onboarding_case
    WHERE onboarding_case.id = p_case_id
    FOR UPDATE;

    IF NOT FOUND THEN
        preparation_outcome :=
            'case_not_found';

        RETURN NEXT;
        RETURN;
    END IF;

    case_id :=
        case_row.id;

    correlation_id :=
        case_row.correlation_id;

    case_state :=
        case_row.state;

    accepted_submission_id :=
        case_row.accepted_submission_id;

    client_id :=
        case_row.client_id;

    case_created_at :=
        case_row.created_at;

    response_timeout_hours :=
        p_response_timeout_hours;

    recipient_email :=
        v_recipient_email;

    waiting_execution_id :=
        p_waiting_execution_id;

    message_marker :=
        p_message_marker;

    template_key :=
        p_template_key;

    IF case_row.correlation_id
        IS DISTINCT FROM p_correlation_id
    THEN
        preparation_outcome :=
            'correlation_mismatch';

        RETURN NEXT;
        RETURN;
    END IF;

    SELECT step.*
    INTO step_row
    FROM onboarding_steps AS step
    WHERE step.case_id = p_case_id
      AND step.step_type = 'manual_approval'
    FOR UPDATE;

    IF NOT FOUND THEN
        preparation_outcome :=
            'approval_step_not_found';

        RETURN NEXT;
        RETURN;
    END IF;

    approval_step_id :=
        step_row.id;

    approval_step_status :=
        step_row.status;

    IF case_row.state = 'rejected' THEN
        IF case_row.approval_decision = 'rejected'
            AND step_row.status = 'completed'
            AND step_row.approval_decision = 'rejected'
            AND step_row.approval_decided_at IS NOT NULL
        THEN
            preparation_outcome :=
                'already_rejected';
        ELSE
            preparation_outcome :=
                'inconsistent_rejected_state';
        END IF;

        RETURN NEXT;
        RETURN;
    END IF;

    IF case_row.state IN (
        'approved',
        'provisioning',
        'provisioning_failed',
        'provisioned',
        'finalizing',
        'finalization_failed',
        'completed'
    ) THEN
        IF case_row.approval_decision = 'approved'
            AND step_row.status = 'completed'
            AND step_row.approval_decision = 'approved'
            AND step_row.approval_decided_at IS NOT NULL
        THEN
            preparation_outcome :=
                'already_approved';
        ELSE
            preparation_outcome :=
                'inconsistent_approved_state';
        END IF;

        RETURN NEXT;
        RETURN;
    END IF;

    IF case_row.state <> 'awaiting_approval' THEN
        preparation_outcome :=
            'not_required';

        RETURN NEXT;
        RETURN;
    END IF;

    IF case_row.approval_decision IS NOT NULL
        OR case_row.approval_decided_at IS NOT NULL
        OR case_row.accepted_submission_id IS NULL
        OR case_row.client_id IS NULL
    THEN
        preparation_outcome :=
            'invalid_case_approval_state';

        RETURN NEXT;
        RETURN;
    END IF;

    SELECT submission.*
    INTO submission_row
    FROM onboarding_submissions AS submission
    WHERE submission.id =
          case_row.accepted_submission_id
      AND submission.case_id =
          case_row.id;

    IF NOT FOUND
        OR submission_row.validation_status <> 'passed'
    THEN
        preparation_outcome :=
            'accepted_submission_invalid';

        RETURN NEXT;
        RETURN;
    END IF;

    SELECT client.*
    INTO client_row
    FROM clients AS client
    WHERE client.id = case_row.client_id;

    IF NOT FOUND
        OR client_row.source_submission_id
            IS DISTINCT FROM
            case_row.accepted_submission_id
    THEN
        preparation_outcome :=
            'canonical_client_invalid';

        RETURN NEXT;
        RETURN;
    END IF;

    IF p_trigger_source = 'wf03'
        AND (
            p_accepted_submission_id
                IS DISTINCT FROM
                case_row.accepted_submission_id
            OR p_client_id
                IS DISTINCT FROM
                case_row.client_id
        )
    THEN
        preparation_outcome :=
            'invocation_identity_mismatch';

        RETURN NEXT;
        RETURN;
    END IF;

    legal_name :=
        client_row.legal_name;

    company_identifier_country :=
        client_row.company_identifier_country;

    company_identifier_type :=
        client_row.company_identifier_type;

    company_identifier_value :=
        client_row.company_identifier_value;

    primary_contact_first_name :=
        client_row.primary_contact_first_name;

    primary_contact_last_name :=
        client_row.primary_contact_last_name;

    primary_contact_email :=
        client_row.primary_contact_email;

    primary_contact_phone :=
        client_row.primary_contact_phone;

    v_idempotency_key :=
        'onboarding:'
        || case_row.id::text
        || ':send-approval-request';

    v_lease_owner :=
        'WF04:'
        || p_waiting_execution_id;

    v_request_summary :=
        jsonb_build_object(
            'recipient_email',
            v_recipient_email,

            'template_key',
            p_template_key,

            'case_id',
            case_row.id,

            'accepted_submission_id',
            case_row.accepted_submission_id,

            'client_id',
            case_row.client_id,

            'message_marker',
            p_message_marker,

            'response_timeout_hours',
            p_response_timeout_hours
        );

    SELECT operation.*
    INTO existing_operation_row
    FROM external_operations AS operation
    WHERE operation.idempotency_key =
          v_idempotency_key
    FOR UPDATE;

    IF step_row.status = 'waiting' THEN
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

    IF step_row.status = 'completed' THEN
        preparation_outcome :=
            'inconsistent_completed_step';

        RETURN NEXT;
        RETURN;
    END IF;

    IF step_row.status = 'failed_terminal' THEN
        preparation_outcome :=
            'approval_step_terminal';

        RETURN NEXT;
        RETURN;
    END IF;

    IF step_row.status NOT IN (
        'pending',
        'failed_retryable'
    )
        AND NOT v_recover_expired_wait
    THEN
        preparation_outcome :=
            'invalid_approval_step_status';

        RETURN NEXT;
        RETURN;
    END IF;

    SELECT claim.*
    INTO claim_row
    FROM claim_external_operation(
        v_idempotency_key,
        'send_approval_request',
        case_row.id,
        v_lease_owner,
        p_lease_seconds,
        p_max_attempts,
        v_request_summary
    ) AS claim;

    operation_claim_outcome :=
        claim_row.claim_outcome;

    operation_id :=
        claim_row.operation_id;

    operation_status :=
        claim_row.operation_status;

    operation_attempt_count :=
        claim_row.current_attempt_count;

    operation_max_attempts :=
        claim_row.configured_max_attempts;

    operation_lease_expires_at :=
        claim_row.current_lease_expires_at;

    IF p_external_operation_id IS NOT NULL
        AND claim_row.operation_id
            IS DISTINCT FROM p_external_operation_id
    THEN
        RAISE EXCEPTION
            'The supplied external operation does not match the deterministic approval operation';
    END IF;

    IF claim_row.claim_outcome = 'claimed' THEN
        UPDATE onboarding_steps AS step
        SET
            status =
                'waiting',

            attempt_count =
                step.attempt_count + 1,

            started_at =
                COALESCE(
                    step.started_at,
                    v_now
                ),

            completed_at =
                NULL,

            last_error_summary =
                NULL,

            n8n_wait_execution_id =
                p_waiting_execution_id,

            approval_recipient_email =
                v_recipient_email,

            approval_decision =
                NULL,

            approval_decided_at =
                NULL,

            approval_response_metadata =
                NULL

        WHERE step.id = step_row.id;

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
            case_row.id,

            'onboarding:'
                || case_row.id::text
                || ':manual-approval-requested',

            'manual_approval_requested',

            'workflow',

            'WF04',

            NULL,

            NULL,

            jsonb_build_object(
                'external_operation_id',
                claim_row.operation_id,

                'waiting_execution_id',
                p_waiting_execution_id,

                'recipient_email',
                v_recipient_email,

                'response_timeout_hours',
                p_response_timeout_hours,

                'template_key',
                p_template_key
            ),

            case_row.correlation_id
        )
        ON CONFLICT (event_key)
        DO NOTHING;

        preparation_outcome :=
            'ready_to_send';

        approval_step_status :=
            'waiting';

        operation_status :=
            'in_progress';

    ELSIF claim_row.claim_outcome = 'reuse_succeeded' THEN
        preparation_outcome :=
            'inconsistent_succeeded_operation';

    ELSIF claim_row.claim_outcome = 'busy' THEN
        preparation_outcome :=
            'inconsistent_busy_operation';

    ELSIF claim_row.claim_outcome = 'not_due' THEN
        preparation_outcome :=
            'not_due';

    ELSIF claim_row.claim_outcome IN (
        'refused_terminal',
        'refused_exhausted'
    ) THEN
        preparation_outcome :=
            'operator_intervention_required';

    ELSE
        preparation_outcome :=
            'unsupported_claim_outcome';
    END IF;

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION prepare_wf04_approval_request(
    uuid,
    uuid,
    text,
    uuid,
    uuid,
    uuid,
    text,
    text,
    text,
    text,
    text,
    integer,
    integer,
    integer
)
IS
'Atomically validates WF04 prerequisites, claims the approval operation, and reserves the manual approval wait.';


CREATE OR REPLACE FUNCTION finalize_wf04_approval_decision(
    p_case_id uuid,
    p_operation_id uuid,
    p_lease_owner text,
    p_waiting_execution_id text,
    p_recipient_email text,
    p_decision text,
    p_responded_at timestamptz,
    p_gmail_message_id text,
    p_gmail_thread_id text,
    p_operator_comment text,
    p_response_source text
)
RETURNS TABLE (
    finalization_outcome text,
    final_case_state text,
    final_step_status text,
    final_decision text,
    final_operation_status text,
    final_client_id uuid,
    final_accepted_submission_id uuid
)
LANGUAGE plpgsql
AS $$
DECLARE
    case_row onboarding_cases%ROWTYPE;
    step_row onboarding_steps%ROWTYPE;
    operation_row external_operations%ROWTYPE;

    v_now timestamptz;
    v_recipient_email text;
    v_operator_comment text;
    v_response_metadata jsonb;
    v_response_summary jsonb;
    v_success_applied boolean;
BEGIN
    IF p_case_id IS NULL
        OR p_operation_id IS NULL
    THEN
        RAISE EXCEPTION
            'case_id and operation_id are required';
    END IF;

    IF p_lease_owner IS NULL
        OR btrim(p_lease_owner) = ''
        OR p_waiting_execution_id IS NULL
        OR btrim(p_waiting_execution_id) = ''
        OR p_lease_owner IS DISTINCT FROM
            'WF04:' || p_waiting_execution_id
    THEN
        RAISE EXCEPTION
            'lease_owner and waiting_execution_id are invalid';
    END IF;

    v_recipient_email :=
        lower(
            btrim(
                COALESCE(
                    p_recipient_email,
                    ''
                )
            )
        );

    IF v_recipient_email = '' THEN
        RAISE EXCEPTION
            'recipient_email must not be blank';
    END IF;

    IF p_decision NOT IN (
        'approved',
        'rejected'
    ) THEN
        RAISE EXCEPTION
            'decision must be approved or rejected';
    END IF;

    IF p_responded_at IS NULL THEN
        RAISE EXCEPTION
            'responded_at is required';
    END IF;

    IF p_response_source
        IS DISTINCT FROM 'n8n_send_and_wait'
    THEN
        RAISE EXCEPTION
            'response_source must be n8n_send_and_wait';
    END IF;

    v_operator_comment :=
        NULLIF(
            btrim(
                regexp_replace(
                    COALESCE(
                        p_operator_comment,
                        ''
                    ),
                    '[[:cntrl:]]+',
                    ' ',
                    'g'
                )
            ),
            ''
        );

    IF length(
        COALESCE(
            v_operator_comment,
            ''
        )
    ) > 1000 THEN
        RAISE EXCEPTION
            'operator_comment exceeds 1000 characters';
    END IF;

    v_now :=
        clock_timestamp();

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

    final_client_id :=
        case_row.client_id;

    final_accepted_submission_id :=
        case_row.accepted_submission_id;

    SELECT step.*
    INTO step_row
    FROM onboarding_steps AS step
    WHERE step.case_id = p_case_id
      AND step.step_type = 'manual_approval'
    FOR UPDATE;

    IF NOT FOUND THEN
        finalization_outcome :=
            'approval_step_not_found';

        RETURN NEXT;
        RETURN;
    END IF;

    final_step_status :=
        step_row.status;

    final_decision :=
        step_row.approval_decision;

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

    IF operation_row.operation_type
            IS DISTINCT FROM 'send_approval_request'
        OR operation_row.case_id
            IS DISTINCT FROM p_case_id
        OR operation_row.request_summary ->> 'case_id'
            IS DISTINCT FROM p_case_id::text
        OR operation_row.request_summary ->> 'accepted_submission_id'
            IS DISTINCT FROM
                case_row.accepted_submission_id::text
        OR operation_row.request_summary ->> 'client_id'
            IS DISTINCT FROM case_row.client_id::text
        OR lower(
                operation_row.request_summary ->>
                    'recipient_email'
            ) IS DISTINCT FROM v_recipient_email
    THEN
        finalization_outcome :=
            'operation_identity_mismatch';

        RETURN NEXT;
        RETURN;
    END IF;

    IF case_row.state = 'rejected'
        OR case_row.state IN (
            'approved',
            'provisioning',
            'provisioning_failed',
            'provisioned',
            'finalizing',
            'finalization_failed',
            'completed'
        )
    THEN
        IF step_row.status = 'completed'
            AND operation_row.status = 'succeeded'
            AND case_row.approval_decision
                IS NOT DISTINCT FROM p_decision
            AND step_row.approval_decision
                IS NOT DISTINCT FROM p_decision
        THEN
            finalization_outcome :=
                'already_finalized';
        ELSE
            finalization_outcome :=
                'stale_or_conflicting_response';
        END IF;

        RETURN NEXT;
        RETURN;
    END IF;

    IF case_row.state <> 'awaiting_approval'
        OR case_row.approval_decision IS NOT NULL
        OR case_row.approval_decided_at IS NOT NULL
        OR step_row.status <> 'waiting'
        OR step_row.n8n_wait_execution_id
            IS DISTINCT FROM p_waiting_execution_id
        OR lower(
                btrim(
                    step_row.approval_recipient_email
                )
            ) IS DISTINCT FROM v_recipient_email
        OR operation_row.status <> 'in_progress'
        OR operation_row.lease_owner
            IS DISTINCT FROM p_lease_owner
        OR operation_row.lease_expires_at <= v_now
    THEN
        finalization_outcome :=
            'response_context_invalid';

        RETURN NEXT;
        RETURN;
    END IF;

    v_response_metadata :=
        jsonb_strip_nulls(
            jsonb_build_object(
                'response_source',
                p_response_source,

                'expected_recipient',
                v_recipient_email,

                'decision',
                p_decision,

                'responded_at',
                p_responded_at,

                'message_id',
                NULLIF(
                    btrim(
                        COALESCE(
                            p_gmail_message_id,
                            ''
                        )
                    ),
                    ''
                ),

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

                'waiting_execution_id',
                p_waiting_execution_id,

                'operator_comment',
                v_operator_comment
            )
        );

    v_response_summary :=
        jsonb_strip_nulls(
            jsonb_build_object(
                'provider',
                'gmail',

                'decision',
                p_decision,

                'responded_at',
                p_responded_at,

                'message_id',
                NULLIF(
                    btrim(
                        COALESCE(
                            p_gmail_message_id,
                            ''
                        )
                    ),
                    ''
                ),

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

                'response_source',
                p_response_source,

                'finalized_at',
                v_now
            )
        );

    v_success_applied :=
        complete_external_operation_success(
            p_operation_id,
            p_lease_owner,
            NULLIF(
                btrim(
                    COALESCE(
                        p_gmail_message_id,
                        ''
                    )
                ),
                ''
            ),
            v_response_summary
        );

    IF v_success_applied IS NOT TRUE THEN
        finalization_outcome :=
            'lease_not_owned';

        RETURN NEXT;
        RETURN;
    END IF;

    UPDATE onboarding_steps AS step
    SET
        status =
            'completed',

        completed_at =
            v_now,

        last_error_summary =
            NULL,

        approval_decision =
            p_decision,

        approval_decided_at =
            p_responded_at,

        approval_response_metadata =
            v_response_metadata

    WHERE step.id = step_row.id;

    UPDATE onboarding_cases AS onboarding_case
    SET
        state =
            CASE
                WHEN p_decision = 'approved'
                    THEN 'approved'
                ELSE 'rejected'
            END,

        approval_decision =
            p_decision,

        approval_decided_at =
            p_responded_at,

        rejected_at =
            CASE
                WHEN p_decision = 'rejected'
                    THEN p_responded_at
                ELSE NULL
            END

    WHERE onboarding_case.id = case_row.id
      AND onboarding_case.state = 'awaiting_approval'
      AND onboarding_case.approval_decision IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'The onboarding case changed during approval finalization';
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
        case_row.id,

        'onboarding:'
            || case_row.id::text
            || CASE
                WHEN p_decision = 'approved'
                    THEN ':manual-approval-approved'
                ELSE ':manual-approval-rejected'
            END,

        CASE
            WHEN p_decision = 'approved'
                THEN 'manual_approval_approved'
            ELSE 'manual_approval_rejected'
        END,

        'external_user',

        v_recipient_email,

        'awaiting_approval',

        CASE
            WHEN p_decision = 'approved'
                THEN 'approved'
            ELSE 'rejected'
        END,

        jsonb_strip_nulls(
            jsonb_build_object(
                'external_operation_id',
                p_operation_id,

                'waiting_execution_id',
                p_waiting_execution_id,

                'response_source',
                p_response_source,

                'message_id',
                NULLIF(
                    btrim(
                        COALESCE(
                            p_gmail_message_id,
                            ''
                        )
                    ),
                    ''
                )
            )
        ),

        case_row.correlation_id
    )
    ON CONFLICT (event_key)
    DO NOTHING;

    finalization_outcome :=
        'finalized';

    final_case_state :=
        CASE
            WHEN p_decision = 'approved'
                THEN 'approved'
            ELSE 'rejected'
        END;

    final_step_status :=
        'completed';

    final_decision :=
        p_decision;

    final_operation_status :=
        'succeeded';

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION finalize_wf04_approval_decision(
    uuid,
    uuid,
    text,
    text,
    text,
    text,
    timestamptz,
    text,
    text,
    text,
    text
)
IS
'Atomically validates and persists the first valid WF04 approval decision.';


CREATE OR REPLACE FUNCTION finalize_wf04_approval_failure(
    p_case_id uuid,
    p_operation_id uuid,
    p_lease_owner text,
    p_waiting_execution_id text,
    p_recipient_email text,
    p_retryable boolean,
    p_error_class text,
    p_error_summary jsonb,
    p_next_retry_at timestamptz
)
RETURNS TABLE (
    finalization_outcome text,
    final_operation_status text,
    final_step_status text,
    final_case_state text
)
LANGUAGE plpgsql
AS $$
DECLARE
    case_row onboarding_cases%ROWTYPE;
    step_row onboarding_steps%ROWTYPE;
    operation_row external_operations%ROWTYPE;

    v_now timestamptz;
    v_recipient_email text;
    v_operation_status text;
    v_step_error jsonb;
BEGIN
    IF p_case_id IS NULL
        OR p_operation_id IS NULL
    THEN
        RAISE EXCEPTION
            'case_id and operation_id are required';
    END IF;

    IF p_lease_owner IS NULL
        OR btrim(p_lease_owner) = ''
        OR p_waiting_execution_id IS NULL
        OR btrim(p_waiting_execution_id) = ''
        OR p_lease_owner IS DISTINCT FROM
            'WF04:' || p_waiting_execution_id
    THEN
        RAISE EXCEPTION
            'lease_owner and waiting_execution_id are invalid';
    END IF;

    v_recipient_email :=
        lower(
            btrim(
                COALESCE(
                    p_recipient_email,
                    ''
                )
            )
        );

    IF v_recipient_email = '' THEN
        RAISE EXCEPTION
            'recipient_email must not be blank';
    END IF;

    IF p_retryable IS NULL THEN
        RAISE EXCEPTION
            'retryable must not be null';
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

    IF p_retryable
        AND p_next_retry_at IS NULL
    THEN
        RAISE EXCEPTION
            'next_retry_at is required for retryable failure';
    END IF;

    v_now :=
        clock_timestamp();

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

    SELECT step.*
    INTO step_row
    FROM onboarding_steps AS step
    WHERE step.case_id = p_case_id
      AND step.step_type = 'manual_approval'
    FOR UPDATE;

    IF NOT FOUND THEN
        finalization_outcome :=
            'approval_step_not_found';

        RETURN NEXT;
        RETURN;
    END IF;

    final_step_status :=
        step_row.status;

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

    IF case_row.state <> 'awaiting_approval'
        OR case_row.approval_decision IS NOT NULL
        OR step_row.status <> 'waiting'
        OR step_row.n8n_wait_execution_id
            IS DISTINCT FROM p_waiting_execution_id
        OR lower(
                btrim(
                    step_row.approval_recipient_email
                )
            ) IS DISTINCT FROM v_recipient_email
        OR operation_row.operation_type
            IS DISTINCT FROM 'send_approval_request'
        OR operation_row.case_id
            IS DISTINCT FROM p_case_id
        OR operation_row.status <> 'in_progress'
        OR operation_row.lease_owner
            IS DISTINCT FROM p_lease_owner
        OR operation_row.lease_expires_at <= v_now
    THEN
        finalization_outcome :=
            'failure_context_invalid';

        RETURN NEXT;
        RETURN;
    END IF;

    v_operation_status :=
        complete_external_operation_failure(
            p_operation_id,
            p_lease_owner,
            p_retryable,
            p_error_class,
            p_error_summary,
            p_next_retry_at
        );

    IF v_operation_status IN (
        'operation_not_found',
        'lease_not_owned'
    ) THEN
        finalization_outcome :=
            v_operation_status;

        RETURN NEXT;
        RETURN;
    END IF;

    v_step_error :=
        jsonb_build_object(
            'error_class',
            p_error_class,

            'error_summary',
            p_error_summary,

            'external_operation_id',
            p_operation_id,

            'failed_at',
            v_now
        );

    UPDATE onboarding_steps AS step
    SET
        status =
            v_operation_status,

        completed_at =
            CASE
                WHEN v_operation_status =
                    'failed_terminal'
                    THEN v_now
                ELSE NULL
            END,

        last_error_summary =
            v_step_error,

        n8n_wait_execution_id =
            NULL,

        approval_recipient_email =
            NULL,

        approval_decision =
            NULL,

        approval_decided_at =
            NULL,

        approval_response_metadata =
            NULL

    WHERE step.id = step_row.id;

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
        case_row.id,

        'onboarding:'
            || case_row.id::text
            || ':manual-approval-request-failed',

        'manual_approval_request_failed',

        'workflow',

        'WF04',

        NULL,

        NULL,

        jsonb_build_object(
            'external_operation_id',
            p_operation_id,

            'error_class',
            p_error_class,

            'operation_status',
            v_operation_status,

            'retryable',
            v_operation_status =
                'failed_retryable'
        ),

        case_row.correlation_id
    )
    ON CONFLICT (event_key)
    DO NOTHING;

    finalization_outcome :=
        'finalized';

    final_operation_status :=
        v_operation_status;

    final_step_status :=
        v_operation_status;

    final_case_state :=
        'awaiting_approval';

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION finalize_wf04_approval_failure(
    uuid,
    uuid,
    text,
    text,
    text,
    boolean,
    text,
    jsonb,
    timestamptz
)
IS
'Atomically finalizes a clear WF04 pre-response failure without persisting a false decision.';

COMMIT;
