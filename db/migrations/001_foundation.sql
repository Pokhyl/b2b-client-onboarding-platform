BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE clients (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    company_identifier_country text NOT NULL,
    company_identifier_type text NOT NULL,
    company_identifier_value text NOT NULL,
    company_identifier_value_normalized text NOT NULL,

    legal_name text NOT NULL,

    primary_contact_first_name text NOT NULL,
    primary_contact_last_name text NOT NULL,
    primary_contact_email text NOT NULL,
    primary_contact_phone text NOT NULL,

    source_submission_id uuid NOT NULL,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT clients_country_format_check
        CHECK (company_identifier_country ~ '^[A-Z]{2}$'),

    CONSTRAINT clients_identifier_type_not_blank_check
        CHECK (btrim(company_identifier_type) <> ''),

    CONSTRAINT clients_identifier_value_not_blank_check
        CHECK (btrim(company_identifier_value) <> ''),

    CONSTRAINT clients_identifier_normalized_not_blank_check
        CHECK (btrim(company_identifier_value_normalized) <> ''),

    CONSTRAINT clients_legal_name_not_blank_check
        CHECK (btrim(legal_name) <> ''),

    CONSTRAINT clients_contact_first_name_not_blank_check
        CHECK (btrim(primary_contact_first_name) <> ''),

    CONSTRAINT clients_contact_last_name_not_blank_check
        CHECK (btrim(primary_contact_last_name) <> ''),

    CONSTRAINT clients_contact_email_not_blank_check
        CHECK (btrim(primary_contact_email) <> ''),

    CONSTRAINT clients_contact_phone_not_blank_check
        CHECK (btrim(primary_contact_phone) <> ''),

    CONSTRAINT clients_identity_unique
        UNIQUE (
            company_identifier_country,
            company_identifier_type,
            company_identifier_value_normalized
        ),

    CONSTRAINT clients_source_submission_unique
        UNIQUE (source_submission_id)
);
CREATE TABLE onboarding_cases (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    source_system text NOT NULL,
    source_event_id text NOT NULL,
    source_deal_id text NOT NULL,
    correlation_id uuid NOT NULL DEFAULT gen_random_uuid(),

    state text NOT NULL DEFAULT 'created',

    intake_company_name text NOT NULL,
    intake_contact_first_name text,
    intake_contact_last_name text,
    intake_contact_email text NOT NULL,
    intake_contact_phone text,
    intake_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,

    client_id uuid,
    accepted_submission_id uuid,

    approval_decision text,
    approval_decided_at timestamptz,

    external_client_id text,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    rejected_at timestamptz,

    CONSTRAINT onboarding_cases_source_system_format_check
        CHECK (source_system ~ '^[a-z0-9][a-z0-9_-]*$'),

    CONSTRAINT onboarding_cases_source_event_not_blank_check
        CHECK (btrim(source_event_id) <> ''),

    CONSTRAINT onboarding_cases_source_deal_not_blank_check
        CHECK (btrim(source_deal_id) <> ''),

    CONSTRAINT onboarding_cases_company_name_not_blank_check
        CHECK (btrim(intake_company_name) <> ''),

    CONSTRAINT onboarding_cases_email_not_blank_check
        CHECK (btrim(intake_contact_email) <> ''),

    CONSTRAINT onboarding_cases_metadata_object_check
        CHECK (jsonb_typeof(intake_metadata) = 'object'),

    CONSTRAINT onboarding_cases_state_check
        CHECK (
            state IN (
                'created',
                'awaiting_client_data',
                'data_received',
                'validation_failed',
                'awaiting_approval',
                'rejected',
                'approved',
                'provisioning',
                'provisioning_failed',
                'provisioned',
                'finalizing',
                'finalization_failed',
                'completed'
            )
        ),

    CONSTRAINT onboarding_cases_approval_decision_check
        CHECK (
            approval_decision IS NULL
            OR approval_decision IN ('approved', 'rejected')
        ),

    CONSTRAINT onboarding_cases_approval_timestamp_check
        CHECK (
            (approval_decision IS NULL AND approval_decided_at IS NULL)
            OR
            (approval_decision IS NOT NULL AND approval_decided_at IS NOT NULL)
        ),

    CONSTRAINT onboarding_cases_client_submission_pair_check
        CHECK (
            (client_id IS NULL) = (accepted_submission_id IS NULL)
        ),

    CONSTRAINT onboarding_cases_pre_validation_links_check
        CHECK (
            state NOT IN (
                'created',
                'awaiting_client_data',
                'data_received',
                'validation_failed'
            )
            OR (
                client_id IS NULL
                AND accepted_submission_id IS NULL
            )
        ),

    CONSTRAINT onboarding_cases_post_validation_links_check
        CHECK (
            state NOT IN (
                'awaiting_approval',
                'rejected',
                'approved',
                'provisioning',
                'provisioning_failed',
                'provisioned',
                'finalizing',
                'finalization_failed',
                'completed'
            )
            OR (
                client_id IS NOT NULL
                AND accepted_submission_id IS NOT NULL
            )
        ),

    CONSTRAINT onboarding_cases_approval_state_check
        CHECK (
            (
                state IN (
                    'created',
                    'awaiting_client_data',
                    'data_received',
                    'validation_failed',
                    'awaiting_approval'
                )
                AND approval_decision IS NULL
            )
            OR (
                state = 'rejected'
                AND approval_decision = 'rejected'
            )
            OR (
                state IN (
                    'approved',
                    'provisioning',
                    'provisioning_failed',
                    'provisioned',
                    'finalizing',
                    'finalization_failed',
                    'completed'
                )
                AND approval_decision = 'approved'
            )
        ),

    CONSTRAINT onboarding_cases_rejected_timestamp_check
        CHECK (
            (state = 'rejected') = (rejected_at IS NOT NULL)
        ),

    CONSTRAINT onboarding_cases_completed_timestamp_check
        CHECK (
            (state = 'completed') = (completed_at IS NOT NULL)
        ),

    CONSTRAINT onboarding_cases_external_client_check
        CHECK (
            state NOT IN (
                'provisioned',
                'finalizing',
                'finalization_failed',
                'completed'
            )
            OR (
                external_client_id IS NOT NULL
                AND btrim(external_client_id) <> ''
            )
        ),

    CONSTRAINT onboarding_cases_source_event_unique
        UNIQUE (source_system, source_event_id),

    CONSTRAINT onboarding_cases_source_deal_unique
        UNIQUE (source_system, source_deal_id),

    CONSTRAINT onboarding_cases_correlation_unique
        UNIQUE (correlation_id),

    CONSTRAINT onboarding_cases_client_fk
        FOREIGN KEY (client_id)
        REFERENCES clients(id)
        ON DELETE RESTRICT
);

