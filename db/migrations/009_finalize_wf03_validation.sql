BEGIN;

CREATE OR REPLACE FUNCTION finalize_wf03_validation(
    p_case_id uuid,
    p_submission_id uuid,
    p_validation_status text,
    p_validation_errors jsonb
)
RETURNS TABLE (
    finalization_outcome text,
    final_validation_status text,
    final_case_state text,
    final_collect_step_status text,
    final_validate_step_status text,
    final_client_id uuid
)
LANGUAGE plpgsql
AS $$
DECLARE
    case_row onboarding_cases%ROWTYPE;
    submission_row onboarding_submissions%ROWTYPE;
    token_row onboarding_form_tokens%ROWTYPE;
    collect_step_row onboarding_steps%ROWTYPE;
    validate_step_row onboarding_steps%ROWTYPE;

    existing_client_id uuid;
    existing_client_source_submission_id uuid;
    new_client_id uuid;

    v_now timestamptz := clock_timestamp();

    v_country text;
    v_identifier_type text;
    v_identifier_value text;
    v_identifier_value_normalized text;
    v_legal_name text;
    v_contact_first_name text;
    v_contact_last_name text;
    v_contact_email text;
    v_contact_phone text;
BEGIN
    IF p_case_id IS NULL THEN
        RAISE EXCEPTION 'p_case_id is required';
    END IF;

    IF p_submission_id IS NULL THEN
        RAISE EXCEPTION 'p_submission_id is required';
    END IF;

    IF p_validation_status NOT IN ('passed', 'failed') THEN
        RAISE EXCEPTION
            'p_validation_status must be passed or failed';
    END IF;

    IF p_validation_errors IS NULL
        OR jsonb_typeof(p_validation_errors) <> 'array'
    THEN
        RAISE EXCEPTION
            'p_validation_errors must be a JSON array';
    END IF;

    IF p_validation_status = 'passed'
        AND jsonb_array_length(p_validation_errors) <> 0
    THEN
        RAISE EXCEPTION
            'passed validation requires an empty error array';
    END IF;

    IF p_validation_status = 'failed'
        AND jsonb_array_length(p_validation_errors) = 0
    THEN
        RAISE EXCEPTION
            'failed validation requires at least one error';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_validation_errors)
            AS error_item(value)
        WHERE jsonb_typeof(error_item.value) <> 'object'
           OR jsonb_typeof(error_item.value -> 'field') <> 'string'
           OR jsonb_typeof(error_item.value -> 'code') <> 'string'
           OR (
                SELECT count(*)
                FROM jsonb_object_keys(error_item.value)
           ) <> 2
           OR (error_item.value ->> 'field')
                !~ '^[a-z][a-z0-9_]{0,63}$'
           OR (error_item.value ->> 'code')
                !~ '^[a-z][a-z0-9_]{0,63}$'
    ) THEN
        RAISE EXCEPTION
            'validation errors must contain only field and code';
    END IF;

    SELECT onboarding_case.*
    INTO case_row
    FROM onboarding_cases AS onboarding_case
    WHERE onboarding_case.id = p_case_id
    FOR UPDATE;

    IF NOT FOUND THEN
        finalization_outcome := 'case_not_found';
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT submission.*
    INTO submission_row
    FROM onboarding_submissions AS submission
    WHERE submission.id = p_submission_id
      AND submission.case_id = p_case_id
    FOR UPDATE;

    IF NOT FOUND THEN
        finalization_outcome := 'submission_not_found';
        final_case_state := case_row.state;
        final_client_id := case_row.client_id;
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT form_token.*
    INTO token_row
    FROM onboarding_form_tokens AS form_token
    WHERE form_token.id = submission_row.form_token_id
      AND form_token.case_id = p_case_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'The submission references a missing form token';
    END IF;

    SELECT step.*
    INTO collect_step_row
    FROM onboarding_steps AS step
    WHERE step.case_id = p_case_id
      AND step.step_type = 'collect_client_data'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'The collect_client_data step is missing';
    END IF;

    SELECT step.*
    INTO validate_step_row
    FROM onboarding_steps AS step
    WHERE step.case_id = p_case_id
      AND step.step_type = 'validate_client_data'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'The validate_client_data step is missing';
    END IF;

    IF submission_row.validation_status = p_validation_status THEN
        IF p_validation_status = 'passed'
            AND submission_row.validation_errors = '[]'::jsonb
            AND case_row.state = 'awaiting_approval'
            AND case_row.accepted_submission_id = p_submission_id
            AND case_row.client_id IS NOT NULL
            AND collect_step_row.status = 'completed'
            AND validate_step_row.status = 'completed'
        THEN
            finalization_outcome := 'already_finalized';
            final_validation_status := 'passed';
            final_case_state := case_row.state;
            final_collect_step_status := collect_step_row.status;
            final_validate_step_status := validate_step_row.status;
            final_client_id := case_row.client_id;
            RETURN NEXT;
            RETURN;
        END IF;

        IF p_validation_status = 'failed'
            AND submission_row.validation_errors = p_validation_errors
            AND case_row.state = 'validation_failed'
            AND case_row.client_id IS NULL
            AND case_row.accepted_submission_id IS NULL
            AND collect_step_row.status = 'in_progress'
            AND validate_step_row.status = 'pending'
        THEN
            finalization_outcome := 'already_finalized';
            final_validation_status := 'failed';
            final_case_state := case_row.state;
            final_collect_step_status := collect_step_row.status;
            final_validate_step_status := validate_step_row.status;
            final_client_id := NULL;
            RETURN NEXT;
            RETURN;
        END IF;

        finalization_outcome :=
            'inconsistent_existing_finalization';
        final_validation_status :=
            submission_row.validation_status;
        final_case_state := case_row.state;
        final_collect_step_status :=
            collect_step_row.status;
        final_validate_step_status :=
            validate_step_row.status;
        final_client_id := case_row.client_id;
        RETURN NEXT;
        RETURN;
    END IF;

    IF submission_row.validation_status <> 'pending' THEN
        finalization_outcome := 'submission_not_pending';
        final_validation_status :=
            submission_row.validation_status;
        final_case_state := case_row.state;
        final_collect_step_status :=
            collect_step_row.status;
        final_validate_step_status :=
            validate_step_row.status;
        final_client_id := case_row.client_id;
        RETURN NEXT;
        RETURN;
    END IF;

    IF case_row.state <> 'data_received'
        OR case_row.client_id IS NOT NULL
        OR case_row.accepted_submission_id IS NOT NULL
    THEN
        finalization_outcome := 'invalid_case_state';
        final_validation_status :=
            submission_row.validation_status;
        final_case_state := case_row.state;
        final_collect_step_status :=
            collect_step_row.status;
        final_validate_step_status :=
            validate_step_row.status;
        final_client_id := case_row.client_id;
        RETURN NEXT;
        RETURN;
    END IF;

    IF token_row.status <> 'consumed'
        OR token_row.consumed_at IS NULL
    THEN
        finalization_outcome := 'token_not_consumed';
        final_validation_status :=
            submission_row.validation_status;
        final_case_state := case_row.state;
        final_collect_step_status :=
            collect_step_row.status;
        final_validate_step_status :=
            validate_step_row.status;
        final_client_id := case_row.client_id;
        RETURN NEXT;
        RETURN;
    END IF;

    IF collect_step_row.status <> 'in_progress' THEN
        finalization_outcome :=
            'invalid_collect_step_state';
        final_validation_status :=
            submission_row.validation_status;
        final_case_state := case_row.state;
        final_collect_step_status :=
            collect_step_row.status;
        final_validate_step_status :=
            validate_step_row.status;
        final_client_id := case_row.client_id;
        RETURN NEXT;
        RETURN;
    END IF;

    IF validate_step_row.status <> 'pending' THEN
        finalization_outcome :=
            'invalid_validate_step_state';
        final_validation_status :=
            submission_row.validation_status;
        final_case_state := case_row.state;
        final_collect_step_status :=
            collect_step_row.status;
        final_validate_step_status :=
            validate_step_row.status;
        final_client_id := case_row.client_id;
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_validation_status = 'failed' THEN
        UPDATE onboarding_submissions
        SET
            validation_status = 'failed',
            validation_errors = p_validation_errors,
            validated_at = v_now
        WHERE id = p_submission_id;

        UPDATE onboarding_cases
        SET state = 'validation_failed'
        WHERE id = p_case_id
          AND state = 'data_received';

        UPDATE onboarding_steps
        SET
            attempt_count = attempt_count + 1,
            started_at = COALESCE(started_at, v_now),
            completed_at = NULL,
            last_error_summary = jsonb_build_object(
                'error_class',
                'business_validation',
                'validation_errors',
                p_validation_errors
            )
        WHERE id = validate_step_row.id
          AND status = 'pending';

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
            'wf03:submission:'
                || p_submission_id::text
                || ':validation-failed',
            'client_data_validation_failed',
            'workflow',
            'WF03',
            'data_received',
            'validation_failed',
            jsonb_build_object(
                'submission_id',
                p_submission_id,
                'submission_sequence',
                submission_row.submission_sequence,
                'validation_error_count',
                jsonb_array_length(p_validation_errors),
                'validation_errors',
                p_validation_errors
            ),
            case_row.correlation_id
        )
        ON CONFLICT (event_key)
        DO NOTHING;

        finalization_outcome := 'finalized';
        final_validation_status := 'failed';
        final_case_state := 'validation_failed';
        final_collect_step_status := 'in_progress';
        final_validate_step_status := 'pending';
        final_client_id := NULL;
        RETURN NEXT;
        RETURN;
    END IF;

    v_country := NULLIF(
        btrim(
            submission_row.normalized_data
                ->> 'company_identifier_country'
        ),
        ''
    );

    v_identifier_type := NULLIF(
        btrim(
            submission_row.normalized_data
                ->> 'company_identifier_type'
        ),
        ''
    );

    v_identifier_value := NULLIF(
        btrim(
            submission_row.normalized_data
                ->> 'company_identifier_value'
        ),
        ''
    );

    v_identifier_value_normalized := NULLIF(
        btrim(
            submission_row.normalized_data
                ->> 'company_identifier_value_normalized'
        ),
        ''
    );

    v_legal_name := NULLIF(
        btrim(
            submission_row.normalized_data
                ->> 'legal_name'
        ),
        ''
    );

    v_contact_first_name := NULLIF(
        btrim(
            submission_row.normalized_data
                ->> 'primary_contact_first_name'
        ),
        ''
    );

    v_contact_last_name := NULLIF(
        btrim(
            submission_row.normalized_data
                ->> 'primary_contact_last_name'
        ),
        ''
    );

    v_contact_email := NULLIF(
        btrim(
            submission_row.normalized_data
                ->> 'primary_contact_email'
        ),
        ''
    );

    v_contact_phone := NULLIF(
        btrim(
            submission_row.normalized_data
                ->> 'primary_contact_phone'
        ),
        ''
    );

    IF v_country IS NULL
        OR v_country !~ '^[A-Z]{2}$'
        OR v_identifier_type IS NULL
        OR v_identifier_type
            !~ '^[a-z0-9][a-z0-9_-]{0,63}$'
        OR v_identifier_value IS NULL
        OR v_identifier_value_normalized IS NULL
        OR v_identifier_value_normalized
            !~ '^[A-Z0-9]{2,64}$'
        OR v_legal_name IS NULL
        OR v_contact_first_name IS NULL
        OR v_contact_last_name IS NULL
        OR v_contact_email IS NULL
        OR v_contact_email
            !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
        OR v_contact_phone IS NULL
        OR v_contact_phone
            !~ '^\+[1-9][0-9]{7,14}$'
    THEN
        finalization_outcome :=
            'normalized_data_invalid';
        final_validation_status :=
            submission_row.validation_status;
        final_case_state := case_row.state;
        final_collect_step_status :=
            collect_step_row.status;
        final_validate_step_status :=
            validate_step_row.status;
        final_client_id := NULL;
        RETURN NEXT;
        RETURN;
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            v_country
                || E'\x1f'
                || v_identifier_type
                || E'\x1f'
                || v_identifier_value_normalized,
            0
        )
    );

    SELECT
        client.id,
        client.source_submission_id
    INTO
        existing_client_id,
        existing_client_source_submission_id
    FROM clients AS client
    WHERE client.company_identifier_country =
            v_country
      AND client.company_identifier_type =
            v_identifier_type
      AND client.company_identifier_value_normalized =
            v_identifier_value_normalized
    FOR UPDATE;

    IF FOUND THEN
        finalization_outcome :=
            'client_identity_conflict';
        final_validation_status :=
            submission_row.validation_status;
        final_case_state := case_row.state;
        final_collect_step_status :=
            collect_step_row.status;
        final_validate_step_status :=
            validate_step_row.status;
        final_client_id := existing_client_id;
        RETURN NEXT;
        RETURN;
    END IF;

    UPDATE onboarding_submissions
    SET
        validation_status = 'passed',
        validation_errors = '[]'::jsonb,
        validated_at = v_now
    WHERE id = p_submission_id;

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
        v_country,
        v_identifier_type,
        v_identifier_value,
        v_identifier_value_normalized,
        v_legal_name,
        v_contact_first_name,
        v_contact_last_name,
        v_contact_email,
        v_contact_phone,
        p_submission_id
    )
    RETURNING id
    INTO new_client_id;

    UPDATE onboarding_cases
    SET
        state = 'awaiting_approval',
        client_id = new_client_id,
        accepted_submission_id = p_submission_id
    WHERE id = p_case_id
      AND state = 'data_received';

    UPDATE onboarding_steps
    SET
        status = 'completed',
        completed_at = v_now,
        last_error_summary = NULL
    WHERE id = collect_step_row.id
      AND status = 'in_progress';

    UPDATE onboarding_steps
    SET
        status = 'completed',
        attempt_count = attempt_count + 1,
        started_at = COALESCE(started_at, v_now),
        completed_at = v_now,
        last_error_summary = NULL
    WHERE id = validate_step_row.id
      AND status = 'pending';

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
        'wf03:submission:'
            || p_submission_id::text
            || ':validation-passed',
        'client_data_validation_passed',
        'workflow',
        'WF03',
        'data_received',
        'awaiting_approval',
        jsonb_build_object(
            'submission_id',
            p_submission_id,
            'submission_sequence',
            submission_row.submission_sequence,
            'client_id',
            new_client_id
        ),
        case_row.correlation_id
    )
    ON CONFLICT (event_key)
    DO NOTHING;

    finalization_outcome := 'finalized';
    final_validation_status := 'passed';
    final_case_state := 'awaiting_approval';
    final_collect_step_status := 'completed';
    final_validate_step_status := 'completed';
    final_client_id := new_client_id;

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION finalize_wf03_validation(
    uuid,
    uuid,
    text,
    jsonb
)
IS
'Atomically finalizes WF03 business validation, creates the client on success, and preserves correction state on failure.';

COMMIT;
