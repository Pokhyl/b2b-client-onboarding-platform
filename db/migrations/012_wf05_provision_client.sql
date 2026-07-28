\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION prepare_wf05_provision_client(
    p_case_id uuid,
    p_correlation_id uuid,
    p_trigger_source text,
    p_client_id uuid,
    p_accepted_submission_id uuid,
    p_external_operation_id uuid,
    p_execution_id text,
    p_scenario text,
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
    v_approval_step onboarding_steps%ROWTYPE;
    v_provision_step onboarding_steps%ROWTYPE;
    v_operation external_operations%ROWTYPE;
    v_claim record;

    v_operation_found boolean := false;
    v_missing_initial_dispatch boolean := false;
    v_idempotency_key text;
    v_lease_owner text;
    v_company_identifier text;
    v_company_name text;
    v_effective_scenario text;
    v_request_summary jsonb;
    v_previous_state text;
    v_now timestamptz := clock_timestamp();
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

    IF p_trigger_source NOT IN (
        'wf04',
        'wf98'
    ) THEN
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

    IF p_trigger_source = 'wf04' THEN
        IF p_client_id IS NULL
            OR p_accepted_submission_id IS NULL
            OR p_external_operation_id IS NOT NULL
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'invalid_internal_invocation',
                'error_code',
                'invalid_wf04_invocation',
                'case_id',
                p_case_id
            );
        END IF;

        IF p_scenario IS NULL
            OR p_scenario NOT IN (
            'success',
            'retryable_once',
            'retryable_always',
            'terminal'
        ) THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'invalid_configuration',
                'error_code',
                'invalid_provisioning_scenario',
                'case_id',
                p_case_id
            );
        END IF;

        v_missing_initial_dispatch := false;
    ELSE
        IF p_client_id IS NOT NULL
            OR p_accepted_submission_id IS NOT NULL
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'invalid_internal_invocation',
                'error_code',
                'invalid_wf98_invocation',
                'case_id',
                p_case_id
            );
        END IF;

        IF p_external_operation_id IS NULL THEN
            IF p_scenario IS NULL
                OR p_scenario NOT IN (
                    'success',
                    'retryable_once',
                    'retryable_always',
                    'terminal'
                )
            THEN
                RETURN jsonb_build_object(
                    'preparation_outcome',
                    'invalid_internal_invocation',
                    'error_code',
                    'invalid_wf98_invocation',
                    'case_id',
                    p_case_id
                );
            END IF;

            v_missing_initial_dispatch := true;
        ELSE
            IF p_scenario IS NOT NULL THEN
                RETURN jsonb_build_object(
                    'preparation_outcome',
                    'invalid_internal_invocation',
                    'error_code',
                    'invalid_wf98_invocation',
                    'case_id',
                    p_case_id
                );
            END IF;

            v_missing_initial_dispatch := false;
        END IF;
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
            p_case_id,
            'correlation_id',
            v_case.correlation_id
        );
    END IF;

    IF p_trigger_source = 'wf04'
        AND (
            v_case.client_id
                IS DISTINCT FROM p_client_id
            OR v_case.accepted_submission_id
                IS DISTINCT FROM p_accepted_submission_id
        )
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'invalid_internal_invocation',
            'error_code',
            'authoritative_reference_mismatch',
            'case_id',
            v_case.id,
            'correlation_id',
            v_case.correlation_id
        );
    END IF;

    IF v_case.state IN (
        'created',
        'awaiting_client_data',
        'data_received',
        'validation_failed',
        'awaiting_approval',
        'rejected'
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

    SELECT step.*
    INTO v_approval_step
    FROM onboarding_steps AS step
    WHERE step.case_id = v_case.id
      AND step.step_type = 'manual_approval'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'manual_approval_step_missing',
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

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'provision_client_step_missing',
            'case_id',
            v_case.id
        );
    END IF;

    IF v_case.client_id IS NULL
        OR v_case.accepted_submission_id IS NULL
        OR v_case.approval_decision <> 'approved'
        OR v_case.approval_decided_at IS NULL
        OR v_approval_step.status <> 'completed'
        OR v_approval_step.approval_decision <> 'approved'
        OR v_approval_step.approval_decided_at IS NULL
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'approval_prerequisite_invalid',
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

    v_idempotency_key :=
        'onboarding:' ||
        v_case.id::text ||
        ':provision-client';

    v_lease_owner :=
        'WF05:' ||
        btrim(p_execution_id);

    v_company_name :=
        btrim(v_client.legal_name);

    v_company_identifier :=
        btrim(v_client.company_identifier_country) ||
        ':' ||
        btrim(v_client.company_identifier_type) ||
        ':' ||
        btrim(
            v_client
                .company_identifier_value_normalized
        );

    SELECT operation.*
    INTO v_operation
    FROM external_operations AS operation
    WHERE operation.idempotency_key =
          v_idempotency_key
    FOR UPDATE;

    v_operation_found := FOUND;

    IF p_trigger_source = 'wf98'
        AND NOT v_missing_initial_dispatch
        AND (
            NOT v_operation_found
            OR v_operation.id
                IS DISTINCT FROM
                p_external_operation_id
            OR v_operation.case_id
                IS DISTINCT FROM
                v_case.id
            OR v_operation.operation_type
                IS DISTINCT FROM
                'provision_client'
        )
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'invalid_internal_invocation',
            'error_code',
            'retry_operation_mismatch',
            'case_id',
            v_case.id,
            'external_operation_id',
            p_external_operation_id
        );
    END IF;

    IF v_case.state IN (
        'provisioned',
        'finalizing',
        'finalization_failed',
        'completed'
    ) THEN
        IF v_operation_found
            AND v_operation.status = 'succeeded'
            AND v_case.external_client_id IS NOT NULL
            AND btrim(v_case.external_client_id) <> ''
            AND v_operation.external_id
                IS NOT DISTINCT FROM
                v_case.external_client_id
            AND v_provision_step.status = 'completed'
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'already_provisioned',
                'operation_claim_outcome',
                'reuse_succeeded',
                'case_id',
                v_case.id,
                'correlation_id',
                v_case.correlation_id,
                'client_id',
                v_case.client_id,
                'accepted_submission_id',
                v_case.accepted_submission_id,
                'operation_id',
                v_operation.id,
                'external_client_id',
                v_case.external_client_id,
                'case_state',
                v_case.state,
                'provision_step_status',
                v_provision_step.status
            );
        END IF;

        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'inconsistent_provisioned_state',
            'case_id',
            v_case.id,
            'case_state',
            v_case.state
        );
    END IF;

    IF v_case.external_client_id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'premature_external_client_id',
            'case_id',
            v_case.id,
            'case_state',
            v_case.state
        );
    END IF;

    IF (
        p_trigger_source = 'wf04'
        OR v_missing_initial_dispatch
    )
        AND v_case.state <> 'approved'
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            CASE
                WHEN v_case.state = 'provisioning'
                    THEN 'busy'
                ELSE 'not_required'
            END,
            'case_id',
            v_case.id,
            'case_state',
            v_case.state
        );
    END IF;

    IF p_trigger_source = 'wf98'
        AND NOT v_missing_initial_dispatch
        AND v_case.state NOT IN (
            'provisioning_failed',
            'provisioning'
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

    IF v_case.state = 'approved'
        AND v_provision_step.status <> 'pending'
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'approved_step_state_mismatch',
            'case_id',
            v_case.id,
            'provision_step_status',
            v_provision_step.status
        );
    END IF;

    IF v_case.state = 'provisioning'
        AND (
            NOT v_operation_found
            OR v_operation.status <> 'in_progress'
            OR v_provision_step.status <> 'in_progress'
        )
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'active_provisioning_state_mismatch',
            'case_id',
            v_case.id
        );
    END IF;

    IF v_case.state = 'provisioning_failed'
        AND (
            NOT v_operation_found
            OR v_operation.status NOT IN (
                'failed_retryable',
                'failed_terminal'
            )
            OR v_provision_step.status NOT IN (
                'failed_retryable',
                'failed_terminal'
            )
        )
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'error_code',
            'failed_provisioning_state_mismatch',
            'case_id',
            v_case.id
        );
    END IF;

    IF v_case.state = 'provisioning_failed'
        AND (
            v_operation.status = 'failed_terminal'
            OR v_provision_step.status = 'failed_terminal'
        )
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'failed_terminal',
            'operation_claim_outcome',
            'refused_terminal',
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id,
            'case_state',
            v_case.state,
            'requires_intervention',
            true
        );
    END IF;

    IF p_trigger_source = 'wf98'
        AND NOT v_missing_initial_dispatch
    THEN
        IF v_operation.request_summary IS NULL
            OR jsonb_typeof(
                v_operation.request_summary
            ) <> 'object'
            OR v_operation.request_summary
                ->> 'endpoint_path'
                IS DISTINCT FROM '/v1/clients'
            OR v_operation.request_summary
                ->> 'case_id'
                IS DISTINCT FROM v_case.id::text
            OR v_operation.request_summary
                ->> 'client_id'
                IS DISTINCT FROM v_case.client_id::text
            OR v_operation.request_summary
                ->> 'accepted_submission_id'
                IS DISTINCT FROM
                v_case.accepted_submission_id::text
            OR v_operation.request_summary
                ->> 'company_name'
                IS DISTINCT FROM v_company_name
            OR v_operation.request_summary
                ->> 'company_identifier'
                IS DISTINCT FROM
                v_company_identifier
            OR v_operation.request_summary
                ->> 'scenario'
                NOT IN (
                    'success',
                    'retryable_once',
                    'retryable_always',
                    'terminal'
                )
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'data_integrity_failure',
                'error_code',
                'immutable_request_summary_mismatch',
                'case_id',
                v_case.id,
                'operation_id',
                v_operation.id
            );
        END IF;

        v_request_summary :=
            v_operation.request_summary;

        v_effective_scenario :=
            v_operation.request_summary
                ->> 'scenario';
    ELSE
        v_effective_scenario :=
            p_scenario;

        v_request_summary :=
            jsonb_build_object(
                'endpoint_path',
                '/v1/clients',
                'case_id',
                v_case.id::text,
                'client_id',
                v_case.client_id::text,
                'accepted_submission_id',
                v_case.accepted_submission_id::text,
                'company_name',
                v_company_name,
                'company_identifier',
                v_company_identifier,
                'scenario',
                v_effective_scenario
            );

        IF v_operation_found
            AND (
                v_operation.operation_type
                    IS DISTINCT FROM
                    'provision_client'
                OR v_operation.case_id
                    IS DISTINCT FROM
                    v_case.id
                OR v_operation.max_attempts
                    IS DISTINCT FROM
                    p_max_attempts
                OR v_operation.request_summary
                    IS DISTINCT FROM
                    v_request_summary
            )
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'data_integrity_failure',
                'error_code',
                'existing_operation_contract_mismatch',
                'case_id',
                v_case.id,
                'operation_id',
                v_operation.id
            );
        END IF;
    END IF;

    SELECT claim_result.*
    INTO STRICT v_claim
    FROM claim_external_operation(
        v_idempotency_key,
        'provision_client',
        v_case.id,
        v_lease_owner,
        p_lease_seconds,
        p_max_attempts,
        v_request_summary
    ) AS claim_result;

    IF p_trigger_source = 'wf98'
        AND NOT v_missing_initial_dispatch
        AND v_claim.operation_id
            IS DISTINCT FROM
            p_external_operation_id
    THEN
        RAISE EXCEPTION
            'Claimed WF05 operation does not match the retry operation';
    END IF;

    IF v_claim.claim_outcome = 'claimed' THEN
        v_previous_state :=
            v_case.state;

        IF v_case.state IN (
            'approved',
            'provisioning_failed'
        ) THEN
            UPDATE onboarding_cases
            SET state = 'provisioning'
            WHERE id = v_case.id
              AND state = v_previous_state;

            IF NOT FOUND THEN
                RAISE EXCEPTION
                    'WF05 case state changed during preparation';
            END IF;
        ELSIF v_case.state <> 'provisioning' THEN
            RAISE EXCEPTION
                'WF05 claimed an operation for an invalid case state';
        END IF;

        UPDATE onboarding_steps
        SET
            status = 'in_progress',
            attempt_count =
                v_claim.current_attempt_count,
            started_at = COALESCE(
                started_at,
                v_now
            ),
            completed_at = NULL,
            last_error_summary = NULL
        WHERE id = v_provision_step.id;

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
            v_idempotency_key || ':started',
            'client_provisioning_started',
            'workflow',
            'WF05',
            v_previous_state,
            'provisioning',
            jsonb_build_object(
                'operation_id',
                v_claim.operation_id,
                'client_id',
                v_case.client_id,
                'attempt_count',
                v_claim.current_attempt_count,
                'provider',
                'mock-provisioning-api'
            ),
            v_case.correlation_id
        )
        ON CONFLICT (event_key)
        DO NOTHING;

        RETURN jsonb_build_object(
            'preparation_outcome',
            'ready_to_call',
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
            'provision_step_id',
            v_provision_step.id,
            'operation_id',
            v_claim.operation_id,
            'operation_status',
            v_claim.operation_status,
            'operation_attempt_count',
            v_claim.current_attempt_count,
            'operation_max_attempts',
            v_claim.configured_max_attempts,
            'operation_lease_expires_at',
            v_claim.current_lease_expires_at,
            'lease_owner',
            v_lease_owner,
            'case_state',
            'provisioning',
            'provision_step_status',
            'in_progress',
            'idempotency_key',
            v_idempotency_key,
            'endpoint_path',
            '/v1/clients',
            'company_name',
            v_request_summary ->> 'company_name',
            'company_identifier',
            v_request_summary
                ->> 'company_identifier',
            'scenario',
            v_request_summary ->> 'scenario',
            'request_summary',
            v_request_summary
        );
    END IF;

    IF v_claim.claim_outcome =
        'reuse_succeeded'
    THEN
        SELECT operation.*
        INTO STRICT v_operation
        FROM external_operations AS operation
        WHERE operation.id =
              v_claim.operation_id
        FOR UPDATE;

        SELECT step.*
        INTO STRICT v_provision_step
        FROM onboarding_steps AS step
        WHERE step.id =
              v_provision_step.id
        FOR UPDATE;

        SELECT onboarding_case.*
        INTO STRICT v_case
        FROM onboarding_cases AS onboarding_case
        WHERE onboarding_case.id =
              v_case.id
        FOR UPDATE;

        IF v_case.state IN (
                'provisioned',
                'finalizing',
                'finalization_failed',
                'completed'
            )
            AND v_case.external_client_id
                IS NOT NULL
            AND v_operation.external_id
                IS NOT DISTINCT FROM
                v_case.external_client_id
            AND v_provision_step.status =
                'completed'
        THEN
            RETURN jsonb_build_object(
                'preparation_outcome',
                'already_provisioned',
                'operation_claim_outcome',
                'reuse_succeeded',
                'case_id',
                v_case.id,
                'correlation_id',
                v_case.correlation_id,
                'client_id',
                v_case.client_id,
                'accepted_submission_id',
                v_case.accepted_submission_id,
                'operation_id',
                v_operation.id,
                'external_client_id',
                v_case.external_client_id,
                'case_state',
                v_case.state
            );
        END IF;

        RETURN jsonb_build_object(
            'preparation_outcome',
            'data_integrity_failure',
            'operation_claim_outcome',
            'reuse_succeeded',
            'error_code',
            'inconsistent_existing_success',
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id
        );
    END IF;

    IF v_claim.claim_outcome IN (
        'busy',
        'not_due'
    ) THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            v_claim.claim_outcome,
            'operation_claim_outcome',
            v_claim.claim_outcome,
            'case_id',
            v_case.id,
            'correlation_id',
            v_case.correlation_id,
            'operation_id',
            v_claim.operation_id,
            'operation_status',
            v_claim.operation_status,
            'operation_attempt_count',
            v_claim.current_attempt_count,
            'operation_max_attempts',
            v_claim.configured_max_attempts,
            'operation_lease_expires_at',
            v_claim.current_lease_expires_at,
            'case_state',
            v_case.state
        );
    END IF;

    IF v_claim.claim_outcome =
        'refused_terminal'
    THEN
        RETURN jsonb_build_object(
            'preparation_outcome',
            'failed_terminal',
            'operation_claim_outcome',
            'refused_terminal',
            'case_id',
            v_case.id,
            'operation_id',
            v_claim.operation_id,
            'case_state',
            v_case.state,
            'requires_intervention',
            true
        );
    END IF;

    IF v_claim.claim_outcome =
        'refused_exhausted'
    THEN
        UPDATE external_operations
        SET
            status = 'failed_terminal',
            lease_owner = NULL,
            lease_expires_at = NULL,
            next_retry_at = NULL,
            last_error_class =
                'max_attempts_exhausted',
            last_error_summary =
                jsonb_build_object(
                    'error_code',
                    'wf05_max_attempts_exhausted',
                    'attempt_count',
                    v_claim.current_attempt_count,
                    'max_attempts',
                    v_claim.configured_max_attempts
                ),
            completed_at = v_now
        WHERE id = v_claim.operation_id
          AND status IN (
              'in_progress',
              'failed_retryable'
          );

        IF v_case.state = 'provisioning' THEN
            UPDATE onboarding_cases
            SET state = 'provisioning_failed'
            WHERE id = v_case.id
              AND state = 'provisioning';
        END IF;

        UPDATE onboarding_steps
        SET
            status = 'failed_terminal',
            completed_at = v_now,
            last_error_summary =
                jsonb_build_object(
                    'error_code',
                    'wf05_max_attempts_exhausted',
                    'operation_id',
                    v_claim.operation_id,
                    'attempt_count',
                    v_claim.current_attempt_count
                )
        WHERE id = v_provision_step.id;

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
            v_idempotency_key ||
                ':failed-terminal',
            'client_provisioning_failed_terminal',
            'workflow',
            'WF05',
            v_case.state,
            'provisioning_failed',
            jsonb_build_object(
                'operation_id',
                v_claim.operation_id,
                'error_code',
                'wf05_max_attempts_exhausted',
                'attempt_count',
                v_claim.current_attempt_count
            ),
            v_case.correlation_id
        )
        ON CONFLICT (event_key)
        DO NOTHING;

        RETURN jsonb_build_object(
            'preparation_outcome',
            'failed_terminal',
            'operation_claim_outcome',
            'refused_exhausted',
            'case_id',
            v_case.id,
            'operation_id',
            v_claim.operation_id,
            'case_state',
            'provisioning_failed',
            'provision_step_status',
            'failed_terminal',
            'requires_intervention',
            true
        );
    END IF;

    RETURN jsonb_build_object(
        'preparation_outcome',
        'data_integrity_failure',
        'error_code',
        'unknown_claim_outcome',
        'operation_claim_outcome',
        v_claim.claim_outcome,
        'case_id',
        v_case.id,
        'operation_id',
        v_claim.operation_id
    );
