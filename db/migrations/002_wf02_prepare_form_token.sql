BEGIN;

CREATE OR REPLACE FUNCTION prepare_client_data_form_token(
    p_case_id uuid,
    p_correlation_id uuid,
    p_request_cycle_key text,
    p_failed_submission_id uuid,
    p_candidate_token_id uuid,
    p_candidate_token_hash bytea,
    p_candidate_token_ciphertext bytea,
    p_candidate_token_nonce bytea,
    p_candidate_token_auth_tag bytea,
    p_encryption_key_id text,
    p_ttl_hours integer DEFAULT 72
)
RETURNS TABLE (
    prepare_outcome text,
    authoritative_token_id uuid,
    authoritative_token_status text,
    authoritative_token_expires_at timestamptz,
    authoritative_token_hash_base64 text,
    authoritative_token_ciphertext_base64 text,
    authoritative_token_nonce_base64 text,
    authoritative_token_auth_tag_base64 text,
    authoritative_encryption_key_id text,
    token_created boolean,
    collect_step_id uuid,
    collect_step_attempt_count integer,
    expired_stale_token_id uuid,
    database_now timestamptz
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_case onboarding_cases%ROWTYPE;
    v_step onboarding_steps%ROWTYPE;
    v_token onboarding_form_tokens%ROWTYPE;
    v_active_token onboarding_form_tokens%ROWTYPE;

    v_expected_case_state text;
    v_expected_step_status text;
    v_failed_submission_status text;

    v_now timestamptz := clock_timestamp();
BEGIN
    database_now := v_now;
    token_created := false;

    IF p_case_id IS NULL THEN
        RAISE EXCEPTION
            'case_id is required';
    END IF;

    IF p_correlation_id IS NULL THEN
        RAISE EXCEPTION
            'correlation_id is required';
    END IF;

    IF p_request_cycle_key IS NULL
        OR btrim(p_request_cycle_key) = ''
    THEN
        RAISE EXCEPTION
            'request_cycle_key must not be blank';
    END IF;

    IF p_candidate_token_id IS NULL THEN
        RAISE EXCEPTION
            'candidate_token_id is required';
    END IF;

    IF p_candidate_token_hash IS NULL
        OR octet_length(p_candidate_token_hash) <> 32
    THEN
        RAISE EXCEPTION
            'candidate token hash must contain exactly 32 bytes';
    END IF;

    IF p_candidate_token_ciphertext IS NULL
        OR octet_length(p_candidate_token_ciphertext) <> 32
    THEN
        RAISE EXCEPTION
            'candidate token ciphertext must contain exactly 32 bytes';
    END IF;

    IF p_candidate_token_nonce IS NULL
        OR octet_length(p_candidate_token_nonce) <> 12
    THEN
        RAISE EXCEPTION
            'candidate token nonce must contain exactly 12 bytes';
    END IF;

    IF p_candidate_token_auth_tag IS NULL
        OR octet_length(p_candidate_token_auth_tag) <> 16
    THEN
        RAISE EXCEPTION
            'candidate token authentication tag must contain exactly 16 bytes';
    END IF;

    IF p_encryption_key_id IS NULL
        OR btrim(p_encryption_key_id) = ''
    THEN
        RAISE EXCEPTION
            'encryption_key_id must not be blank';
    END IF;

    IF p_ttl_hours IS NULL
        OR p_ttl_hours < 1
        OR p_ttl_hours > 720
    THEN
        RAISE EXCEPTION
            'ttl_hours must be between 1 and 720';
    END IF;

    /*
     * Serialize all token preparation for this case.
     */
    SELECT onboarding_case.*
    INTO v_case
    FROM onboarding_cases AS onboarding_case
    WHERE onboarding_case.id = p_case_id
    FOR UPDATE;

    IF NOT FOUND THEN
        prepare_outcome := 'case_not_found';

        RETURN NEXT;
        RETURN;
    END IF;

    IF v_case.correlation_id
        IS DISTINCT FROM p_correlation_id
    THEN
        prepare_outcome := 'correlation_mismatch';

        RETURN NEXT;
        RETURN;
    END IF;

    /*
     * Validate the deterministic request-cycle identity.
     */
    IF p_request_cycle_key = 'initial' THEN
        IF p_failed_submission_id IS NOT NULL THEN
            prepare_outcome :=
                'invalid_initial_cycle_identity';

            RETURN NEXT;
            RETURN;
        END IF;

        v_expected_case_state := 'created';
        v_expected_step_status := 'pending';

    ELSE
        IF p_failed_submission_id IS NULL
            OR p_request_cycle_key <>
                (
                    'validation_failed:' ||
                    p_failed_submission_id::text
                )
        THEN
            prepare_outcome :=
                'invalid_correction_cycle_identity';

            RETURN NEXT;
            RETURN;
        END IF;

        SELECT submission.validation_status
        INTO v_failed_submission_status
        FROM onboarding_submissions AS submission
        WHERE submission.id = p_failed_submission_id
          AND submission.case_id = p_case_id;

        IF NOT FOUND
            OR v_failed_submission_status <> 'failed'
        THEN
            prepare_outcome :=
                'invalid_failed_submission';

            RETURN NEXT;
            RETURN;
        END IF;

        v_expected_case_state := 'validation_failed';
        v_expected_step_status := 'completed';
    END IF;

    IF v_case.state <> v_expected_case_state THEN
        prepare_outcome := 'invalid_case_state';

        RETURN NEXT;
        RETURN;
    END IF;

    /*
     * Lock the collection step.
     */
    SELECT step.*
    INTO v_step
    FROM onboarding_steps AS step
    WHERE step.case_id = p_case_id
      AND step.step_type = 'collect_client_data'
    FOR UPDATE;

    IF NOT FOUND THEN
        prepare_outcome := 'collect_step_not_found';

        RETURN NEXT;
        RETURN;
    END IF;

    collect_step_id := v_step.id;
    collect_step_attempt_count :=
        v_step.attempt_count;

    /*
     * Reuse the authoritative token if another execution
     * already created this exact request cycle.
     */
    SELECT token.*
    INTO v_token
    FROM onboarding_form_tokens AS token
    WHERE token.case_id = p_case_id
      AND token.request_cycle_key =
          p_request_cycle_key
    FOR UPDATE;

    IF FOUND THEN
        authoritative_token_id := v_token.id;
        authoritative_token_status :=
            v_token.status;
        authoritative_token_expires_at :=
            v_token.expires_at;
        authoritative_encryption_key_id :=
            v_token.encryption_key_id;

        IF v_token.status = 'issued'
            AND v_token.expires_at <= v_now
        THEN
            UPDATE onboarding_form_tokens
            SET
                status = 'expired',
                token_ciphertext = NULL,
                token_nonce = NULL,
                token_auth_tag = NULL,
                encryption_key_id = NULL
            WHERE id = v_token.id
            RETURNING *
            INTO v_token;

            authoritative_token_status :=
                v_token.status;
            authoritative_encryption_key_id :=
                NULL;

            prepare_outcome :=
                'same_cycle_token_expired';

            RETURN NEXT;
            RETURN;
        END IF;

        IF v_token.status = 'issued'
            AND v_token.expires_at > v_now
        THEN
            IF v_token.token_ciphertext IS NULL
                OR octet_length(
                    v_token.token_ciphertext
                ) <> 32
                OR v_token.token_nonce IS NULL
                OR octet_length(
                    v_token.token_nonce
                ) <> 12
                OR v_token.token_auth_tag IS NULL
                OR octet_length(
                    v_token.token_auth_tag
                ) <> 16
                OR v_token.encryption_key_id IS NULL
                OR btrim(
                    v_token.encryption_key_id
                ) = ''
            THEN
                prepare_outcome :=
                    'invalid_existing_token_crypto';

                RETURN NEXT;
                RETURN;
            END IF;

            IF v_step.status <> 'in_progress' THEN
                prepare_outcome :=
                    'existing_token_step_mismatch';

                RETURN NEXT;
                RETURN;
            END IF;

            authoritative_token_hash_base64 :=
                encode(
                    v_token.token_hash,
                    'base64'
                );

            authoritative_token_ciphertext_base64 :=
                encode(
                    v_token.token_ciphertext,
                    'base64'
                );

            authoritative_token_nonce_base64 :=
                encode(
                    v_token.token_nonce,
                    'base64'
                );

            authoritative_token_auth_tag_base64 :=
                encode(
                    v_token.token_auth_tag,
                    'base64'
                );

            prepare_outcome :=
                'reused_issued_token';

            RETURN NEXT;
            RETURN;
        END IF;

        IF v_token.status = 'delivered' THEN
            prepare_outcome :=
                'same_cycle_already_delivered';

            RETURN NEXT;
            RETURN;
        END IF;

        prepare_outcome :=
            'same_cycle_already_closed';

        RETURN NEXT;
        RETURN;
    END IF;

    /*
     * Inspect the one possible active token belonging
     * to another request cycle.
     */
    SELECT token.*
    INTO v_active_token
    FROM onboarding_form_tokens AS token
    WHERE token.case_id = p_case_id
      AND token.request_cycle_key <>
          p_request_cycle_key
      AND token.status IN (
          'issued',
          'delivered'
      )
    ORDER BY
        token.issued_at DESC,
        token.id DESC
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
        IF v_active_token.status = 'issued'
            AND v_active_token.expires_at <= v_now
        THEN
            UPDATE onboarding_form_tokens
            SET
                status = 'expired',
                token_ciphertext = NULL,
                token_nonce = NULL,
                token_auth_tag = NULL,
                encryption_key_id = NULL
            WHERE id = v_active_token.id;

            expired_stale_token_id :=
                v_active_token.id;
        ELSE
            prepare_outcome :=
                'blocked_by_other_active_cycle';

            authoritative_token_id :=
                v_active_token.id;

            authoritative_token_status :=
                v_active_token.status;

            authoritative_token_expires_at :=
                v_active_token.expires_at;

            RETURN NEXT;
            RETURN;
        END IF;
    END IF;

    /*
     * A genuinely new cycle must start from the
     * expected step state.
     */
    IF v_step.status <> v_expected_step_status THEN
        prepare_outcome :=
            'invalid_new_cycle_step_state';

        RETURN NEXT;
        RETURN;
    END IF;

    /*
     * Insert the candidate token using database time.
     */
    INSERT INTO onboarding_form_tokens (
        id,
        case_id,
        request_cycle_key,
        token_hash,
        token_ciphertext,
        token_nonce,
        token_auth_tag,
        encryption_key_id,
        status,
        expires_at,
        issued_at
    )
    VALUES (
        p_candidate_token_id,
        p_case_id,
        p_request_cycle_key,
        p_candidate_token_hash,
        p_candidate_token_ciphertext,
        p_candidate_token_nonce,
        p_candidate_token_auth_tag,
        p_encryption_key_id,
        'issued',
        v_now + make_interval(
            hours => p_ttl_hours
        ),
        v_now
    )
    RETURNING *
    INTO v_token;

    /*
     * The step attempt count represents request cycles,
     * not individual Gmail attempts.
     */
    UPDATE onboarding_steps
    SET
        status = 'in_progress',
        attempt_count = attempt_count + 1,
        started_at = v_now,
        completed_at = NULL,
        last_error_summary = NULL
    WHERE id = v_step.id
    RETURNING *
    INTO v_step;

    /*
     * Record a sanitized, deterministic issued event.
     */
    INSERT INTO onboarding_events (
        case_id,
        event_key,
        event_type,
        actor_type,
        actor_identifier,
        previous_state,
        new_state,
        event_data,
        correlation_id,
        occurred_at
    )
    VALUES (
        p_case_id,
        (
            'onboarding:' ||
            p_case_id::text ||
            ':form-token:' ||
            v_token.id::text ||
            ':issued'
        ),
        'client_data_token_issued',
        'workflow',
        'WF02',
        NULL,
        NULL,
        jsonb_build_object(
            'token_id',
            v_token.id,
            'request_cycle_key',
            p_request_cycle_key,
            'expires_at',
            v_token.expires_at
        ),
        v_case.correlation_id,
        v_now
    )
    ON CONFLICT (event_key)
    DO NOTHING;

    prepare_outcome := 'created';

    authoritative_token_id :=
        v_token.id;

    authoritative_token_status :=
        v_token.status;

    authoritative_token_expires_at :=
        v_token.expires_at;

    authoritative_token_hash_base64 :=
        encode(
            v_token.token_hash,
            'base64'
        );

    authoritative_token_ciphertext_base64 :=
        encode(
            v_token.token_ciphertext,
            'base64'
        );

    authoritative_token_nonce_base64 :=
        encode(
            v_token.token_nonce,
            'base64'
        );

    authoritative_token_auth_tag_base64 :=
        encode(
            v_token.token_auth_tag,
            'base64'
        );

    authoritative_encryption_key_id :=
        v_token.encryption_key_id;

    token_created := true;

    collect_step_id :=
        v_step.id;

    collect_step_attempt_count :=
        v_step.attempt_count;

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION prepare_client_data_form_token(
    uuid,
    uuid,
    text,
    uuid,
    uuid,
    bytea,
    bytea,
    bytea,
    bytea,
    text,
    integer
)
IS
'Atomically prepares or resolves the authoritative WF02 client-data form token and collection step.';

COMMIT;