CREATE INDEX onboarding_cases_state_updated_idx
    ON onboarding_cases (state, updated_at);

CREATE INDEX onboarding_cases_client_idx
    ON onboarding_cases (client_id)
    WHERE client_id IS NOT NULL;
    CREATE TABLE onboarding_steps (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    case_id uuid NOT NULL,
    step_type text NOT NULL,
    status text NOT NULL DEFAULT 'pending',

    attempt_count integer NOT NULL DEFAULT 0,
    started_at timestamptz,
    completed_at timestamptz,

    last_error_summary jsonb,

    n8n_wait_execution_id text,
    approval_recipient_email text,
    approval_decision text,
    approval_decided_at timestamptz,
    approval_response_metadata jsonb,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT onboarding_steps_case_fk
        FOREIGN KEY (case_id)
        REFERENCES onboarding_cases(id)
        ON DELETE RESTRICT,

    CONSTRAINT onboarding_steps_case_type_unique
        UNIQUE (case_id, step_type),

    CONSTRAINT onboarding_steps_type_check
        CHECK (
            step_type IN (
                'collect_client_data',
                'validate_client_data',
                'manual_approval',
                'provision_client',
                'create_drive_folder',
                'create_kickoff_event',
                'notify_team'
            )
        ),

    CONSTRAINT onboarding_steps_status_check
        CHECK (
            status IN (
                'pending',
                'in_progress',
                'waiting',
                'completed',
                'failed_retryable',
                'failed_terminal',
                'skipped'
            )
        ),

    CONSTRAINT onboarding_steps_attempt_count_check
        CHECK (attempt_count >= 0),

    CONSTRAINT onboarding_steps_error_object_check
        CHECK (
            last_error_summary IS NULL
            OR jsonb_typeof(last_error_summary) = 'object'
        ),

    CONSTRAINT onboarding_steps_response_object_check
        CHECK (
            approval_response_metadata IS NULL
            OR jsonb_typeof(approval_response_metadata) = 'object'
        ),

    CONSTRAINT onboarding_steps_waiting_status_check
        CHECK (
            status <> 'waiting'
            OR (
                step_type = 'manual_approval'
                AND n8n_wait_execution_id IS NOT NULL
                AND btrim(n8n_wait_execution_id) <> ''
                AND approval_recipient_email IS NOT NULL
                AND btrim(approval_recipient_email) <> ''
            )
        ),

    CONSTRAINT onboarding_steps_approval_fields_check
        CHECK (
            step_type = 'manual_approval'
            OR (
                n8n_wait_execution_id IS NULL
                AND approval_recipient_email IS NULL
                AND approval_decision IS NULL
                AND approval_decided_at IS NULL
                AND approval_response_metadata IS NULL
            )
        ),

    CONSTRAINT onboarding_steps_approval_decision_check
        CHECK (
            approval_decision IS NULL
            OR approval_decision IN ('approved', 'rejected')
        ),

    CONSTRAINT onboarding_steps_approval_timestamp_check
        CHECK (
            (approval_decision IS NULL AND approval_decided_at IS NULL)
            OR
            (
                approval_decision IS NOT NULL
                AND approval_decided_at IS NOT NULL
                AND status = 'completed'
            )
        ),

    CONSTRAINT onboarding_steps_manual_completion_check
        CHECK (
            NOT (
                step_type = 'manual_approval'
                AND status = 'completed'
            )
            OR (
                n8n_wait_execution_id IS NOT NULL
                AND approval_recipient_email IS NOT NULL
                AND approval_decision IS NOT NULL
                AND approval_decided_at IS NOT NULL
            )
        ),

    CONSTRAINT onboarding_steps_completed_timestamp_check
        CHECK (
            (
                status IN (
                    'completed',
                    'failed_terminal',
                    'skipped'
                )
            ) = (completed_at IS NOT NULL)
        )
);

CREATE UNIQUE INDEX onboarding_steps_wait_execution_unique
    ON onboarding_steps (n8n_wait_execution_id)
    WHERE n8n_wait_execution_id IS NOT NULL;

