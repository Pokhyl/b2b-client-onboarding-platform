\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION prepare_wf06_finalization_operation(
    p_case_id uuid,
    p_correlation_id uuid,
    p_trigger_source text,
    p_client_id uuid,
    p_accepted_submission_id uuid,
    p_external_client_id text,
    p_external_operation_id uuid,
    p_recovery_reason text,
    p_execution_id text,
    p_configuration jsonb,
    p_lease_seconds integer,
    p_max_attempts integer
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_case onboarding_cases%ROWTYPE;
    v_client clients%ROWTYPE;
    v_submission onboarding_submissions%ROWTYPE;
    v_provision_step onboarding_steps%ROWTYPE;
    v_drive_step onboarding_steps%ROWTYPE;
    v_calendar_step onboarding_steps%ROWTYPE;
    v_notification_step onboarding_steps%ROWTYPE;
    v_current_step onboarding_steps%ROWTYPE;

    v_provision_operation external_operations%ROWTYPE;
    v_drive_operation external_operations%ROWTYPE;
    v_calendar_operation external_operations%ROWTYPE;
    v_notification_operation external_operations%ROWTYPE;
    v_current_operation external_operations%ROWTYPE;
    v_claim record;

    v_drive_found boolean := false;
    v_calendar_found boolean := false;
    v_notification_found boolean := false;
    v_current_operation_found boolean := false;
    v_all_succeeded boolean := false;

    v_operation_type text;
    v_idempotency_key text;
    v_lease_owner text;
    v_request_summary jsonb;
    v_operation_key_hash text;
    v_previous_state text;
    v_cycle_number integer;

    v_folder_name_template text;
    v_folder_name text;
    v_drive_parent_folder_id text;
    v_drive_use_shared_drive boolean;
    v_drive_folder_id text;
    v_drive_folder_link text;

    v_calendar_id text;
    v_kickoff_timezone text;
    v_kickoff_delay_days integer;
    v_kickoff_start_local_time time;
    v_kickoff_duration_minutes integer;
    v_internal_attendee_email text;
    v_kickoff_local_date date;
    v_kickoff_start_at timestamptz;
    v_kickoff_end_at timestamptz;
    v_calendar_event_id text;
    v_calendar_event_link text;

    v_team_recipients jsonb;
    v_team_sender_name text;
    v_team_template_key text;
    v_message_marker text;
BEGIN
    IF p_case_id IS NULL
        OR p_correlation_id IS NULL
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'invalid_internal_invocation',
            'error_code',
            'missing_case_identity'
        );
    END IF;

    IF p_execution_id IS NULL
        OR btrim(p_execution_id) = ''
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'invalid_internal_invocation',
            'error_code',
            'missing_execution_id',
            'case_id',
            p_case_id
        );
    END IF;

    IF p_configuration IS NULL
        OR jsonb_typeof(p_configuration) <> 'object'
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'invalid_configuration',
            'error_code',
            'configuration_not_object',
            'case_id',
            p_case_id
        );
    END IF;

    IF p_lease_seconds IS NULL
        OR p_lease_seconds <= 0
        OR p_max_attempts IS NULL
        OR p_max_attempts <= 0
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'invalid_configuration',
            'error_code',
            'invalid_operation_configuration',
            'case_id',
            p_case_id
        );
    END IF;

    IF p_trigger_source = 'wf05' THEN
        IF p_client_id IS NULL
            OR p_accepted_submission_id IS NULL
            OR p_external_client_id IS NULL
            OR btrim(p_external_client_id) = ''
            OR p_external_operation_id IS NOT NULL
            OR p_recovery_reason IS NOT NULL
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'invalid_internal_invocation',
                'error_code',
                'invalid_wf05_invocation',
                'case_id',
                p_case_id
            );
        END IF;

    ELSIF p_trigger_source = 'wf98' THEN
        IF p_client_id IS NOT NULL
            OR p_accepted_submission_id IS NOT NULL
            OR p_external_client_id IS NOT NULL
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'invalid_internal_invocation',
                'error_code',
                'invalid_wf98_authoritative_fields',
                'case_id',
                p_case_id
            );
        END IF;

        IF p_external_operation_id IS NOT NULL THEN
            IF p_recovery_reason IS NOT NULL THEN
                RETURN jsonb_build_object(
                    'preparation_outcome',
                    'invalid_internal_invocation',
                    'error_code',
                    'retry_operation_with_recovery_reason',
                    'case_id',
                    p_case_id
                );
            END IF;
        ELSIF p_recovery_reason IS NULL
            OR p_recovery_reason NOT IN (
                'missing_initial_dispatch',
                'resume_finalization',
                'complete_finalization'
            )
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'invalid_internal_invocation',
                'error_code',
                'invalid_wf98_recovery_invocation',
                'case_id',
                p_case_id
            );
        END IF;

    ELSE
        RETURN jsonb_build_object(
            'preparation_outcome',
            'invalid_internal_invocation',
            'error_code',
            'invalid_trigger_source',
            'case_id',
            p_case_id,
            'trigger_source',
            p_trigger_source
        );
    END IF;

    SELECT onboarding_case.*
    INTO v_case
    FROM onboarding_cases AS onboarding_case
    WHERE onboarding_case.id = p_case_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'case_not_found',
            'case_id',
            p_case_id
        );
    END IF;

    IF v_case.correlation_id
        IS DISTINCT FROM p_correlation_id
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'invalid_internal_invocation',
            'error_code',
            'correlation_id_mismatch',
            'case_id',
            v_case.id,
            'correlation_id',
            v_case.correlation_id
        );
    END IF;

    IF p_trigger_source = 'wf05'
        AND (
            v_case.client_id
                IS DISTINCT FROM p_client_id
            OR v_case.accepted_submission_id
                IS DISTINCT FROM p_accepted_submission_id
            OR v_case.external_client_id
                IS DISTINCT FROM btrim(p_external_client_id)
        )
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'invalid_internal_invocation',
            'error_code',
            'authoritative_reference_mismatch',
            'case_id',
            v_case.id
        );
    END IF;

    IF v_case.state NOT IN (
        'provisioned',
        'finalizing',
        'finalization_failed',
        'completed'
    ) THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'not_required',
            'case_id',
            v_case.id,
            'correlation_id',
            v_case.correlation_id,
            'case_state',
            v_case.state
        );
    END IF;

    IF v_case.client_id IS NULL
        OR v_case.accepted_submission_id IS NULL
        OR v_case.external_client_id IS NULL
        OR btrim(v_case.external_client_id) = ''
        OR v_case.approval_decision <> 'approved'
        OR v_case.approval_decided_at IS NULL
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'finalization_prerequisite_invalid',
            'case_id',
            v_case.id,
            'case_state',
            v_case.state
        );
    END IF;

    SELECT submission.*
    INTO v_submission
    FROM onboarding_submissions AS submission
    WHERE submission.id =
          v_case.accepted_submission_id
      AND submission.case_id =
          v_case.id;

    IF NOT FOUND
        OR v_submission.validation_status <> 'passed'
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'accepted_submission_invalid',
            'case_id',
            v_case.id
        );
    END IF;

    SELECT client.*
    INTO v_client
    FROM clients AS client
    WHERE client.id = v_case.client_id;

    IF NOT FOUND
        OR v_client.source_submission_id
            IS DISTINCT FROM
            v_case.accepted_submission_id
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'canonical_client_invalid',
            'case_id',
            v_case.id
        );
    END IF;

    SELECT step.*
    INTO v_provision_step
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case.id
      AND step.step_type = 'provision_client'
    FOR UPDATE;

    IF NOT FOUND
        OR v_provision_step.status <> 'completed'
        OR v_provision_step.completed_at IS NULL
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'provision_step_invalid',
            'case_id',
            v_case.id
        );
    END IF;

    SELECT operation.*
    INTO v_provision_operation
    FROM external_operations AS operation
    WHERE operation.idempotency_key =
          'onboarding:' ||
          v_case.id::text ||
          ':provision-client'
    FOR UPDATE;

    IF NOT FOUND
        OR v_provision_operation.case_id
            IS DISTINCT FROM v_case.id
        OR v_provision_operation.operation_type
            IS DISTINCT FROM 'provision_client'
        OR v_provision_operation.status
            IS DISTINCT FROM 'succeeded'
        OR v_provision_operation.external_id
            IS DISTINCT FROM
            v_case.external_client_id
        OR v_provision_operation.completed_at IS NULL
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'provision_operation_invalid',
            'case_id',
            v_case.id
        );
    END IF;

    SELECT step.*
    INTO v_drive_step
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case.id
      AND step.step_type = 'create_drive_folder'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'drive_step_missing',
            'case_id',
            v_case.id
        );
    END IF;

    SELECT step.*
    INTO v_calendar_step
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case.id
      AND step.step_type = 'create_kickoff_event'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'calendar_step_missing',
            'case_id',
            v_case.id
        );
    END IF;

    SELECT step.*
    INTO v_notification_step
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case.id
      AND step.step_type = 'notify_team'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'notification_step_missing',
            'case_id',
            v_case.id
        );
    END IF;

    SELECT operation.*
    INTO v_drive_operation
    FROM external_operations AS operation
    WHERE operation.idempotency_key =
          'onboarding:' ||
          v_case.id::text ||
          ':create-drive-folder'
    FOR UPDATE;

    v_drive_found := FOUND;

    SELECT operation.*
    INTO v_calendar_operation
    FROM external_operations AS operation
    WHERE operation.idempotency_key =
          'onboarding:' ||
          v_case.id::text ||
          ':create-kickoff-event'
    FOR UPDATE;

    v_calendar_found := FOUND;

    SELECT operation.*
    INTO v_notification_operation
    FROM external_operations AS operation
    WHERE operation.idempotency_key =
          'onboarding:' ||
          v_case.id::text ||
          ':notify-team'
    FOR UPDATE;

    v_notification_found := FOUND;

    IF v_drive_found
        AND (
            v_drive_operation.case_id
                IS DISTINCT FROM v_case.id
            OR v_drive_operation.operation_type
                IS DISTINCT FROM 'create_drive_folder'
        )
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'drive_operation_identity_mismatch',
            'case_id',
            v_case.id
        );
    END IF;

    IF v_calendar_found
        AND (
            v_calendar_operation.case_id
                IS DISTINCT FROM v_case.id
            OR v_calendar_operation.operation_type
                IS DISTINCT FROM 'create_kickoff_event'
        )
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'calendar_operation_identity_mismatch',
            'case_id',
            v_case.id
        );
    END IF;

    IF v_notification_found
        AND (
            v_notification_operation.case_id
                IS DISTINCT FROM v_case.id
            OR v_notification_operation.operation_type
                IS DISTINCT FROM 'notify_team'
        )
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'notification_operation_identity_mismatch',
            'case_id',
            v_case.id
        );
    END IF;

    IF (
        NOT v_drive_found
        AND v_drive_step.status <> 'pending'
    )
        OR (
            v_drive_found
            AND (
                (v_drive_operation.status = 'pending'
                    AND v_drive_step.status <> 'pending')
                OR (v_drive_operation.status = 'in_progress'
                    AND v_drive_step.status <> 'in_progress')
                OR (v_drive_operation.status = 'succeeded'
                    AND (
                        v_drive_step.status <> 'completed'
                        OR v_drive_step.completed_at IS NULL
                        OR v_drive_operation.external_id IS NULL
                        OR btrim(v_drive_operation.external_id) = ''
                    ))
                OR (v_drive_operation.status = 'failed_retryable'
                    AND v_drive_step.status <> 'failed_retryable')
                OR (v_drive_operation.status = 'failed_terminal'
                    AND v_drive_step.status <> 'failed_terminal')
            )
        )
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'drive_operation_step_mismatch',
            'case_id',
            v_case.id
        );
    END IF;

    IF (
        NOT v_calendar_found
        AND v_calendar_step.status <> 'pending'
    )
        OR (
            v_calendar_found
            AND (
                (v_calendar_operation.status = 'pending'
                    AND v_calendar_step.status <> 'pending')
                OR (v_calendar_operation.status = 'in_progress'
                    AND v_calendar_step.status <> 'in_progress')
                OR (v_calendar_operation.status = 'succeeded'
                    AND (
                        v_calendar_step.status <> 'completed'
                        OR v_calendar_step.completed_at IS NULL
                        OR v_calendar_operation.external_id IS NULL
                        OR btrim(v_calendar_operation.external_id) = ''
                    ))
                OR (v_calendar_operation.status = 'failed_retryable'
                    AND v_calendar_step.status <> 'failed_retryable')
                OR (v_calendar_operation.status = 'failed_terminal'
                    AND v_calendar_step.status <> 'failed_terminal')
            )
        )
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'calendar_operation_step_mismatch',
            'case_id',
            v_case.id
        );
    END IF;

    IF (
        NOT v_notification_found
        AND v_notification_step.status <> 'pending'
    )
        OR (
            v_notification_found
            AND (
                (v_notification_operation.status = 'pending'
                    AND v_notification_step.status <> 'pending')
                OR (v_notification_operation.status = 'in_progress'
                    AND v_notification_step.status <> 'in_progress')
                OR (v_notification_operation.status = 'succeeded'
                    AND (
                        v_notification_step.status <> 'completed'
                        OR v_notification_step.completed_at IS NULL
                        OR v_notification_operation.external_id IS NULL
                        OR btrim(v_notification_operation.external_id) = ''
                    ))
                OR (v_notification_operation.status = 'failed_retryable'
                    AND v_notification_step.status <> 'failed_retryable')
                OR (v_notification_operation.status = 'failed_terminal'
                    AND v_notification_step.status <> 'failed_terminal')
            )
        )
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'notification_operation_step_mismatch',
            'case_id',
            v_case.id
        );
    END IF;

    IF (
        NOT v_drive_found
        OR v_drive_operation.status <> 'succeeded'
    )
        AND (
            v_calendar_found
            OR v_notification_found
            OR v_calendar_step.status <> 'pending'
            OR v_notification_step.status <> 'pending'
        )
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'out_of_order_finalization_state',
            'case_id',
            v_case.id,
            'expected_operation_type',
            'create_drive_folder'
        );
    END IF;

    IF v_drive_found
        AND v_drive_operation.status = 'succeeded'
        AND (
            NOT v_calendar_found
            OR v_calendar_operation.status <> 'succeeded'
        )
        AND (
            v_notification_found
            OR v_notification_step.status <> 'pending'
        )
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'out_of_order_finalization_state',
            'case_id',
            v_case.id,
            'expected_operation_type',
            'create_kickoff_event'
        );
    END IF;

    v_all_succeeded :=
        v_drive_found
        AND v_drive_operation.status = 'succeeded'
        AND v_calendar_found
        AND v_calendar_operation.status = 'succeeded'
        AND v_notification_found
        AND v_notification_operation.status = 'succeeded';

    IF v_case.state = 'completed' THEN
        IF v_all_succeeded
            AND v_case.completed_at IS NOT NULL
            AND v_drive_step.status = 'completed'
            AND v_calendar_step.status = 'completed'
            AND v_notification_step.status = 'completed'
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'already_completed',
                'case_id',
                v_case.id,
                'correlation_id',
                v_case.correlation_id,
                'client_id',
                v_case.client_id,
                'accepted_submission_id',
                v_case.accepted_submission_id,
                'external_client_id',
                v_case.external_client_id,
                'drive_folder_id',
                v_drive_operation.external_id,
                'kickoff_event_id',
                v_calendar_operation.external_id,
                'team_message_id',
                v_notification_operation.external_id,
                'case_state',
                v_case.state
            );
        END IF;

        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'inconsistent_completed_state',
            'case_id',
            v_case.id
        );
    END IF;

    IF v_all_succeeded THEN
        IF v_case.state <> 'finalizing' THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'data_integrity_failure',
                'error_code',
                'all_operations_succeeded_outside_finalizing',
                'case_id',
                v_case.id,
                'case_state',
                v_case.state
            );
        END IF;

        IF p_trigger_source = 'wf98'
            AND p_recovery_reason IS NOT NULL
            AND p_recovery_reason <>
                'complete_finalization'
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'invalid_internal_invocation',
                'error_code',
                'wrong_completion_recovery_reason',
                'case_id',
                v_case.id
            );
        END IF;

        RETURN jsonb_build_object(
            'preparation_outcome',
            'ready_to_complete',
            'case_id',
            v_case.id,
            'correlation_id',
            v_case.correlation_id,
            'client_id',
            v_case.client_id,
            'accepted_submission_id',
            v_case.accepted_submission_id,
            'external_client_id',
            v_case.external_client_id,
            'drive_folder_id',
            v_drive_operation.external_id,
            'kickoff_event_id',
            v_calendar_operation.external_id,
            'team_message_id',
            v_notification_operation.external_id,
            'case_state',
            v_case.state
        );
    END IF;

    IF p_trigger_source = 'wf98'
        AND p_recovery_reason =
            'complete_finalization'
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'invalid_internal_invocation',
            'error_code',
            'completion_prerequisites_not_met',
            'case_id',
            v_case.id
        );
    END IF;

    IF NOT v_drive_found
        OR v_drive_operation.status <> 'succeeded'
    THEN
        v_operation_type := 'create_drive_folder';
        v_current_step := v_drive_step;
        v_current_operation := v_drive_operation;
        v_current_operation_found := v_drive_found;

    ELSIF NOT v_calendar_found
        OR v_calendar_operation.status <> 'succeeded'
    THEN
        v_operation_type := 'create_kickoff_event';
        v_current_step := v_calendar_step;
        v_current_operation := v_calendar_operation;
        v_current_operation_found := v_calendar_found;

    ELSE
        v_operation_type := 'notify_team';
        v_current_step := v_notification_step;
        v_current_operation := v_notification_operation;
        v_current_operation_found := v_notification_found;
    END IF;

    IF v_current_operation_found
        AND v_current_operation.status =
            'failed_terminal'
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'failed_terminal',
            'operation_claim_outcome',
            'refused_terminal',
            'case_id',
            v_case.id,
            'operation_id',
            v_current_operation.id,
            'operation_type',
            v_operation_type,
            'case_state',
            v_case.state,
            'requires_intervention',
            true
        );
    END IF;

    IF p_trigger_source = 'wf05'
        AND v_case.state =
            'finalization_failed'
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'not_required',
            'case_id',
            v_case.id,
            'case_state',
            v_case.state
        );
    END IF;

    IF p_trigger_source = 'wf98' THEN
        IF p_external_operation_id IS NOT NULL THEN
            IF NOT v_current_operation_found
                OR v_current_operation.id
                    IS DISTINCT FROM
                    p_external_operation_id
            THEN
                RETURN jsonb_build_object(
                    'preparation_outcome',
                    'invalid_internal_invocation',
                    'error_code',
                    'retry_operation_not_earliest_incomplete',
                    'case_id',
                    v_case.id,
                    'external_operation_id',
                    p_external_operation_id,
                    'expected_operation_type',
                    v_operation_type
                );
            END IF;

            IF v_case.state NOT IN (
                'finalizing',
                'finalization_failed'
            ) THEN
                RETURN jsonb_build_object(
                    'preparation_outcome',
                    'not_required',
                    'case_id',
                    v_case.id,
                    'case_state',
                    v_case.state
                );
            END IF;

        ELSIF p_recovery_reason =
            'missing_initial_dispatch'
        THEN
            IF v_case.state <> 'provisioned'
                OR v_operation_type <>
                    'create_drive_folder'
                OR v_current_operation_found
            THEN
                RETURN jsonb_build_object(
                    'preparation_outcome',
                    'not_required',
                    'case_id',
                    v_case.id,
                    'case_state',
                    v_case.state
                );
            END IF;

        ELSIF p_recovery_reason =
            'resume_finalization'
        THEN
            IF v_case.state <> 'finalizing'
                OR (
                    v_current_operation_found
                    AND v_current_operation.status <>
                        'pending'
                )
            THEN
                RETURN jsonb_build_object(
                    'preparation_outcome',
                    'not_required',
                    'case_id',
                    v_case.id,
                    'case_state',
                    v_case.state
                );
            END IF;
        END IF;
    END IF;

    v_idempotency_key :=
        'onboarding:' ||
        v_case.id::text ||
        ':' ||
        CASE v_operation_type
            WHEN 'create_drive_folder'
                THEN 'create-drive-folder'
            WHEN 'create_kickoff_event'
                THEN 'create-kickoff-event'
            ELSE 'notify-team'
        END;

    v_lease_owner :=
        'WF06:' ||
        btrim(p_execution_id);

    IF v_current_operation_found THEN
        IF v_current_operation.max_attempts
                IS DISTINCT FROM p_max_attempts
            OR v_current_operation.request_summary IS NULL
            OR jsonb_typeof(
                v_current_operation.request_summary
            ) <> 'object'
            OR v_current_operation.request_summary =
                '{}'::jsonb
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'data_integrity_failure',
                'error_code',
                'existing_operation_contract_mismatch',
                'case_id',
                v_case.id,
                'operation_id',
                v_current_operation.id,
                'operation_type',
                v_operation_type
            );
        END IF;

        IF v_operation_type <> 'notify_team'
            AND (
                v_current_operation.request_summary
                    ->> 'onboarding_case_id'
                    IS DISTINCT FROM v_case.id::text
                OR v_current_operation.request_summary
                    ->> 'operation_key_hash'
                    IS NULL
                OR v_current_operation.request_summary
                    ->> 'operation_key_hash'
                    !~ '^[0-9a-f]{32}$'
            )
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'data_integrity_failure',
                'error_code',
                'existing_operation_identity_mismatch',
                'case_id',
                v_case.id,
                'operation_id',
                v_current_operation.id,
                'operation_type',
                v_operation_type
            );
        END IF;

        IF v_operation_type =
                'create_drive_folder'
            AND (
                NULLIF(
                    btrim(
                        v_current_operation
                            .request_summary
                            ->> 'parent_folder_id'
                    ),
                    ''
                ) IS NULL
                OR NULLIF(
                    btrim(
                        v_current_operation
                            .request_summary
                            ->> 'folder_name'
                    ),
                    ''
                ) IS NULL
                OR jsonb_typeof(
                    v_current_operation
                        .request_summary
                        -> 'use_shared_drive'
                ) IS DISTINCT FROM 'boolean'
                OR v_current_operation
                    .request_summary
                    ->> 'mime_type'
                    IS DISTINCT FROM
                    'application/vnd.google-apps.folder'
            )
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'data_integrity_failure',
                'error_code',
                'existing_drive_request_invalid',
                'case_id',
                v_case.id,
                'operation_id',
                v_current_operation.id
            );
        END IF;

        IF v_operation_type =
                'create_kickoff_event'
            AND (
                NULLIF(
                    btrim(
                        v_current_operation
                            .request_summary
                            ->> 'calendar_id'
                    ),
                    ''
                ) IS NULL
                OR NULLIF(
                    btrim(
                        v_current_operation
                            .request_summary
                            ->> 'event_summary'
                    ),
                    ''
                ) IS NULL
                OR NULLIF(
                    btrim(
                        v_current_operation
                            .request_summary
                            ->> 'start_at'
                    ),
                    ''
                ) IS NULL
                OR NULLIF(
                    btrim(
                        v_current_operation
                            .request_summary
                            ->> 'end_at'
                    ),
                    ''
                ) IS NULL
                OR NULLIF(
                    btrim(
                        v_current_operation
                            .request_summary
                            ->> 'timezone'
                    ),
                    ''
                ) IS NULL
                OR v_current_operation
                    .request_summary
                    ->> 'drive_folder_id'
                    IS DISTINCT FROM
                    v_drive_operation.external_id
                OR v_current_operation
                    .request_summary
                    ->> 'external_client_id'
                    IS DISTINCT FROM
                    v_case.external_client_id
                OR jsonb_typeof(
                    v_current_operation
                        .request_summary
                        -> 'attendees'
                ) IS DISTINCT FROM 'array'
                OR v_current_operation
                    .request_summary
                    ->> 'send_updates'
                    IS DISTINCT FROM 'all'
            )
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'data_integrity_failure',
                'error_code',
                'existing_calendar_request_invalid',
                'case_id',
                v_case.id,
                'operation_id',
                v_current_operation.id
            );
        END IF;

        IF v_operation_type = 'notify_team'
            AND (
                jsonb_typeof(
                    v_current_operation
                        .request_summary
                        -> 'recipients'
                ) IS DISTINCT FROM 'array'
                OR NULLIF(
                    btrim(
                        v_current_operation
                            .request_summary
                            ->> 'template_key'
                    ),
                    ''
                ) IS NULL
                OR NULLIF(
                    btrim(
                        v_current_operation
                            .request_summary
                            ->> 'message_marker'
                    ),
                    ''
                ) IS NULL
                OR v_current_operation
                    .request_summary
                    ->> 'message_marker'
                    IS DISTINCT FROM
                    'b2b-team-notification-' ||
                    substr(
                        encode(
                            digest(
                                convert_to(
                                    v_idempotency_key,
                                    'UTF8'
                                ),
                                'sha256'
                            ),
                            'hex'
                        ),
                        1,
                        24
                    )
                OR v_current_operation
                    .request_summary
                    ->> 'drive_folder_id'
                    IS DISTINCT FROM
                    v_drive_operation.external_id
                OR v_current_operation
                    .request_summary
                    ->> 'calendar_event_id'
                    IS DISTINCT FROM
                    v_calendar_operation.external_id
                OR v_current_operation
                    .request_summary
                    ->> 'external_client_id'
                    IS DISTINCT FROM
                    v_case.external_client_id
            )
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'data_integrity_failure',
                'error_code',
                'existing_notification_request_invalid',
                'case_id',
                v_case.id,
                'operation_id',
                v_current_operation.id
            );
        END IF;

        v_request_summary :=
            v_current_operation.request_summary;
    ELSE
        v_operation_key_hash :=
            substr(
                encode(
                    digest(
                        convert_to(
                            v_idempotency_key,
                            'UTF8'
                        ),
                        'sha256'
                    ),
                    'hex'
                ),
                1,
                32
            );

        IF v_operation_type =
            'create_drive_folder'
        THEN
            v_drive_parent_folder_id :=
                NULLIF(
                    btrim(
                        p_configuration
                            ->> 'drive_parent_folder_id'
                    ),
                    ''
                );

            v_folder_name_template :=
                NULLIF(
                    btrim(
                        p_configuration
                            ->> 'drive_folder_name_template'
                    ),
                    ''
                );

            IF v_drive_parent_folder_id IS NULL
                OR v_folder_name_template IS NULL
                OR position(
                    '{legal_name}' IN
                    v_folder_name_template
                ) = 0
                OR jsonb_typeof(
                    p_configuration
                        -> 'drive_use_shared_drive'
                ) IS DISTINCT FROM 'boolean'
            THEN
                RETURN jsonb_build_object(
                    'preparation_outcome',
                    'invalid_configuration',
                    'error_code',
                    'invalid_drive_configuration',
                    'case_id',
                    v_case.id
                );
            END IF;

            v_drive_use_shared_drive :=
                (
                    p_configuration
                        ->> 'drive_use_shared_drive'
                )::boolean;

            v_folder_name :=
                replace(
                    v_folder_name_template,
                    '{legal_name}',
                    btrim(v_client.legal_name)
                );

            IF btrim(v_folder_name) = '' THEN
                RETURN jsonb_build_object(
                    'preparation_outcome',
                    'invalid_configuration',
                    'error_code',
                    'empty_drive_folder_name',
                    'case_id',
                    v_case.id
                );
            END IF;

            v_request_summary :=
                jsonb_build_object(
                    'parent_folder_id',
                    v_drive_parent_folder_id,
                    'use_shared_drive',
                    v_drive_use_shared_drive,
                    'folder_name',
                    v_folder_name,
                    'mime_type',
                    'application/vnd.google-apps.folder',
                    'onboarding_case_id',
                    v_case.id::text,
                    'operation_key_hash',
                    v_operation_key_hash
                );

        ELSIF v_operation_type =
            'create_kickoff_event'
        THEN
            v_calendar_id :=
                NULLIF(
                    btrim(
                        p_configuration
                            ->> 'calendar_id'
                    ),
                    ''
                );

            v_kickoff_timezone :=
                NULLIF(
                    btrim(
                        p_configuration
                            ->> 'kickoff_timezone'
                    ),
                    ''
                );

            v_internal_attendee_email :=
                NULLIF(
                    lower(
                        btrim(
                            p_configuration
                                ->> 'kickoff_internal_attendee_email'
                        )
                    ),
                    ''
                );

            IF v_calendar_id IS NULL
                OR v_kickoff_timezone IS NULL
                OR NOT EXISTS (
                    SELECT 1
                    FROM pg_timezone_names
                    WHERE name =
                          v_kickoff_timezone
                )
                OR NULLIF(
                    p_configuration
                        ->> 'kickoff_delay_days',
                    ''
                ) IS NULL
                OR (
                    p_configuration
                        ->> 'kickoff_delay_days'
                ) !~ '^[0-9]+$'
                OR NULLIF(
                    p_configuration
                        ->> 'kickoff_duration_minutes',
                    ''
                ) IS NULL
                OR (
                    p_configuration
                        ->> 'kickoff_duration_minutes'
                ) !~ '^[1-9][0-9]*$'
                OR NULLIF(
                    p_configuration
                        ->> 'kickoff_start_local_time',
                    ''
                ) IS NULL
                OR (
                    p_configuration
                        ->> 'kickoff_start_local_time'
                ) !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
                OR v_internal_attendee_email IS NULL
                OR v_internal_attendee_email
                    !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
            THEN
                RETURN jsonb_build_object(
                    'preparation_outcome',
                    'invalid_configuration',
                    'error_code',
                    'invalid_calendar_configuration',
                    'case_id',
                    v_case.id
                );
            END IF;

            v_kickoff_delay_days :=
                (
                    p_configuration
                        ->> 'kickoff_delay_days'
                )::integer;

            v_kickoff_duration_minutes :=
                (
                    p_configuration
                        ->> 'kickoff_duration_minutes'
                )::integer;

            v_kickoff_start_local_time :=
                (
                    p_configuration
                        ->> 'kickoff_start_local_time'
                )::time;

            v_kickoff_local_date :=
                (
                    v_provision_operation.completed_at
                    AT TIME ZONE
                    v_kickoff_timezone
                )::date
                + v_kickoff_delay_days;

            v_kickoff_start_at :=
                make_timestamptz(
                    extract(
                        year FROM v_kickoff_local_date
                    )::integer,
                    extract(
                        month FROM v_kickoff_local_date
                    )::integer,
                    extract(
                        day FROM v_kickoff_local_date
                    )::integer,
                    extract(
                        hour FROM
                        v_kickoff_start_local_time
                    )::integer,
                    extract(
                        minute FROM
                        v_kickoff_start_local_time
                    )::integer,
                    0,
                    v_kickoff_timezone
                );

            v_kickoff_end_at :=
                v_kickoff_start_at
                + make_interval(
                    mins =>
                        v_kickoff_duration_minutes
                );

            v_drive_folder_id :=
                btrim(v_drive_operation.external_id);

            v_drive_folder_link :=
                NULLIF(
                    btrim(
                        v_drive_operation
                            .response_summary
                            ->> 'web_view_link'
                    ),
                    ''
                );

            IF v_drive_folder_link IS NULL THEN
                v_drive_folder_link :=
                    'https://drive.google.com/drive/folders/'
                    || v_drive_folder_id;
            END IF;

            v_request_summary :=
                jsonb_build_object(
                    'calendar_id',
                    v_calendar_id,
                    'event_summary',
                    'B2B Kickoff — ' ||
                        btrim(v_client.legal_name),
                    'start_at',
                    v_kickoff_start_at,
                    'end_at',
                    v_kickoff_end_at,
                    'timezone',
                    v_kickoff_timezone,
                    'attendees',
                    jsonb_build_array(
                        lower(
                            btrim(
                                v_client
                                    .primary_contact_email
                            )
                        ),
                        v_internal_attendee_email
                    ),
                    'drive_folder_id',
                    v_drive_folder_id,
                    'drive_folder_link',
                    v_drive_folder_link,
                    'external_client_id',
                    v_case.external_client_id,
                    'onboarding_case_id',
                    v_case.id::text,
                    'operation_key_hash',
                    v_operation_key_hash,
                    'send_updates',
                    'all'
                );

        ELSE
            v_team_recipients :=
                p_configuration
                    -> 'team_notification_recipients';

            v_team_sender_name :=
                NULLIF(
                    btrim(
                        p_configuration
                            ->> 'team_notification_sender_name'
                    ),
                    ''
                );

            v_team_template_key :=
                NULLIF(
                    btrim(
                        p_configuration
                            ->> 'team_notification_template_key'
                    ),
                    ''
                );

            IF jsonb_typeof(v_team_recipients)
                IS DISTINCT FROM 'array'
            THEN
                RETURN jsonb_build_object(
                    'preparation_outcome',
                    'invalid_configuration',
                    'error_code',
                    'invalid_team_notification_configuration',
                    'case_id',
                    v_case.id
                );
            END IF;

            IF jsonb_array_length(
                    v_team_recipients
                ) = 0
                OR EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(
                        v_team_recipients
                    ) AS recipient(value)
                    WHERE jsonb_typeof(recipient.value)
                              IS DISTINCT FROM 'string'
                       OR btrim(
                              recipient.value #>> '{}'
                          ) = ''
                       OR lower(
                              btrim(
                                  recipient.value #>> '{}'
                              )
                          )
                          !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
                )
                OR v_team_sender_name IS NULL
                OR v_team_template_key IS NULL
            THEN
                RETURN jsonb_build_object(
                    'preparation_outcome',
                    'invalid_configuration',
                    'error_code',
                    'invalid_team_notification_configuration',
                    'case_id',
                    v_case.id
                );
            END IF;

            v_message_marker :=
                'b2b-team-notification-' ||
                substr(
                    encode(
                        digest(
                            convert_to(
                                v_idempotency_key,
                                'UTF8'
                            ),
                            'sha256'
                        ),
                        'hex'
                    ),
                    1,
                    24
                );

            v_drive_folder_id :=
                btrim(v_drive_operation.external_id);

            v_drive_folder_link :=
                COALESCE(
                    NULLIF(
                        btrim(
                            v_drive_operation
                                .response_summary
                                ->> 'web_view_link'
                        ),
                        ''
                    ),
                    'https://drive.google.com/drive/folders/'
                    || v_drive_folder_id
                );

            v_calendar_event_id :=
                btrim(
                    v_calendar_operation.external_id
                );

            v_calendar_event_link :=
                NULLIF(
                    btrim(
                        v_calendar_operation
                            .response_summary
                            ->> 'html_link'
                    ),
                    ''
                );

            v_request_summary :=
                jsonb_strip_nulls(
                    jsonb_build_object(
                        'recipients',
                        v_team_recipients,
                        'sender_name',
                        v_team_sender_name,
                        'template_key',
                        v_team_template_key,
                        'legal_name',
                        btrim(v_client.legal_name),
                        'external_client_id',
                        v_case.external_client_id,
                        'onboarding_case_id',
                        v_case.id::text,
                        'operation_key_hash',
                        v_operation_key_hash,
                        'drive_folder_id',
                        v_drive_folder_id,
                        'drive_folder_link',
                        v_drive_folder_link,
                        'calendar_event_id',
                        v_calendar_event_id,
                        'calendar_event_link',
                        v_calendar_event_link,
                        'kickoff_start_at',
                        v_calendar_operation
                            .request_summary
                            -> 'start_at',
                        'kickoff_timezone',
                        v_calendar_operation
                            .request_summary
                            ->> 'timezone',
                        'message_marker',
                        v_message_marker
                    )
                );
        END IF;
    END IF;

    SELECT *
    INTO v_claim
    FROM claim_external_operation(
        v_idempotency_key,
        v_operation_type,
        v_case.id,
        v_lease_owner,
        p_lease_seconds,
        p_max_attempts,
        v_request_summary
    );

    IF v_claim.claim_outcome <> 'claimed' THEN
        RETURN jsonb_strip_nulls(
            jsonb_build_object(
                'preparation_outcome',
                CASE
                    WHEN v_claim.claim_outcome =
                        'reuse_succeeded'
                        THEN 'data_integrity_failure'
                    ELSE v_claim.claim_outcome
                END,
                'error_code',
                CASE
                    WHEN v_claim.claim_outcome =
                        'reuse_succeeded'
                        THEN 'earliest_operation_reused_unexpectedly'
                    ELSE NULL
                END,
                'operation_claim_outcome',
                v_claim.claim_outcome,
                'case_id',
                v_case.id,
                'correlation_id',
                v_case.correlation_id,
                'operation_id',
                v_claim.operation_id,
                'operation_type',
                v_operation_type,
                'case_state',
                v_case.state,
                'operation_status',
                v_claim.operation_status,
                'operation_attempt_count',
                v_claim.current_attempt_count,
                'operation_max_attempts',
                v_claim.configured_max_attempts,
                'lease_expires_at',
                v_claim.current_lease_expires_at,
                'requires_intervention',
                v_claim.claim_outcome IN (
                    'refused_terminal',
                    'refused_exhausted'
                )
            )
        );
    END IF;

    IF v_case.state IN (
        'provisioned',
        'finalization_failed'
    ) THEN
        v_previous_state := v_case.state;

        UPDATE onboarding_cases
        SET state = 'finalizing'
        WHERE id = v_case.id
          AND state = v_previous_state;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'WF06 case transition to finalizing failed';
        END IF;

        SELECT
            count(*)::integer + 1
        INTO v_cycle_number
        FROM onboarding_events
        WHERE case_id = v_case.id
          AND event_type =
              'onboarding_finalization_started';

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
            v_case.id,
            'onboarding:' ||
                v_case.id::text ||
                ':finalization:started:' ||
                v_cycle_number::text,
            'onboarding_finalization_started',
            'workflow',
            'WF06',
            v_previous_state,
            'finalizing',
            jsonb_build_object(
                'cycle_number',
                v_cycle_number,
                'operation_id',
                v_claim.operation_id,
                'operation_type',
                v_operation_type
            ),
            v_case.correlation_id
        )
        ON CONFLICT (event_key)
        DO NOTHING;
    END IF;

    UPDATE onboarding_steps
    SET
        status = 'in_progress',
        attempt_count =
            v_claim.current_attempt_count,
        started_at = COALESCE(
            started_at,
            clock_timestamp()
        ),
        completed_at = NULL,
        last_error_summary = NULL
    WHERE id = v_current_step.id
      AND status IN (
          'pending',
          'in_progress',
          'failed_retryable'
      );

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'WF06 operation step claim update failed';
    END IF;

    RETURN jsonb_build_object(
        'preparation_outcome',
        'claimed',
        'operation_claim_outcome',
        v_claim.claim_outcome,
        'case_id',
        v_case.id,
        'correlation_id',
        v_case.correlation_id,
        'client_id',
        v_case.client_id,
        'accepted_submission_id',
        v_case.accepted_submission_id,
        'external_client_id',
        v_case.external_client_id,
        'case_state',
        'finalizing',
        'operation_id',
        v_claim.operation_id,
        'operation_type',
        v_operation_type,
        'operation_status',
        'in_progress',
        'operation_attempt_count',
        v_claim.current_attempt_count,
        'operation_max_attempts',
        v_claim.configured_max_attempts,
        'lease_owner',
        v_lease_owner,
        'lease_expires_at',
        v_claim.current_lease_expires_at,
        'request_summary',
        v_request_summary
    );