END;
$$;


CREATE OR REPLACE FUNCTION finalize_wf05_provision_success(
    p_case_id uuid,
    p_operation_id uuid,
    p_lease_owner text,
    p_http_status integer,
    p_external_client_id text,
    p_response_case_id uuid,
    p_response_company_name text,
    p_response_company_identifier text,
    p_provider_status text,
    p_provider_attempt_number integer,
    p_replayed boolean
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_case onboarding_cases%ROWTYPE;
    v_step onboarding_steps%ROWTYPE;
    v_operation external_operations%ROWTYPE;
    v_request_summary jsonb;
    v_response_summary jsonb;
    v_operation_completed boolean;
    v_now timestamptz := clock_timestamp();
BEGIN
    IF p_case_id IS NULL
        OR p_operation_id IS NULL
        OR p_lease_owner IS NULL
        OR btrim(p_lease_owner) = ''
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'invalid_success_input'
        );
    END IF;

    IF p_http_status NOT IN (
        200,
        201
    )
        OR p_external_client_id IS NULL
        OR btrim(p_external_client_id) = ''
        OR p_response_case_id IS NULL
        OR p_response_company_name IS NULL
        OR btrim(p_response_company_name) = ''
        OR p_response_company_identifier IS NULL
        OR btrim(p_response_company_identifier) = ''
        OR p_provider_status <> 'provisioned'
        OR p_provider_attempt_number IS NULL
        OR p_provider_attempt_number <= 0
        OR p_replayed IS NULL
        OR (
            p_http_status = 200
            AND p_replayed IS DISTINCT FROM true
        )
        OR (
            p_http_status = 201
            AND p_replayed IS DISTINCT FROM false
        )
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'invalid_provider_success_response',
            'case_id',
            p_case_id,
            'operation_id',
            p_operation_id
        );
    END IF;

    SELECT operation.*
    INTO v_operation
    FROM external_operations AS operation
    WHERE operation.id = p_operation_id
    FOR UPDATE;

    IF NOT FOUND
        OR v_operation.case_id
            IS DISTINCT FROM p_case_id
        OR v_operation.operation_type
            IS DISTINCT FROM
            'provision_client'
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'operation_context_invalid',
            'case_id',
            p_case_id,
            'operation_id',
            p_operation_id
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

    SELECT step.*
    INTO v_step
    FROM onboarding_steps AS step
    WHERE step.case_id = p_case_id
      AND step.step_type = 'provision_client'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'provision_step_not_found',
            'case_id',
            p_case_id
        );
    END IF;

    IF v_operation.status = 'succeeded' THEN
        IF v_case.state IN (
                'provisioned',
                'finalizing',
                'finalization_failed',
                'completed'
            )
            AND v_case.external_client_id
                IS NOT DISTINCT FROM
                v_operation.external_id
            AND v_operation.external_id
                IS NOT DISTINCT FROM
                p_external_client_id
            AND v_step.status = 'completed'
        THEN
            RETURN jsonb_build_object(
                'finalization_outcome',
                'already_finalized',
                'case_id',
                v_case.id,
                'correlation_id',
                v_case.correlation_id,
                'client_id',
                v_case.client_id,
                'accepted_submission_id',
                v_case.accepted_submission_id,
                'operation_id',
                v_operation.id,
                'external_client_id',
                v_case.external_client_id,
                'case_state',
                v_case.state,
                'operation_status',
                v_operation.status,
                'provision_step_status',
                v_step.status
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

    IF v_operation.status <> 'in_progress'
        OR v_operation.lease_owner
            IS DISTINCT FROM p_lease_owner
        OR v_operation.lease_expires_at <=
            v_now
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

    IF v_case.state <> 'provisioning'
        OR v_step.status <> 'in_progress'
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'authoritative_state_invalid',
            'case_id',
            v_case.id,
            'case_state',
            v_case.state,
            'provision_step_status',
            v_step.status
        );
    END IF;

    v_request_summary :=
        v_operation.request_summary;

    IF p_response_case_id
            IS DISTINCT FROM v_case.id
        OR p_response_company_name
            IS DISTINCT FROM
            v_request_summary
                ->> 'company_name'
        OR p_response_company_identifier
            IS DISTINCT FROM
            v_request_summary
                ->> 'company_identifier'
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'provider_response_mismatch',
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id
        );
    END IF;

    v_response_summary :=
        jsonb_build_object(
            'provider',
            'mock-provisioning-api',
            'http_status',
            p_http_status,
            'external_client_id',
            btrim(p_external_client_id),
            'provider_status',
            p_provider_status,
            'provider_attempt_number',
            p_provider_attempt_number,
            'replayed',
            p_replayed,
            'completed_at',
            v_now
        );

    SELECT complete_external_operation_success(
        v_operation.id,
        p_lease_owner,
        btrim(p_external_client_id),
        v_response_summary
    )
    INTO v_operation_completed;

    IF v_operation_completed IS DISTINCT FROM true THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'lease_not_owned',
            'case_id',
            v_case.id,
            'operation_id',
            v_operation.id
        );
    END IF;

    UPDATE onboarding_cases
    SET
        external_client_id =
            btrim(p_external_client_id),
        state = 'provisioned'
    WHERE id = v_case.id
      AND state = 'provisioning'
      AND (
          external_client_id IS NULL
          OR external_client_id =
             btrim(p_external_client_id)
      );

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'WF05 success case update failed';
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
            'WF05 success step update failed';
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
        v_operation.idempotency_key ||
            ':succeeded',
        'client_provisioning_succeeded',
        'workflow',
        'WF05',
        'provisioning',
        'provisioned',
        jsonb_build_object(
            'operation_id',
            v_operation.id,
            'external_client_id',
            btrim(p_external_client_id),
            'provider',
            'mock-provisioning-api',
            'provider_attempt_number',
            p_provider_attempt_number,
            'replayed',
            p_replayed
        ),
        v_case.correlation_id
    )
    ON CONFLICT (event_key)
    DO NOTHING;

    RETURN jsonb_build_object(
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
        'operation_id',
        v_operation.id,
        'external_client_id',
        btrim(p_external_client_id),
        'case_state',
        'provisioned',
        'operation_status',
        'succeeded',
        'provision_step_status',
        'completed'
    );