CREATE INDEX onboarding_steps_status_updated_idx
    ON onboarding_steps (status, updated_at);
    CREATE TABLE onboarding_form_tokens (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    case_id uuid NOT NULL,
    request_cycle_key text NOT NULL,

    token_hash bytea NOT NULL,

    token_ciphertext bytea,
    token_nonce bytea,
    token_auth_tag bytea,
    encryption_key_id text,

    status text NOT NULL DEFAULT 'issued',

    expires_at timestamptz NOT NULL,
    issued_at timestamptz NOT NULL DEFAULT now(),
    delivered_at timestamptz,
    consumed_at timestamptz,
    revoked_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT onboarding_form_tokens_case_fk
        FOREIGN KEY (case_id)
        REFERENCES onboarding_cases(id)
        ON DELETE RESTRICT,

    CONSTRAINT onboarding_form_tokens_case_id_unique
        UNIQUE (case_id, id),

    CONSTRAINT onboarding_form_tokens_request_cycle_unique
        UNIQUE (case_id, request_cycle_key),

    CONSTRAINT onboarding_form_tokens_hash_unique
        UNIQUE (token_hash),

    CONSTRAINT onboarding_form_tokens_cycle_not_blank_check
        CHECK (btrim(request_cycle_key) <> ''),

    CONSTRAINT onboarding_form_tokens_hash_length_check
        CHECK (octet_length(token_hash) = 32),

    CONSTRAINT onboarding_form_tokens_status_check
        CHECK (
            status IN (
                'issued',
                'delivered',
                'consumed',
                'expired',
                'revoked'
            )
        ),

    CONSTRAINT onboarding_form_tokens_expiry_check
        CHECK (expires_at > issued_at),

    CONSTRAINT onboarding_form_tokens_crypto_group_check
        CHECK (
            (
                token_ciphertext IS NULL
                AND token_nonce IS NULL
                AND token_auth_tag IS NULL
                AND encryption_key_id IS NULL
            )
            OR
            (
                token_ciphertext IS NOT NULL
                AND token_nonce IS NOT NULL
                AND token_auth_tag IS NOT NULL
                AND encryption_key_id IS NOT NULL
                AND btrim(encryption_key_id) <> ''
            )
        ),

    CONSTRAINT onboarding_form_tokens_status_fields_check
        CHECK (
            (
                status = 'issued'
                AND token_ciphertext IS NOT NULL
                AND delivered_at IS NULL
                AND consumed_at IS NULL
                AND revoked_at IS NULL
            )
            OR
            (
                status = 'delivered'
                AND token_ciphertext IS NULL
                AND delivered_at IS NOT NULL
                AND consumed_at IS NULL
                AND revoked_at IS NULL
            )
            OR
            (
                status = 'consumed'
                AND token_ciphertext IS NULL
                AND delivered_at IS NOT NULL
                AND consumed_at IS NOT NULL
                AND consumed_at <= expires_at
                AND revoked_at IS NULL
            )
            OR
            (
                status = 'expired'
                AND token_ciphertext IS NULL
                AND consumed_at IS NULL
                AND revoked_at IS NULL
            )
            OR
            (
                status = 'revoked'
                AND token_ciphertext IS NULL
                AND consumed_at IS NULL
                AND revoked_at IS NOT NULL
            )
        )
);

CREATE UNIQUE INDEX onboarding_form_tokens_one_active_per_case
    ON onboarding_form_tokens (case_id)
    WHERE status IN ('issued', 'delivered');

CREATE INDEX onboarding_form_tokens_active_expiry_idx
    ON onboarding_form_tokens (expires_at)
    WHERE status IN ('issued', 'delivered');
    CREATE TABLE onboarding_submissions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    case_id uuid NOT NULL,
    form_token_id uuid NOT NULL,
    submission_sequence integer NOT NULL,

    submitted_data jsonb NOT NULL,
    normalized_data jsonb NOT NULL,

    validation_status text NOT NULL DEFAULT 'pending',
    validation_errors jsonb NOT NULL DEFAULT '[]'::jsonb,

    submitted_at timestamptz NOT NULL DEFAULT now(),
    validated_at timestamptz,

    CONSTRAINT onboarding_submissions_case_fk
        FOREIGN KEY (case_id)
        REFERENCES onboarding_cases(id)
        ON DELETE RESTRICT,

    CONSTRAINT onboarding_submissions_token_case_fk
        FOREIGN KEY (case_id, form_token_id)
        REFERENCES onboarding_form_tokens(case_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT onboarding_submissions_token_unique
        UNIQUE (form_token_id),

    CONSTRAINT onboarding_submissions_case_sequence_unique
        UNIQUE (case_id, submission_sequence),

    CONSTRAINT onboarding_submissions_case_id_unique
        UNIQUE (case_id, id),

    CONSTRAINT onboarding_submissions_sequence_check
        CHECK (submission_sequence > 0),

    CONSTRAINT onboarding_submissions_submitted_object_check
        CHECK (
            jsonb_typeof(submitted_data) = 'object'
            AND submitted_data <> '{}'::jsonb
        ),

    CONSTRAINT onboarding_submissions_normalized_object_check
        CHECK (
            jsonb_typeof(normalized_data) = 'object'
        ),

    CONSTRAINT onboarding_submissions_errors_array_check
        CHECK (
            jsonb_typeof(validation_errors) = 'array'
        ),

    CONSTRAINT onboarding_submissions_validation_status_check
        CHECK (
            validation_status IN (
                'pending',
                'passed',
                'failed'
            )
        ),

    CONSTRAINT onboarding_submissions_validation_fields_check
        CHECK (
            (
                validation_status = 'pending'
                AND validated_at IS NULL
                AND validation_errors = '[]'::jsonb
            )
            OR
            (
                validation_status = 'passed'
                AND validated_at IS NOT NULL
                AND validation_errors = '[]'::jsonb
            )
            OR
            (
                validation_status = 'failed'
                AND validated_at IS NOT NULL
                AND jsonb_array_length(validation_errors) > 0
            )
        )
);

CREATE INDEX onboarding_submissions_case_submitted_idx
    ON onboarding_submissions (case_id, submitted_at DESC);
    ALTER TABLE clients
    ADD CONSTRAINT clients_source_submission_fk
    FOREIGN KEY (source_submission_id)
    REFERENCES onboarding_submissions(id)
    ON DELETE RESTRICT;

ALTER TABLE onboarding_cases
    ADD CONSTRAINT onboarding_cases_accepted_submission_fk
    FOREIGN KEY (id, accepted_submission_id)
    REFERENCES onboarding_submissions(case_id, id)
    ON DELETE RESTRICT;
    CREATE TABLE onboarding_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    case_id uuid,

    event_key text NOT NULL,
    event_type text NOT NULL,

    actor_type text NOT NULL,
    actor_identifier text,

    previous_state text,
    new_state text,

    event_data jsonb NOT NULL DEFAULT '{}'::jsonb,
    correlation_id uuid NOT NULL,

    occurred_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT onboarding_events_case_fk
        FOREIGN KEY (case_id)
        REFERENCES onboarding_cases(id)
        ON DELETE RESTRICT,

    CONSTRAINT onboarding_events_key_unique
        UNIQUE (event_key),

    CONSTRAINT onboarding_events_key_not_blank_check
        CHECK (btrim(event_key) <> ''),

    CONSTRAINT onboarding_events_type_not_blank_check
        CHECK (btrim(event_type) <> ''),

    CONSTRAINT onboarding_events_actor_not_blank_check
        CHECK (btrim(actor_type) <> ''),

    CONSTRAINT onboarding_events_actor_identifier_check
        CHECK (
            actor_identifier IS NULL
            OR btrim(actor_identifier) <> ''
        ),

    CONSTRAINT onboarding_events_data_object_check
        CHECK (
            jsonb_typeof(event_data) = 'object'
        ),

    CONSTRAINT onboarding_events_previous_state_check
        CHECK (
            previous_state IS NULL
            OR previous_state IN (
                'created',
                'awaiting_client_data',
                'data_received',
                'validation_failed',
                'awaiting_approval',
                'rejected',
                'approved',
                'provisioning',
                'provisioning_failed',
                'provisioned',
                'finalizing',
                'finalization_failed',
                'completed'
            )
        ),

    CONSTRAINT onboarding_events_new_state_check
        CHECK (
            new_state IS NULL
            OR new_state IN (
                'created',
                'awaiting_client_data',
                'data_received',
                'validation_failed',
                'awaiting_approval',
                'rejected',
                'approved',
                'provisioning',
                'provisioning_failed',
                'provisioned',
                'finalizing',
                'finalization_failed',
                'completed'
            )
        )
);