END;
$$;

CREATE OR REPLACE FUNCTION complete_wf06_onboarding(
    p_case_id uuid,
    p_correlation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_case onboarding_cases%ROWTYPE;
    v_drive_step onboarding_steps%ROWTYPE;
    v_calendar_step onboarding_steps%ROWTYPE;
    v_notification_step onboarding_steps%ROWTYPE;
    v_drive_operation external_operations%ROWTYPE;
    v_calendar_operation external_operations%ROWTYPE;
    v_notification_operation external_operations%ROWTYPE;
    v_drive_found boolean := false;
    v_calendar_found boolean := false;
    v_notification_found boolean := false;
    v_completion_event_exists boolean := false;
    v_now timestamptz := clock_timestamp();
BEGIN
    IF p_case_id IS NULL
        OR p_correlation_id IS NULL
    THEN
        RETURN jsonb_build_object(
            'completion_outcome',
            'invalid_completion_input'
        );
    END IF;

    SELECT onboarding_case.*
    INTO v_case
    FROM onboarding_cases AS onboarding_case
    WHERE onboarding_case.id = p_case_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'completion_outcome',
            'case_not_found',
            'case_id',
            p_case_id
        );
    END IF;

    IF v_case.correlation_id
        IS DISTINCT FROM p_correlation_id
    THEN
        RETURN jsonb_build_object(
            'completion_outcome',
            'invalid_completion_input',
            'error_code',
            'correlation_id_mismatch',
            'case_id',
            v_case.id,
            'correlation_id',
            v_case.correlation_id
        );
    END IF;

    SELECT step.*
    INTO v_drive_step
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case.id
      AND step.step_type = 'create_drive_folder'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'completion_outcome',
            'data_integrity_failure',
            'error_code',
            'drive_step_missing',
            'case_id',
            v_case.id
        );
    END IF;

    SELECT step.*
    INTO v_calendar_step
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case.id
      AND step.step_type = 'create_kickoff_event'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'completion_outcome',
            'data_integrity_failure',
            'error_code',
            'calendar_step_missing',
            'case_id',
            v_case.id
        );
    END IF;

    SELECT step.*
    INTO v_notification_step
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case.id
      AND step.step_type = 'notify_team'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'completion_outcome',
            'data_integrity_failure',
            'error_code',
            'notification_step_missing',
            'case_id',
            v_case.id
        );
    END IF;

    SELECT operation.*
    INTO v_drive_operation
    FROM external_operations AS operation
    WHERE operation.idempotency_key =
          'onboarding:' ||
          v_case.id::text ||
          ':create-drive-folder'
    FOR UPDATE;

    v_drive_found := FOUND;

    SELECT operation.*
    INTO v_calendar_operation
    FROM external_operations AS operation
    WHERE operation.idempotency_key =
          'onboarding:' ||
          v_case.id::text ||
          ':create-kickoff-event'
    FOR UPDATE;

    v_calendar_found := FOUND;

    SELECT operation.*
    INTO v_notification_operation
    FROM external_operations AS operation
    WHERE operation.idempotency_key =
          'onboarding:' ||
          v_case.id::text ||
          ':notify-team'
    FOR UPDATE;

    v_notification_found := FOUND;

    IF NOT v_drive_found
        OR NOT v_calendar_found
        OR NOT v_notification_found
    THEN
        RETURN jsonb_build_object(
            'completion_outcome',
            'not_ready',
            'error_code',
            'finalization_operation_missing',
            'case_id',
            v_case.id,
            'case_state',
            v_case.state
        );
    END IF;

    IF v_drive_operation.case_id
            IS DISTINCT FROM v_case.id
        OR v_drive_operation.operation_type
            IS DISTINCT FROM 'create_drive_folder'
        OR v_calendar_operation.case_id
            IS DISTINCT FROM v_case.id
        OR v_calendar_operation.operation_type
            IS DISTINCT FROM 'create_kickoff_event'
        OR v_notification_operation.case_id
            IS DISTINCT FROM v_case.id
        OR v_notification_operation.operation_type
            IS DISTINCT FROM 'notify_team'
    THEN
        RETURN jsonb_build_object(
            'completion_outcome',
            'data_integrity_failure',
            'error_code',
            'finalization_operation_identity_mismatch',
            'case_id',
            v_case.id
        );
    END IF;

    IF v_case.state = 'completed' THEN
        IF v_case.completed_at IS NOT NULL
            AND v_drive_step.status = 'completed'
            AND v_drive_step.completed_at IS NOT NULL
            AND v_calendar_step.status = 'completed'
            AND v_calendar_step.completed_at IS NOT NULL
            AND v_notification_step.status = 'completed'
            AND v_notification_step.completed_at IS NOT NULL
            AND v_drive_operation.status = 'succeeded'
            AND v_drive_operation.completed_at IS NOT NULL
            AND v_drive_operation.external_id IS NOT NULL
            AND btrim(
                    v_drive_operation.external_id
                ) <> ''
            AND v_calendar_operation.status =
                'succeeded'
            AND v_calendar_operation.completed_at
                IS NOT NULL
            AND v_calendar_operation.external_id
                IS NOT NULL
            AND btrim(
                    v_calendar_operation.external_id
                ) <> ''
            AND v_notification_operation.status =
                'succeeded'
            AND v_notification_operation.completed_at
                IS NOT NULL
            AND v_notification_operation.external_id
                IS NOT NULL
            AND btrim(
                    v_notification_operation.external_id
                ) <> ''
        THEN
            RETURN jsonb_build_object(
                'completion_outcome',
                'already_completed',
                'case_id',
                v_case.id,
                'correlation_id',
                v_case.correlation_id,
                'client_id',
                v_case.client_id,
                'accepted_submission_id',
                v_case.accepted_submission_id,
                'external_client_id',
                v_case.external_client_id,
                'drive_folder_id',
                v_drive_operation.external_id,
                'kickoff_event_id',
                v_calendar_operation.external_id,
                'team_message_id',
                v_notification_operation.external_id,
                'case_state',
                v_case.state,
                'completed_at',
                v_case.completed_at
            );
        END IF;

        RETURN jsonb_build_object(
            'completion_outcome',
            'data_integrity_failure',
            'error_code',
            'inconsistent_completed_state',
            'case_id',
            v_case.id
        );
    END IF;

    IF v_case.state <> 'finalizing' THEN
        RETURN jsonb_build_object(
            'completion_outcome',
            'not_ready',
            'error_code',
            'case_not_finalizing',
            'case_id',
            v_case.id,
            'case_state',
            v_case.state
        );
    END IF;

    IF v_drive_step.status <> 'completed'
        OR v_drive_step.completed_at IS NULL
        OR v_calendar_step.status <> 'completed'
        OR v_calendar_step.completed_at IS NULL
        OR v_notification_step.status <> 'completed'
        OR v_notification_step.completed_at IS NULL
        OR v_drive_operation.status <> 'succeeded'
        OR v_drive_operation.completed_at IS NULL
        OR v_drive_operation.external_id IS NULL
        OR btrim(v_drive_operation.external_id) = ''
        OR v_calendar_operation.status <> 'succeeded'
        OR v_calendar_operation.completed_at IS NULL
        OR v_calendar_operation.external_id IS NULL
        OR btrim(v_calendar_operation.external_id) = ''
        OR v_notification_operation.status <> 'succeeded'
        OR v_notification_operation.completed_at IS NULL
        OR v_notification_operation.external_id IS NULL
        OR btrim(
                v_notification_operation.external_id
            ) = ''
    THEN
        RETURN jsonb_build_object(
            'completion_outcome',
            'not_ready',
            'error_code',
            'finalization_prerequisites_not_met',
            'case_id',
            v_case.id,
            'case_state',
            v_case.state
        );
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM onboarding_events
        WHERE event_key =
              'onboarding:' ||
              v_case.id::text ||
              ':completed'
    )
    INTO v_completion_event_exists;

    IF v_completion_event_exists THEN
        RETURN jsonb_build_object(
            'completion_outcome',
            'data_integrity_failure',
            'error_code',
            'completion_event_precedes_completed_state',
            'case_id',
            v_case.id
        );
    END IF;

    UPDATE onboarding_cases
    SET
        state = 'completed',
        completed_at = v_now
    WHERE id = v_case.id
      AND state = 'finalizing';

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'WF06 completion case update failed';
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
        v_case.id,
        'onboarding:' ||
            v_case.id::text ||
            ':completed',
        'onboarding_completed',
        'workflow',
        'WF06',
        'finalizing',
        'completed',
        jsonb_build_object(
            'drive_folder_id',
            v_drive_operation.external_id,
            'kickoff_event_id',
            v_calendar_operation.external_id,
            'team_message_id',
            v_notification_operation.external_id
        ),
        v_case.correlation_id
    );

    RETURN jsonb_build_object(
        'completion_outcome',
        'completed',
        'case_id',
        v_case.id,
        'correlation_id',
        v_case.correlation_id,
        'client_id',
        v_case.client_id,
        'accepted_submission_id',
        v_case.accepted_submission_id,
        'external_client_id',
        v_case.external_client_id,
        'drive_folder_id',
        v_drive_operation.external_id,
        'kickoff_event_id',
        v_calendar_operation.external_id,
        'team_message_id',
        v_notification_operation.external_id,
        'case_state',
        'completed',
        'completed_at',
        v_now
    );