END;
$$;


CREATE OR REPLACE FUNCTION finalize_wf05_provision_failure(
    p_case_id uuid,
    p_operation_id uuid,
    p_lease_owner text,
    p_retryable boolean,
    p_error_class text,
    p_error_code text,
    p_error_message text,
    p_http_status integer,
    p_provider_attempt_number integer,
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

    IF p_provider_attempt_number IS NOT NULL
        AND p_provider_attempt_number <= 0
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'invalid_failure_input',
            'error_code',
            'invalid_provider_attempt_number'
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

    SELECT operation.*
    INTO v_operation
    FROM external_operations AS operation
    WHERE operation.id = p_operation_id
    FOR UPDATE;

    IF NOT FOUND
        OR v_operation.case_id
            IS DISTINCT FROM p_case_id
        OR v_operation.operation_type
            IS DISTINCT FROM
            'provision_client'
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'operation_context_invalid',
            'case_id',
            p_case_id,
            'operation_id',
            p_operation_id
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

    SELECT step.*
    INTO v_step
    FROM onboarding_steps AS step
    WHERE step.case_id = p_case_id
      AND step.step_type = 'provision_client'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'provision_step_not_found',
            'case_id',
            p_case_id
        );
    END IF;

    IF v_operation.status IN (
        'failed_retryable',
        'failed_terminal'
    ) THEN
        IF v_case.state = 'provisioning_failed'
            AND (
                (
                    v_operation.status =
                        'failed_retryable'
                    AND v_step.status =
                        'failed_retryable'
                )
                OR (
                    v_operation.status =
                        'failed_terminal'
                    AND v_step.status =
                        'failed_terminal'
                )
            )
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
                    'case_state',
                    v_case.state,
                    'operation_status',
                    v_operation.status,
                    'provision_step_status',
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

    IF v_operation.status <> 'in_progress'
        OR v_operation.lease_owner
            IS DISTINCT FROM p_lease_owner
        OR v_operation.lease_expires_at <=
            v_now
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

    IF v_case.state <> 'provisioning'
        OR v_step.status <> 'in_progress'
    THEN
        RETURN jsonb_build_object(
            'finalization_outcome',
            'authoritative_state_invalid',
            'case_id',
            v_case.id,
            'case_state',
            v_case.state,
            'provision_step_status',
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
            v_now +
            make_interval(
                secs => v_retry_delay_seconds
            );
    ELSE
        v_next_retry_at := NULL;
    END IF;

    v_error_summary :=
        jsonb_strip_nulls(
            jsonb_build_object(
                'provider',
                'mock-provisioning-api',
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
                btrim(p_error_message),
                'http_status',
                p_http_status,
                'provider_attempt_number',
                p_provider_attempt_number,
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
    SET state = 'provisioning_failed'
    WHERE id = v_case.id
      AND state = 'provisioning';

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'WF05 failure case update failed';
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
            'WF05 failure step update failed';
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
            'client_provisioning_failed_retryable';
    ELSE
        v_event_key :=
            v_operation.idempotency_key ||
            ':failed-terminal';

        v_event_type :=
            'client_provisioning_failed_terminal';
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
        'WF05',
        'provisioning',
        'provisioning_failed',
        jsonb_strip_nulls(
            jsonb_build_object(
                'operation_id',
                v_operation.id,
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
            'operation_id',
            v_operation.id,
            'case_state',
            'provisioning_failed',
            'operation_status',
            v_final_status,
            'provision_step_status',
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

COMMENT ON FUNCTION prepare_wf05_provision_client(
    uuid,
    uuid,
    text,
    uuid,
    uuid,
    uuid,
    text,
    text,
    integer,
    integer
) IS
'Atomically validates and claims the deterministic WF05 provision_client operation.';

COMMENT ON FUNCTION finalize_wf05_provision_success(
    uuid,
    uuid,
    text,
    integer,
    text,
    uuid,
    text,
    text,
    text,
    integer,
    boolean
) IS
'Atomically persists a validated WF05 provisioning success.';

COMMENT ON FUNCTION finalize_wf05_provision_failure(
    uuid,
    uuid,
    text,
    boolean,
    text,
    text,
    text,
    integer,
    integer,
    integer
) IS
'Atomically persists a retryable or terminal WF05 provisioning failure.';

COMMIT;