CREATE INDEX onboarding_events_case_occurred_idx
    ON onboarding_events (case_id, occurred_at DESC)
    WHERE case_id IS NOT NULL;

CREATE INDEX onboarding_events_correlation_occurred_idx
    ON onboarding_events (correlation_id, occurred_at DESC);
    CREATE TABLE external_operations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    case_id uuid,

    operation_type text NOT NULL,
    idempotency_key text NOT NULL,
    status text NOT NULL DEFAULT 'pending',

    attempt_count integer NOT NULL DEFAULT 0,
    max_attempts integer NOT NULL DEFAULT 5,
    next_retry_at timestamptz,

    lease_owner text,
    lease_expires_at timestamptz,

    external_id text,

    request_summary jsonb NOT NULL DEFAULT '{}'::jsonb,
    response_summary jsonb NOT NULL DEFAULT '{}'::jsonb,

    last_error_class text,
    last_error_summary jsonb,

    created_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    completed_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT external_operations_case_fk
        FOREIGN KEY (case_id)
        REFERENCES onboarding_cases(id)
        ON DELETE RESTRICT,

    CONSTRAINT external_operations_idempotency_unique
        UNIQUE (idempotency_key),

    CONSTRAINT external_operations_type_check
        CHECK (
            operation_type IN (
                'send_client_data_request',
                'send_approval_request',
                'provision_client',
                'create_drive_folder',
                'create_kickoff_event',
                'notify_team',
                'notify_operator_intervention'
            )
        ),

    CONSTRAINT external_operations_key_not_blank_check
        CHECK (btrim(idempotency_key) <> ''),

    CONSTRAINT external_operations_status_check
        CHECK (
            status IN (
                'pending',
                'in_progress',
                'succeeded',
                'failed_retryable',
                'failed_terminal'
            )
        ),

    CONSTRAINT external_operations_attempts_check
        CHECK (
            attempt_count >= 0
            AND max_attempts > 0
            AND attempt_count <= max_attempts
        ),

    CONSTRAINT external_operations_lease_pair_check
        CHECK (
            (lease_owner IS NULL) = (lease_expires_at IS NULL)
        ),

    CONSTRAINT external_operations_lease_owner_check
        CHECK (
            lease_owner IS NULL
            OR btrim(lease_owner) <> ''
        ),

    CONSTRAINT external_operations_external_id_check
        CHECK (
            external_id IS NULL
            OR btrim(external_id) <> ''
        ),

    CONSTRAINT external_operations_request_object_check
        CHECK (
            jsonb_typeof(request_summary) = 'object'
        ),

    CONSTRAINT external_operations_response_object_check
        CHECK (
            jsonb_typeof(response_summary) = 'object'
        ),

    CONSTRAINT external_operations_error_class_check
        CHECK (
            last_error_class IS NULL
            OR btrim(last_error_class) <> ''
        ),

    CONSTRAINT external_operations_error_object_check
        CHECK (
            last_error_summary IS NULL
            OR jsonb_typeof(last_error_summary) = 'object'
        ),

    CONSTRAINT external_operations_status_fields_check
        CHECK (
            (
                status = 'pending'
                AND attempt_count = 0
                AND lease_owner IS NULL
                AND next_retry_at IS NULL
                AND completed_at IS NULL
            )
            OR
            (
                status = 'in_progress'
                AND attempt_count > 0
                AND lease_owner IS NOT NULL
                AND started_at IS NOT NULL
                AND completed_at IS NULL
            )
            OR
            (
                status = 'succeeded'
                AND attempt_count > 0
                AND lease_owner IS NULL
                AND next_retry_at IS NULL
                AND completed_at IS NOT NULL
            )
            OR
            (
                status = 'failed_retryable'
                AND attempt_count > 0
                AND lease_owner IS NULL
                AND next_retry_at IS NOT NULL
                AND completed_at IS NULL
                AND last_error_class IS NOT NULL
            )
            OR
            (
                status = 'failed_terminal'
                AND attempt_count > 0
                AND lease_owner IS NULL
                AND next_retry_at IS NULL
                AND completed_at IS NOT NULL
                AND last_error_class IS NOT NULL
            )
        )
);

CREATE INDEX external_operations_retry_due_idx
    ON external_operations (next_retry_at)
    WHERE status = 'failed_retryable';

CREATE INDEX external_operations_stale_lease_idx
    ON external_operations (lease_expires_at)
    WHERE status = 'in_progress';