END;
$$;

CREATE OR REPLACE FUNCTION finalize_wf06_operation_failure(
    p_case_id uuid,
    p_operation_id uuid,
    p_lease_owner text,
    p_retryable boolean,
    p_provider text,
    p_error_class text,
    p_error_code text,
    p_error_message text,
    p_http_status integer,
    p_provider_retry_after_seconds integer
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_case onboarding_cases%ROWTYPE;
    v_step onboarding_steps%ROWTYPE;
    v_operation external_operations%ROWTYPE;
    v_platform_delay_seconds integer;
    v_provider_delay_seconds integer := 0;
    v_retry_delay_seconds integer;
    v_next_retry_at timestamptz;
    v_should_retry boolean;
    v_final_status text;
    v_error_summary jsonb;
    v_event_key text;
    v_event_type text;
    v_now timestamptz := clock_timestamp();
BEGIN
    IF p_case_id IS NULL
        OR p_operation_id IS NULL
        OR p_lease_owner IS NULL
        OR btrim(p_lease_owner) = ''
        OR p_retryable IS NULL
        OR p_provider IS NULL
        OR btrim(p_provider) = ''
        OR p_error_class IS NULL
        OR btrim(p_error_class) = ''
        OR p_error_message IS NULL
        OR btrim(p_error_message) = ''
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'invalid_failure_input'
        );
    END IF;

    IF p_provider_retry_after_seconds IS NOT NULL
        AND p_provider_retry_after_seconds < 0
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'invalid_failure_input',
            'error_code',
            'invalid_retry_after'
        );
    END IF;

    IF p_http_status IS NOT NULL
        AND (
            p_http_status < 100
            OR p_http_status > 599
        )
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'invalid_failure_input',
            'error_code',
            'invalid_http_status'
        );
    END IF;

    SELECT onboarding_case.*
    INTO v_case
    FROM onboarding_cases AS onboarding_case
    WHERE onboarding_case.id = p_case_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'case_not_found',
            'case_id',
            p_case_id
        );
    END IF;

    SELECT operation.*
    INTO v_operation
    FROM external_operations AS operation
    WHERE operation.id = p_operation_id
    FOR UPDATE;

    IF NOT FOUND
        OR v_operation.case_id
            IS DISTINCT FROM v_case.id
        OR v_operation.operation_type
            NOT IN (
                'create_drive_folder',
                'create_kickoff_event',
                'notify_team'
            )
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'operation_context_invalid',
            'case_id',
            v_case.id,
            'operation_id',
            p_operation_id
        );
    END IF;

    IF lower(btrim(p_provider))
            IS DISTINCT FROM
            (
            CASE v_operation.operation_type
                WHEN 'create_drive_folder'
                    THEN 'google_drive'
                WHEN 'create_kickoff_event'
                    THEN 'google_calendar'
                ELSE 'gmail'
            END
            )
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'invalid_failure_input',
            'error_code',
            'provider_operation_mismatch',
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id
        );
    END IF;

    SELECT step.*
    INTO v_step
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case.id
      AND step.step_type =
          v_operation.operation_type
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'operation_step_not_found',
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id,
            'operation_type',
            v_operation.operation_type
        );
    END IF;

    IF v_operation.status IN (
        'failed_retryable',
        'failed_terminal'
    ) THEN
        IF v_case.state =
                'finalization_failed'
            AND v_step.status =
                v_operation.status
        THEN
            RETURN jsonb_strip_nulls(
                jsonb_build_object(
                    'finalization_outcome',
                    'already_finalized',
                    'case_id',
                    v_case.id,
                    'correlation_id',
                    v_case.correlation_id,
                    'operation_id',
                    v_operation.id,
                    'operation_type',
                    v_operation.operation_type,
                    'case_state',
                    v_case.state,
                    'operation_status',
                    v_operation.status,
                    'step_status',
                    v_step.status,
                    'next_retry_at',
                    v_operation.next_retry_at,
                    'requires_intervention',
                    v_operation.status =
                        'failed_terminal'
                )
            );
        END IF;

        RETURN jsonb_build_object(
            'finalization_outcome',
            'inconsistent_existing_failure',
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id
        );
    END IF;

    IF v_case.state <> 'finalizing'
        OR v_operation.status <> 'in_progress'
        OR v_operation.lease_owner
            IS DISTINCT FROM p_lease_owner
        OR v_operation.lease_expires_at <= v_now
        OR v_step.status <> 'in_progress'
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'lease_or_state_not_owned',
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id,
            'operation_type',
            v_operation.operation_type,
            'case_state',
            v_case.state,
            'operation_status',
            v_operation.status,
            'step_status',
            v_step.status
        );
    END IF;

    v_should_retry :=
        p_retryable
        AND v_operation.attempt_count <
            v_operation.max_attempts;

    IF v_should_retry THEN
        v_platform_delay_seconds :=
            CASE v_operation.attempt_count
                WHEN 1 THEN 60
                WHEN 2 THEN 300
                WHEN 3 THEN 900
                ELSE 3600
            END;

        v_provider_delay_seconds :=
            LEAST(
                COALESCE(
                    p_provider_retry_after_seconds,
                    0
                ),
                86400
            );

        v_retry_delay_seconds :=
            GREATEST(
                v_platform_delay_seconds,
                v_provider_delay_seconds
            );

        v_next_retry_at :=
            v_now
            + make_interval(
                secs => v_retry_delay_seconds
            );
    ELSE
        v_next_retry_at := NULL;
    END IF;

    v_error_summary :=
        jsonb_strip_nulls(
            jsonb_build_object(
                'provider',
                btrim(p_provider),
                'operation_type',
                v_operation.operation_type,
                'error_class',
                btrim(p_error_class),
                'error_code',
                NULLIF(
                    btrim(
                        COALESCE(
                            p_error_code,
                            ''
                        )
                    ),
                    ''
                ),
                'error_message',
                left(
                    btrim(p_error_message),
                    1000
                ),
                'http_status',
                p_http_status,
                'retryable_requested',
                p_retryable,
                'attempt_count',
                v_operation.attempt_count,
                'max_attempts',
                v_operation.max_attempts,
                'retry_delay_seconds',
                v_retry_delay_seconds,
                'next_retry_at',
                v_next_retry_at
            )
        );

    SELECT complete_external_operation_failure(
        v_operation.id,
        p_lease_owner,
        v_should_retry,
        btrim(p_error_class),
        v_error_summary,
        v_next_retry_at
    )
    INTO v_final_status;

    IF v_final_status =
        'lease_not_owned'
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'lease_not_owned',
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id
        );
    END IF;

    IF v_final_status NOT IN (
        'failed_retryable',
        'failed_terminal'
    ) THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'operation_finalization_failed',
            'operation_result',
            v_final_status,
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id
        );
    END IF;

    UPDATE onboarding_cases
    SET state = 'finalization_failed'
    WHERE id = v_case.id
      AND state = 'finalizing';

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'WF06 failure case update failed';
    END IF;

    UPDATE onboarding_steps
    SET
        status = v_final_status,
        completed_at = CASE
            WHEN v_final_status =
                'failed_terminal'
                THEN v_now
            ELSE NULL
        END,
        last_error_summary =
            v_error_summary
    WHERE id = v_step.id
      AND status = 'in_progress';

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'WF06 failure step update failed';
    END IF;

    IF v_final_status =
        'failed_retryable'
    THEN
        v_event_key :=
            v_operation.idempotency_key ||
            ':attempt:' ||
            v_operation.attempt_count::text ||
            ':failed-retryable';

        v_event_type :=
            'finalization_operation_failed_retryable';
    ELSE
        v_event_key :=
            v_operation.idempotency_key ||
            ':failed-terminal';

        v_event_type :=
            'finalization_operation_failed_terminal';
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
        v_case.id,
        v_event_key,
        v_event_type,
        'workflow',
        'WF06',
        'finalizing',
        'finalization_failed',
        jsonb_strip_nulls(
            jsonb_build_object(
                'operation_id',
                v_operation.id,
                'operation_type',
                v_operation.operation_type,
                'provider',
                btrim(p_provider),
                'error_class',
                btrim(p_error_class),
                'error_code',
                NULLIF(
                    btrim(
                        COALESCE(
                            p_error_code,
                            ''
                        )
                    ),
                    ''
                ),
                'attempt_count',
                v_operation.attempt_count,
                'next_retry_at',
                v_next_retry_at
            )
        ),
        v_case.correlation_id
    )
    ON CONFLICT (event_key)
    DO NOTHING;

    RETURN jsonb_strip_nulls(
        jsonb_build_object(
            'finalization_outcome',
            'finalized',
            'case_id',
            v_case.id,
            'correlation_id',
            v_case.correlation_id,
            'client_id',
            v_case.client_id,
            'accepted_submission_id',
            v_case.accepted_submission_id,
            'external_client_id',
            v_case.external_client_id,
            'operation_id',
            v_operation.id,
            'operation_type',
            v_operation.operation_type,
            'case_state',
            'finalization_failed',
            'operation_status',
            v_final_status,
            'step_status',
            v_final_status,
            'next_retry_at',
            v_next_retry_at,
            'requires_intervention',
            v_final_status =
                'failed_terminal'
        )
    );
