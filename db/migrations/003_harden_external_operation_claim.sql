BEGIN;

CREATE OR REPLACE FUNCTION claim_external_operation(
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

    IF p_operation_type IS NULL
        OR btrim(p_operation_type) = ''
    THEN
        RAISE EXCEPTION
            'operation_type must not be blank';
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
    ON CONFLICT (idempotency_key)
    DO NOTHING;

    SELECT operation.*
    INTO operation_row
    FROM external_operations AS operation
    WHERE operation.idempotency_key =
          p_idempotency_key
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'External operation could not be created or resolved';
    END IF;

    v_now := clock_timestamp();

    IF operation_row.operation_type
            IS DISTINCT FROM p_operation_type
        OR operation_row.case_id
            IS DISTINCT FROM p_case_id
    THEN
        RAISE EXCEPTION
            'The idempotency key belongs to a different operation';
    END IF;

    /*
     * The operation identity and request fields are immutable.
     * A repeated claim must provide the same recovery contract.
     */
    IF operation_row.max_attempts
            IS DISTINCT FROM p_max_attempts
    THEN
        RAISE EXCEPTION
            'The existing operation has a different max_attempts value';
    END IF;

    IF operation_row.request_summary
            IS DISTINCT FROM p_request_summary
    THEN
        RAISE EXCEPTION
            'The existing operation has a different request_summary';
    END IF;

    IF operation_row.status = 'succeeded' THEN
        claim_outcome :=
            'reuse_succeeded';

    ELSIF operation_row.status =
          'failed_terminal'
    THEN
        claim_outcome :=
            'refused_terminal';

    ELSIF operation_row.status =
          'in_progress'
        AND operation_row.lease_expires_at >
            v_now
    THEN
        claim_outcome :=
            'busy';

    ELSIF operation_row.attempt_count >=
          operation_row.max_attempts
    THEN
        claim_outcome :=
            'refused_exhausted';

    ELSIF operation_row.status =
          'failed_retryable'
        AND operation_row.next_retry_at >
            v_now
    THEN
        claim_outcome :=
            'not_due';

    ELSE
        UPDATE external_operations
        SET
            status =
                'in_progress',

            attempt_count =
                external_operations.attempt_count + 1,

            next_retry_at =
                NULL,

            lease_owner =
                p_lease_owner,

            lease_expires_at =
                v_now +
                make_interval(
                    secs => p_lease_seconds
                ),

            started_at =
                COALESCE(
                    external_operations.started_at,
                    v_now
                ),

            completed_at =
                NULL

        WHERE id =
              operation_row.id

        RETURNING *
        INTO operation_row;

        claim_outcome :=
            'claimed';
    END IF;

    operation_id :=
        operation_row.id;

    operation_status :=
        operation_row.status;

    current_attempt_count :=
        operation_row.attempt_count;

    configured_max_attempts :=
        operation_row.max_attempts;

    current_lease_expires_at :=
        operation_row.lease_expires_at;

    current_external_id :=
        operation_row.external_id;

    current_response_summary :=
        operation_row.response_summary;

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION claim_external_operation(
    text,
    text,
    uuid,
    text,
    integer,
    integer,
    jsonb
)
IS
'Atomically creates, validates, and claims an immutable external operation.';

COMMIT;