CREATE INDEX external_operations_case_created_idx
    ON external_operations (case_id, created_at DESC)
    WHERE case_id IS NOT NULL;
    CREATE TABLE error_log (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    case_id uuid,
    step_id uuid,
    submission_id uuid,
    external_operation_id uuid,

    workflow_name text NOT NULL,
    workflow_id text,
    execution_id text,

    error_class text NOT NULL,
    error_code text,
    error_message text NOT NULL,

    retryable boolean NOT NULL,
    severity text NOT NULL DEFAULT 'error',

    error_details jsonb NOT NULL DEFAULT '{}'::jsonb,
    correlation_id uuid,

    occurred_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT error_log_case_fk
        FOREIGN KEY (case_id)
        REFERENCES onboarding_cases(id)
        ON DELETE RESTRICT,

    CONSTRAINT error_log_step_fk
        FOREIGN KEY (step_id)
        REFERENCES onboarding_steps(id)
        ON DELETE RESTRICT,

    CONSTRAINT error_log_submission_fk
        FOREIGN KEY (submission_id)
        REFERENCES onboarding_submissions(id)
        ON DELETE RESTRICT,

    CONSTRAINT error_log_external_operation_fk
        FOREIGN KEY (external_operation_id)
        REFERENCES external_operations(id)
        ON DELETE RESTRICT,

    CONSTRAINT error_log_workflow_not_blank_check
        CHECK (btrim(workflow_name) <> ''),

    CONSTRAINT error_log_class_not_blank_check
        CHECK (btrim(error_class) <> ''),

    CONSTRAINT error_log_message_not_blank_check
        CHECK (btrim(error_message) <> ''),

    CONSTRAINT error_log_severity_check
        CHECK (
            severity IN (
                'warning',
                'error',
                'critical'
            )
        ),

    CONSTRAINT error_log_details_object_check
        CHECK (
            jsonb_typeof(error_details) = 'object'
        )
);

CREATE INDEX error_log_case_occurred_idx
    ON error_log (case_id, occurred_at DESC)
    WHERE case_id IS NOT NULL;

CREATE INDEX error_log_correlation_occurred_idx
    ON error_log (correlation_id, occurred_at DESC)
    WHERE correlation_id IS NOT NULL;

CREATE INDEX error_log_execution_idx
    ON error_log (execution_id)
    WHERE execution_id IS NOT NULL;
    CREATE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$$;

CREATE TRIGGER clients_set_updated_at
BEFORE UPDATE ON clients
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER onboarding_cases_set_updated_at
BEFORE UPDATE ON onboarding_cases
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER onboarding_steps_set_updated_at
BEFORE UPDATE ON onboarding_steps
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER onboarding_form_tokens_set_updated_at
BEFORE UPDATE ON onboarding_form_tokens
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER external_operations_set_updated_at
BEFORE UPDATE ON external_operations
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
CREATE FUNCTION initialize_onboarding_steps()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO onboarding_steps (
        case_id,
        step_type
    )
    VALUES
        (NEW.id, 'collect_client_data'),
        (NEW.id, 'validate_client_data'),
        (NEW.id, 'manual_approval'),
        (NEW.id, 'provision_client'),
        (NEW.id, 'create_drive_folder'),
        (NEW.id, 'create_kickoff_event'),
        (NEW.id, 'notify_team');

    RETURN NEW;
END;
$$;

CREATE TRIGGER onboarding_cases_initialize_steps
AFTER INSERT ON onboarding_cases
FOR EACH ROW
EXECUTE FUNCTION initialize_onboarding_steps();
CREATE FUNCTION enforce_onboarding_case_transition()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.state <> 'created' THEN
            RAISE EXCEPTION
                'A new onboarding case must start in state created';
        END IF;

        RETURN NEW;
    END IF;

    IF NEW.state IS NOT DISTINCT FROM OLD.state THEN
        RETURN NEW;
    END IF;

    IF NOT (
        (
            OLD.state = 'created'
            AND NEW.state = 'awaiting_client_data'
        )
        OR (
            OLD.state = 'awaiting_client_data'
            AND NEW.state = 'data_received'
        )
        OR (
            OLD.state = 'data_received'
            AND NEW.state IN (
                'validation_failed',
                'awaiting_approval'
            )
        )
        OR (
            OLD.state = 'validation_failed'
            AND NEW.state = 'awaiting_client_data'
        )
        OR (
            OLD.state = 'awaiting_approval'
            AND NEW.state IN (
                'rejected',
                'approved'
            )
        )
        OR (
            OLD.state = 'approved'
            AND NEW.state = 'provisioning'
        )
        OR (
            OLD.state = 'provisioning'
            AND NEW.state IN (
                'provisioning_failed',
                'provisioned'
            )
        )
        OR (
            OLD.state = 'provisioning_failed'
            AND NEW.state = 'provisioning'
        )
        OR (
            OLD.state = 'provisioned'
            AND NEW.state = 'finalizing'
        )
        OR (
            OLD.state = 'finalizing'
            AND NEW.state IN (
                'finalization_failed',
                'completed'
            )
        )
        OR (
            OLD.state = 'finalization_failed'
            AND NEW.state = 'finalizing'
        )
    ) THEN
        RAISE EXCEPTION
            'Invalid onboarding case transition: % -> %',
            OLD.state,
            NEW.state;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER onboarding_cases_enforce_transition
BEFORE INSERT OR UPDATE OF state ON onboarding_cases
FOR EACH ROW
EXECUTE FUNCTION enforce_onboarding_case_transition();
CREATE FUNCTION enforce_form_token_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'Onboarding form tokens cannot be deleted';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'issued' THEN
            RAISE EXCEPTION
                'A new form token must start in status issued';
        END IF;

        RETURN NEW;
    END IF;

    IF NEW.id IS DISTINCT FROM OLD.id
        OR NEW.case_id IS DISTINCT FROM OLD.case_id
        OR NEW.request_cycle_key IS DISTINCT FROM OLD.request_cycle_key
        OR NEW.token_hash IS DISTINCT FROM OLD.token_hash
        OR NEW.expires_at IS DISTINCT FROM OLD.expires_at
        OR NEW.issued_at IS DISTINCT FROM OLD.issued_at
    THEN
        RAISE EXCEPTION
            'Form token identity and expiry fields are immutable';
    END IF;

    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
        IF NEW.token_ciphertext IS DISTINCT FROM OLD.token_ciphertext
            OR NEW.token_nonce IS DISTINCT FROM OLD.token_nonce
            OR NEW.token_auth_tag IS DISTINCT FROM OLD.token_auth_tag
            OR NEW.encryption_key_id IS DISTINCT FROM OLD.encryption_key_id
            OR NEW.delivered_at IS DISTINCT FROM OLD.delivered_at
            OR NEW.consumed_at IS DISTINCT FROM OLD.consumed_at
            OR NEW.revoked_at IS DISTINCT FROM OLD.revoked_at
        THEN
            RAISE EXCEPTION
                'Form token lifecycle fields require a status transition';
        END IF;

        RETURN NEW;
    END IF;

    IF NOT (
        (
            OLD.status = 'issued'
            AND NEW.status IN (
                'delivered',
                'expired',
                'revoked'
            )
        )
        OR (
            OLD.status = 'delivered'
            AND NEW.status IN (
                'consumed',
                'expired',
                'revoked'
            )
        )
    ) THEN
        RAISE EXCEPTION
            'Invalid form token transition: % -> %',
            OLD.status,
            NEW.status;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER onboarding_form_tokens_enforce_lifecycle