END;
$$;

CREATE OR REPLACE FUNCTION finalize_wf06_operation_success(
    p_case_id uuid,
    p_operation_id uuid,
    p_lease_owner text,
    p_external_id text,
    p_provider text,
    p_reconciled boolean,
    p_response_summary jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_case onboarding_cases%ROWTYPE;
    v_step onboarding_steps%ROWTYPE;
    v_operation external_operations%ROWTYPE;
    v_operation_completed boolean;
    v_step_type text;
    v_event_type text;
    v_event_key text;
    v_sanitized_response jsonb;
    v_now timestamptz := clock_timestamp();
BEGIN
    IF p_case_id IS NULL
        OR p_operation_id IS NULL
        OR p_lease_owner IS NULL
        OR btrim(p_lease_owner) = ''
        OR p_external_id IS NULL
        OR btrim(p_external_id) = ''
        OR p_provider IS NULL
        OR btrim(p_provider) = ''
        OR p_reconciled IS NULL
        OR p_response_summary IS NULL
        OR jsonb_typeof(p_response_summary) <> 'object'
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'invalid_success_input'
        );
    END IF;

    SELECT onboarding_case.*
    INTO v_case
    FROM onboarding_cases AS onboarding_case
    WHERE onboarding_case.id = p_case_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'case_not_found',
            'case_id',
            p_case_id
        );
    END IF;

    SELECT operation.*
    INTO v_operation
    FROM external_operations AS operation
    WHERE operation.id = p_operation_id
    FOR UPDATE;

    IF NOT FOUND
        OR v_operation.case_id
            IS DISTINCT FROM v_case.id
        OR v_operation.operation_type
            NOT IN (
                'create_drive_folder',
                'create_kickoff_event',
                'notify_team'
            )
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'operation_context_invalid',
            'case_id',
            v_case.id,
            'operation_id',
            p_operation_id
        );
    END IF;

    IF lower(btrim(p_provider))
            IS DISTINCT FROM
            (
            CASE v_operation.operation_type
                WHEN 'create_drive_folder'
                    THEN 'google_drive'
                WHEN 'create_kickoff_event'
                    THEN 'google_calendar'
                ELSE 'gmail'
            END
            )
        OR p_response_summary
            -> 'marker_verified'
            IS DISTINCT FROM 'true'::jsonb
        OR (
            p_response_summary ? 'created'
            AND jsonb_typeof(
                p_response_summary
                    -> 'created'
            ) IS DISTINCT FROM 'boolean'
        )
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'invalid_provider_success_response',
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id,
            'operation_type',
            v_operation.operation_type
        );
    END IF;

    v_step_type :=
        v_operation.operation_type;

    SELECT step.*
    INTO v_step
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case.id
      AND step.step_type = v_step_type
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'operation_step_not_found',
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id,
            'operation_type',
            v_operation.operation_type
        );
    END IF;

    IF v_operation.status = 'succeeded' THEN
        IF v_operation.external_id
                IS NOT DISTINCT FROM
                btrim(p_external_id)
            AND v_step.status = 'completed'
            AND v_step.completed_at IS NOT NULL
            AND v_case.state IN (
                'finalizing',
                'completed'
            )
        THEN
            RETURN jsonb_build_object(
                'finalization_outcome',
                'already_finalized',
                'case_id',
                v_case.id,
                'correlation_id',
                v_case.correlation_id,
                'operation_id',
                v_operation.id,
                'operation_type',
                v_operation.operation_type,
                'external_id',
                v_operation.external_id,
                'operation_status',
                v_operation.status,
                'step_status',
                v_step.status,
                'case_state',
                v_case.state
            );
        END IF;

        RETURN jsonb_build_object(
            'finalization_outcome',
            'inconsistent_existing_success',
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id
        );
    END IF;

    IF v_case.state <> 'finalizing'
        OR v_operation.status <> 'in_progress'
        OR v_operation.lease_owner
            IS DISTINCT FROM p_lease_owner
        OR v_operation.lease_expires_at <= v_now
        OR v_step.status <> 'in_progress'
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'lease_or_state_not_owned',
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id,
            'operation_type',
            v_operation.operation_type,
            'case_state',
            v_case.state,
            'operation_status',
            v_operation.status,
            'step_status',
            v_step.status
        );
    END IF;

    v_sanitized_response :=
        jsonb_strip_nulls(
            jsonb_build_object(
                'provider',
                lower(btrim(p_provider)),
                'external_id',
                btrim(p_external_id),
                'reconciled',
                p_reconciled,
                'marker_verified',
                true,
                'created',
                p_response_summary -> 'created',
                'completed_at',
                v_now
            )
            ||
            CASE v_operation.operation_type
                WHEN 'create_drive_folder' THEN
                    jsonb_build_object(
                        'web_view_link',
                        NULLIF(
                            btrim(
                                p_response_summary
                                    ->> 'web_view_link'
                            ),
                            ''
                        )
                    )
                WHEN 'create_kickoff_event' THEN
                    jsonb_build_object(
                        'html_link',
                        NULLIF(
                            btrim(
                                p_response_summary
                                    ->> 'html_link'
                            ),
                            ''
                        )
                    )
                ELSE
                    jsonb_build_object(
                        'thread_id',
                        NULLIF(
                            btrim(
                                p_response_summary
                                    ->> 'thread_id'
                            ),
                            ''
                        ),
                        'message_marker',
                        v_operation
                            .request_summary
                            ->> 'message_marker'
                    )
            END
        );

    SELECT complete_external_operation_success(
        v_operation.id,
        p_lease_owner,
        btrim(p_external_id),
        v_sanitized_response
    )
    INTO v_operation_completed;

    IF v_operation_completed
        IS DISTINCT FROM true
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'lease_not_owned',
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id
        );
    END IF;

    UPDATE onboarding_steps
    SET
        status = 'completed',
        completed_at = v_now,
        last_error_summary = NULL
    WHERE id = v_step.id
      AND status = 'in_progress';

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'WF06 success step update failed';
    END IF;

    CASE v_operation.operation_type
        WHEN 'create_drive_folder' THEN
            v_event_type :=
                'drive_folder_ready';
            v_event_key :=
                'onboarding:' ||
                v_case.id::text ||
                ':create-drive-folder:succeeded';

        WHEN 'create_kickoff_event' THEN
            v_event_type :=
                'kickoff_event_ready';
            v_event_key :=
                'onboarding:' ||
                v_case.id::text ||
                ':create-kickoff-event:succeeded';

        ELSE
            v_event_type :=
                'team_notification_sent';
            v_event_key :=
                'onboarding:' ||
                v_case.id::text ||
                ':notify-team:succeeded';
    END CASE;

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
        v_case.id,
        v_event_key,
        v_event_type,
        'workflow',
        'WF06',
        'finalizing',
        'finalizing',
        jsonb_build_object(
            'operation_id',
            v_operation.id,
            'operation_type',
            v_operation.operation_type,
            'external_id',
            btrim(p_external_id),
            'provider',
            btrim(p_provider),
            'reconciled',
            p_reconciled
        ),
        v_case.correlation_id
    )
    ON CONFLICT (event_key)
    DO NOTHING;

    RETURN jsonb_build_object(
        'finalization_outcome',
        'finalized',
        'next_action',
        'prepare_next_operation',
        'case_id',
        v_case.id,
        'correlation_id',
        v_case.correlation_id,
        'client_id',
        v_case.client_id,
        'accepted_submission_id',
        v_case.accepted_submission_id,
        'external_client_id',
        v_case.external_client_id,
        'operation_id',
        v_operation.id,
        'operation_type',
        v_operation.operation_type,
        'external_id',
        btrim(p_external_id),
        'operation_status',
        'succeeded',
        'step_status',
        'completed',
        'case_state',
        'finalizing'
    );
END;
$$;

COMMENT ON FUNCTION prepare_wf06_finalization_operation(
    uuid,
    uuid,
    text,
    uuid,
    uuid,
    text,
    uuid,
    text,
    text,
    jsonb,
    integer,
    integer
) IS
'Claims the earliest incomplete WF06 operation from authoritative PostgreSQL state.';

COMMENT ON FUNCTION finalize_wf06_operation_failure(
    uuid,
    uuid,
    text,
    boolean,
    text,
    text,
    text,
    text,
    integer,
    integer
) IS
'Finalizes one failed WF06 external operation and records its retry or terminal state atomically.';

COMMENT ON FUNCTION finalize_wf06_operation_success(
    uuid,
    uuid,
    text,
    text,
    text,
    boolean,
    jsonb
) IS
'Finalizes one validated WF06 external operation success and its matching onboarding step atomically.';

COMMENT ON FUNCTION complete_wf06_onboarding(
    uuid,
    uuid
) IS
'Completes onboarding only after all three ordered WF06 operations have succeeded.';

COMMIT;