BEFORE INSERT OR UPDATE OR DELETE ON onboarding_form_tokens
FOR EACH ROW
EXECUTE FUNCTION enforce_form_token_lifecycle();
CREATE FUNCTION enforce_submission_immutability()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'Onboarding submissions are immutable and cannot be deleted';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.validation_status <> 'pending' THEN
            RAISE EXCEPTION
                'A new submission must start in validation status pending';
        END IF;

        RETURN NEW;
    END IF;

    IF NEW.id IS DISTINCT FROM OLD.id
        OR NEW.case_id IS DISTINCT FROM OLD.case_id
        OR NEW.form_token_id IS DISTINCT FROM OLD.form_token_id
        OR NEW.submission_sequence IS DISTINCT FROM OLD.submission_sequence
        OR NEW.submitted_data IS DISTINCT FROM OLD.submitted_data
        OR NEW.normalized_data IS DISTINCT FROM OLD.normalized_data
        OR NEW.submitted_at IS DISTINCT FROM OLD.submitted_at
    THEN
        RAISE EXCEPTION
            'Submission identity, data, normalization, and timestamp are immutable';
    END IF;

    IF OLD.validation_status <> 'pending' THEN
        RAISE EXCEPTION
            'A finalized submission cannot be changed';
    END IF;

    IF NEW.validation_status NOT IN (
        'passed',
        'failed'
    ) THEN
        RAISE EXCEPTION
            'A pending submission may transition only to passed or failed';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER onboarding_submissions_enforce_immutability
BEFORE INSERT OR UPDATE OR DELETE ON onboarding_submissions
FOR EACH ROW
EXECUTE FUNCTION enforce_submission_immutability();
CREATE FUNCTION enforce_accepted_case_submission()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    accepted_status text;
BEGIN
    IF NEW.accepted_submission_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE'
        AND NEW.accepted_submission_id
            IS NOT DISTINCT FROM OLD.accepted_submission_id
    THEN
        RETURN NEW;
    END IF;

    SELECT submission.validation_status
    INTO accepted_status
    FROM onboarding_submissions AS submission
    WHERE submission.id = NEW.accepted_submission_id
      AND submission.case_id = NEW.id;

    IF NOT FOUND OR accepted_status <> 'passed' THEN
        RAISE EXCEPTION
            'An accepted submission must belong to the case and have status passed';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER onboarding_cases_enforce_accepted_submission
BEFORE INSERT OR UPDATE OF accepted_submission_id
ON onboarding_cases
FOR EACH ROW
EXECUTE FUNCTION enforce_accepted_case_submission();
CREATE FUNCTION prevent_append_only_changes()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION
        '% is append-only; % is not allowed',
        TG_TABLE_NAME,
        TG_OP;

    RETURN NULL;
END;
$$;

CREATE TRIGGER onboarding_events_append_only
BEFORE UPDATE OR DELETE ON onboarding_events
FOR EACH ROW
EXECUTE FUNCTION prevent_append_only_changes();
CREATE FUNCTION consume_form_token_and_create_submission(
    p_token_hash bytea,
    p_submitted_data jsonb,
    p_normalized_data jsonb
)
RETURNS TABLE (
    consume_outcome text,
    created_submission_id uuid,
    onboarding_case_id uuid,
    created_submission_sequence integer
)
LANGUAGE plpgsql
AS $$
DECLARE
    token_row onboarding_form_tokens%ROWTYPE;
    next_submission_sequence integer;
    new_submission_id uuid;
    updated_case_count integer;
    v_now timestamptz := clock_timestamp();
BEGIN
    IF p_token_hash IS NULL
        OR octet_length(p_token_hash) <> 32
    THEN
        RAISE EXCEPTION
            'token_hash must contain exactly 32 bytes';
    END IF;

    IF p_submitted_data IS NULL
        OR jsonb_typeof(p_submitted_data) <> 'object'
        OR p_submitted_data = '{}'::jsonb
    THEN
        RAISE EXCEPTION
            'submitted_data must be a non-empty JSON object';
    END IF;

    IF p_normalized_data IS NULL
        OR jsonb_typeof(p_normalized_data) <> 'object'
    THEN
        RAISE EXCEPTION
            'normalized_data must be a JSON object';
    END IF;

    SELECT token.*
    INTO token_row
    FROM onboarding_form_tokens AS token
    WHERE token.token_hash = p_token_hash
    FOR UPDATE;

    IF NOT FOUND THEN
        consume_outcome := 'invalid_token';
        RETURN NEXT;
        RETURN;
    END IF;

    onboarding_case_id := token_row.case_id;

    IF token_row.status = 'consumed' THEN
        consume_outcome := 'already_consumed';
        RETURN NEXT;
        RETURN;
    END IF;

    IF token_row.status = 'revoked' THEN
        consume_outcome := 'revoked';
        RETURN NEXT;
        RETURN;
    END IF;

    IF token_row.status = 'expired' THEN
        consume_outcome := 'expired';
        RETURN NEXT;
        RETURN;
    END IF;

    IF token_row.expires_at <= v_now THEN
        UPDATE onboarding_form_tokens
        SET
            status = 'expired',
            token_ciphertext = NULL,
            token_nonce = NULL,
            token_auth_tag = NULL,
            encryption_key_id = NULL
        WHERE id = token_row.id;

        consume_outcome := 'expired';
        RETURN NEXT;
        RETURN;
    END IF;

    IF token_row.status <> 'delivered' THEN
        consume_outcome := 'not_delivered';
        RETURN NEXT;
        RETURN;
    END IF;

    PERFORM 1
    FROM onboarding_cases AS onboarding_case
    WHERE onboarding_case.id = token_row.case_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'The token references a missing onboarding case';
    END IF;

    PERFORM 1
    FROM onboarding_cases AS onboarding_case
    WHERE onboarding_case.id = token_row.case_id
      AND onboarding_case.state = 'awaiting_client_data';

    IF NOT FOUND THEN
        consume_outcome := 'invalid_case_state';
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT
        COALESCE(MAX(submission.submission_sequence), 0) + 1
    INTO next_submission_sequence
    FROM onboarding_submissions AS submission
    WHERE submission.case_id = token_row.case_id;

    UPDATE onboarding_form_tokens
    SET
        status = 'consumed',
        consumed_at = v_now
    WHERE id = token_row.id;

    INSERT INTO onboarding_submissions (
        case_id,
        form_token_id,
        submission_sequence,
        submitted_data,
        normalized_data
    )
    VALUES (
        token_row.case_id,
        token_row.id,
        next_submission_sequence,
        p_submitted_data,
        p_normalized_data
    )
    RETURNING id
    INTO new_submission_id;

    UPDATE onboarding_cases AS onboarding_case
    SET state = 'data_received'
    WHERE onboarding_case.id = token_row.case_id
      AND onboarding_case.state = 'awaiting_client_data';

    GET DIAGNOSTICS updated_case_count = ROW_COUNT;

    IF updated_case_count <> 1 THEN
        RAISE EXCEPTION
            'The onboarding case state changed while consuming the token';
    END IF;

    consume_outcome := 'created';
    created_submission_id := new_submission_id;
    created_submission_sequence := next_submission_sequence;

    RETURN NEXT;
END;
$$;
CREATE FUNCTION enforce_external_operation_transition()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'pending' THEN
            RAISE EXCEPTION
                'A new external operation must start in status pending';
        END IF;

        RETURN NEW;
    END IF;

    IF NEW.id IS DISTINCT FROM OLD.id
        OR NEW.case_id IS DISTINCT FROM OLD.case_id
        OR NEW.operation_type IS DISTINCT FROM OLD.operation_type
        OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
        OR NEW.max_attempts IS DISTINCT FROM OLD.max_attempts
        OR NEW.request_summary IS DISTINCT FROM OLD.request_summary
        OR NEW.created_at IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION
            'External operation identity and request fields are immutable';
    END IF;

    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NEW;
    END IF;

    IF NOT (
        (
            OLD.status = 'pending'
            AND NEW.status = 'in_progress'
        )
        OR (
            OLD.status = 'in_progress'
            AND NEW.status IN (
                'succeeded',
                'failed_retryable',
                'failed_terminal'
            )
        )
        OR (
            OLD.status = 'failed_retryable'
            AND NEW.status IN (
                'in_progress',
                'failed_terminal'
            )
        )
    ) THEN
        RAISE EXCEPTION
            'Invalid external operation transition: % -> %',
            OLD.status,
            NEW.status;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER external_operations_enforce_transition
BEFORE INSERT OR UPDATE ON external_operations
FOR EACH ROW
EXECUTE FUNCTION enforce_external_operation_transition();
CREATE FUNCTION claim_external_operation(
    p_idempotency_key text,
    p_operation_type text,
    p_case_id uuid,
    p_lease_owner text,
    p_lease_seconds integer DEFAULT 300,
    p_max_attempts integer DEFAULT 5,
    p_request_summary jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
    operation_id uuid,
    claim_outcome text,
    operation_status text,
    current_attempt_count integer,
    configured_max_attempts integer,
    current_lease_expires_at timestamptz,
    current_external_id text,
    current_response_summary jsonb
)
LANGUAGE plpgsql
AS $$
DECLARE
    operation_row external_operations%ROWTYPE;
    v_now timestamptz;
BEGIN
    IF p_idempotency_key IS NULL
        OR btrim(p_idempotency_key) = ''
    THEN
        RAISE EXCEPTION
            'idempotency_key must not be blank';
    END IF;

    IF p_lease_owner IS NULL
        OR btrim(p_lease_owner) = ''
    THEN
        RAISE EXCEPTION
            'lease_owner must not be blank';
    END IF;

    IF p_lease_seconds <= 0
        OR p_max_attempts <= 0
    THEN
        RAISE EXCEPTION
            'lease_seconds and max_attempts must be greater than zero';
    END IF;

    IF p_request_summary IS NULL
        OR jsonb_typeof(p_request_summary) <> 'object'
    THEN
        RAISE EXCEPTION
            'request_summary must be a JSON object';
    END IF;

    INSERT INTO external_operations (
        case_id,
        operation_type,
        idempotency_key,
        max_attempts,
        request_summary
    )
    VALUES (
        p_case_id,
        p_operation_type,
        p_idempotency_key,
        p_max_attempts,
        p_request_summary
    )
    ON CONFLICT (idempotency_key) DO NOTHING;

    SELECT operation.*
    INTO operation_row
    FROM external_operations AS operation
    WHERE operation.idempotency_key = p_idempotency_key
    FOR UPDATE;

    v_now := clock_timestamp();

    IF operation_row.operation_type
            IS DISTINCT FROM p_operation_type
        OR operation_row.case_id
            IS DISTINCT FROM p_case_id
    THEN
        RAISE EXCEPTION
            'The idempotency key belongs to a different operation';
    END IF;

    IF operation_row.status = 'succeeded' THEN
        claim_outcome := 'reuse_succeeded';

    ELSIF operation_row.status = 'failed_terminal' THEN
        claim_outcome := 'refused_terminal';

    ELSIF operation_row.attempt_count
            >= operation_row.max_attempts
    THEN
        claim_outcome := 'refused_exhausted';

    ELSIF operation_row.status = 'in_progress'
        AND operation_row.lease_expires_at > v_now
    THEN
        claim_outcome := 'busy';

    ELSIF operation_row.status = 'failed_retryable'
        AND operation_row.next_retry_at > v_now
    THEN
        claim_outcome := 'not_due';

    ELSE
        UPDATE external_operations
        SET
            status = 'in_progress',
            attempt_count =
                external_operations.attempt_count + 1,
            next_retry_at = NULL,
            lease_owner = p_lease_owner,
            lease_expires_at =
                v_now
                + make_interval(secs => p_lease_seconds),
            started_at = COALESCE(
                external_operations.started_at,
                v_now
            ),
            completed_at = NULL
        WHERE id = operation_row.id
        RETURNING *
        INTO operation_row;

        claim_outcome := 'claimed';
    END IF;

    operation_id := operation_row.id;
    operation_status := operation_row.status;
    current_attempt_count := operation_row.attempt_count;
    configured_max_attempts := operation_row.max_attempts;
    current_lease_expires_at :=
        operation_row.lease_expires_at;
    current_external_id := operation_row.external_id;
    current_response_summary :=
        operation_row.response_summary;

    RETURN NEXT;
END;
$$;
CREATE FUNCTION complete_external_operation_success(
    p_operation_id uuid,
    p_lease_owner text,
    p_external_id text DEFAULT NULL,
    p_response_summary jsonb DEFAULT '{}'::jsonb
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    updated_operation_id uuid;
BEGIN
    IF p_lease_owner IS NULL
        OR btrim(p_lease_owner) = ''
    THEN
        RAISE EXCEPTION
            'lease_owner must not be blank';
    END IF;

    IF p_response_summary IS NULL
        OR jsonb_typeof(p_response_summary) <> 'object'
    THEN
        RAISE EXCEPTION
            'response_summary must be a JSON object';
    END IF;

    UPDATE external_operations AS operation
    SET
        status = 'succeeded',
        lease_owner = NULL,
        lease_expires_at = NULL,
        next_retry_at = NULL,
        external_id = p_external_id,
        response_summary = p_response_summary,
        last_error_class = NULL,
        last_error_summary = NULL,
        completed_at = clock_timestamp()
    WHERE operation.id = p_operation_id
      AND operation.status = 'in_progress'
      AND operation.lease_owner = p_lease_owner
      AND operation.lease_expires_at > clock_timestamp()
    RETURNING operation.id
    INTO updated_operation_id;

    RETURN updated_operation_id IS NOT NULL;
END;
$$;
CREATE FUNCTION complete_external_operation_failure(
    p_operation_id uuid,
    p_lease_owner text,
    p_retryable boolean,
    p_error_class text,
    p_error_summary jsonb DEFAULT '{}'::jsonb,
    p_next_retry_at timestamptz DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    operation_row external_operations%ROWTYPE;
    final_status text;
    v_now timestamptz;
BEGIN
    IF p_lease_owner IS NULL
        OR btrim(p_lease_owner) = ''
    THEN
        RAISE EXCEPTION
            'lease_owner must not be blank';
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

    SELECT operation.*
    INTO operation_row
    FROM external_operations AS operation
    WHERE operation.id = p_operation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN 'operation_not_found';
    END IF;

    v_now := clock_timestamp();

    IF operation_row.status <> 'in_progress'
        OR operation_row.lease_owner
            IS DISTINCT FROM p_lease_owner
        OR operation_row.lease_expires_at <= v_now
    THEN
        RETURN 'lease_not_owned';
    END IF;

    IF p_retryable
        AND operation_row.attempt_count
            < operation_row.max_attempts
    THEN
        IF p_next_retry_at IS NULL THEN
            RAISE EXCEPTION
                'next_retry_at is required for a retryable failure';
        END IF;

        final_status := 'failed_retryable';
    ELSE
        final_status := 'failed_terminal';
    END IF;

    UPDATE external_operations AS operation
    SET
        status = final_status,
        lease_owner = NULL,
        lease_expires_at = NULL,
        next_retry_at = CASE
            WHEN final_status = 'failed_retryable'
                THEN p_next_retry_at
            ELSE NULL
        END,
        last_error_class = p_error_class,
        last_error_summary = p_error_summary,
        completed_at = CASE
            WHEN final_status = 'failed_terminal'
                THEN v_now
            ELSE NULL
        END
    WHERE operation.id = p_operation_id;

    RETURN final_status;
END;
$$;
CREATE FUNCTION enforce_validated_client_source()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    source_status text;
BEGIN
    SELECT submission.validation_status
    INTO source_status
    FROM onboarding_submissions AS submission
    WHERE submission.id = NEW.source_submission_id;

    IF NOT FOUND OR source_status <> 'passed' THEN
        RAISE EXCEPTION
            'Canonical client data requires a passed source submission';
    END IF;

    IF TG_OP = 'UPDATE'
        AND (
            NEW.company_identifier_country
                IS DISTINCT FROM OLD.company_identifier_country
            OR NEW.company_identifier_type
                IS DISTINCT FROM OLD.company_identifier_type
            OR NEW.company_identifier_value
                IS DISTINCT FROM OLD.company_identifier_value
            OR NEW.company_identifier_value_normalized
                IS DISTINCT FROM OLD.company_identifier_value_normalized
            OR NEW.legal_name
                IS DISTINCT FROM OLD.legal_name
            OR NEW.primary_contact_first_name
                IS DISTINCT FROM OLD.primary_contact_first_name
            OR NEW.primary_contact_last_name
                IS DISTINCT FROM OLD.primary_contact_last_name
            OR NEW.primary_contact_email
                IS DISTINCT FROM OLD.primary_contact_email
            OR NEW.primary_contact_phone
                IS DISTINCT FROM OLD.primary_contact_phone
        )
        AND NEW.source_submission_id
            IS NOT DISTINCT FROM OLD.source_submission_id
    THEN
        RAISE EXCEPTION
            'Canonical client data changes require a new passed source submission';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER clients_enforce_validated_source
BEFORE INSERT OR UPDATE ON clients
FOR EACH ROW
EXECUTE FUNCTION enforce_validated_client_source();
COMMIT;