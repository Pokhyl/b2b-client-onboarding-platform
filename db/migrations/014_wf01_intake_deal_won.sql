BEGIN;

CREATE OR REPLACE FUNCTION process_wf01_intake(
    p_source_system text,
    p_source_event_id text,
    p_source_deal_id text,
    p_intake_company_name text,
    p_intake_contact_first_name text,
    p_intake_contact_last_name text,
    p_intake_contact_email text,
    p_intake_contact_phone text,
    p_intake_metadata jsonb
)
RETURNS TABLE (
    database_outcome text,
    intake_result text,
    case_id uuid,
    correlation_id uuid,
    case_state text,
    should_dispatch_wf02 boolean,
    http_status integer
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_case onboarding_cases%ROWTYPE;
    v_event onboarding_events%ROWTYPE;

    v_source_event_key text;
    v_case_created_event_key text;

    v_case_inserted boolean := false;
    v_source_event_inserted boolean := false;
    v_provisional_result text;
    v_now timestamptz := clock_timestamp();
BEGIN
    /*
     * Defensive validation.
     * n8n validates these values before calling this function,
     * but PostgreSQL remains the authoritative boundary.
     */
    IF p_source_system IS NULL
        OR btrim(p_source_system) = ''
    THEN
        RAISE EXCEPTION 'source_system must not be blank';
    END IF;

    IF p_source_event_id IS NULL
        OR btrim(p_source_event_id) = ''
    THEN
        RAISE EXCEPTION 'source_event_id must not be blank';
    END IF;

    IF p_source_deal_id IS NULL
        OR btrim(p_source_deal_id) = ''
    THEN
        RAISE EXCEPTION 'source_deal_id must not be blank';
    END IF;

    IF p_intake_company_name IS NULL
        OR btrim(p_intake_company_name) = ''
    THEN
        RAISE EXCEPTION 'intake_company_name must not be blank';
    END IF;

    IF p_intake_contact_email IS NULL
        OR btrim(p_intake_contact_email) = ''
    THEN
        RAISE EXCEPTION 'intake_contact_email must not be blank';
    END IF;

    IF p_intake_metadata IS NULL
        OR jsonb_typeof(p_intake_metadata) <> 'object'
    THEN
        RAISE EXCEPTION 'intake_metadata must be a JSON object';
    END IF;

    v_source_event_key :=
        'crm:' ||
        p_source_system ||
        ':event:' ||
        p_source_event_id ||
        ':deal-won-received';

    /*
     * First resolve an already recorded source event.
     */
    SELECT event.*
    INTO v_event
    FROM onboarding_events AS event
    WHERE event.event_key = v_source_event_key;

    IF FOUND THEN
        IF NOT (v_event.event_data ? 'source_deal_id') THEN
            RAISE EXCEPTION
                'WF01 persisted-data inconsistency: source event has no source_deal_id';
        END IF;

        IF v_event.event_data ->> 'source_deal_id'
            IS DISTINCT FROM p_source_deal_id
        THEN
            database_outcome := 'source_identity_conflict';
            intake_result := NULL;
            case_id := NULL;
            correlation_id := NULL;
            case_state := NULL;
            should_dispatch_wf02 := false;
            http_status := 409;

            RETURN NEXT;
            RETURN;
        END IF;

        IF v_event.case_id IS NULL THEN
            RAISE EXCEPTION
                'WF01 persisted-data inconsistency: source event has no case_id';
        END IF;

        SELECT onboarding_case.*
        INTO v_case
        FROM onboarding_cases AS onboarding_case
        WHERE onboarding_case.id = v_event.case_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'WF01 persisted-data inconsistency: source event case does not exist';
        END IF;

        database_outcome := 'accepted';
        intake_result := 'duplicate_event';
        case_id := v_case.id;
        correlation_id := v_case.correlation_id;
        case_state := v_case.state;

        should_dispatch_wf02 :=
            v_case.state = 'created'
            AND NOT EXISTS (
                SELECT 1
                FROM external_operations AS operation
                WHERE operation.case_id = v_case.id
                  AND operation.operation_type =
                      'send_client_data_request'
                  AND operation.status = 'succeeded'
            );

        http_status := 200;

        RETURN NEXT;
        RETURN;
    END IF;

    /*
     * Defensive source-event lookup.
     * A case with this event but without its business event
     * indicates an incomplete persisted state.
     */
    SELECT onboarding_case.*
    INTO v_case
    FROM onboarding_cases AS onboarding_case
    WHERE onboarding_case.source_system = p_source_system
      AND onboarding_case.source_event_id = p_source_event_id;

    IF FOUND THEN
        IF v_case.source_deal_id
            IS DISTINCT FROM p_source_deal_id
        THEN
            database_outcome := 'source_identity_conflict';
            intake_result := NULL;
            case_id := NULL;
            correlation_id := NULL;
            case_state := NULL;
            should_dispatch_wf02 := false;
            http_status := 409;

            RETURN NEXT;
            RETURN;
        END IF;

        RAISE EXCEPTION
            'WF01 persisted-data inconsistency: case exists but source event is missing';
    END IF;

    /*
     * Resolve an existing case for the same source deal.
     */
    SELECT onboarding_case.*
    INTO v_case
    FROM onboarding_cases AS onboarding_case
    WHERE onboarding_case.source_system = p_source_system
      AND onboarding_case.source_deal_id = p_source_deal_id;

    IF NOT FOUND THEN
        /*
         * Attempt conflict-safe case creation.
         * PostgreSQL uniqueness constraints resolve concurrency.
         */
        INSERT INTO onboarding_cases (
            source_system,
            source_event_id,
            source_deal_id,
            state,
            intake_company_name,
            intake_contact_first_name,
            intake_contact_last_name,
            intake_contact_email,
            intake_contact_phone,
            intake_metadata
        )
        VALUES (
            p_source_system,
            p_source_event_id,
            p_source_deal_id,
            'created',
            p_intake_company_name,
            p_intake_contact_first_name,
            p_intake_contact_last_name,
            p_intake_contact_email,
            p_intake_contact_phone,
            p_intake_metadata
        )
        ON CONFLICT DO NOTHING
        RETURNING *
        INTO v_case;

        v_case_inserted := FOUND;

        IF NOT v_case_inserted THEN
            /*
             * Another transaction may have created the
             * authoritative event and case concurrently.
             */
            SELECT event.*
            INTO v_event
            FROM onboarding_events AS event
            WHERE event.event_key = v_source_event_key;

            IF FOUND THEN
                IF v_event.event_data ->> 'source_deal_id'
                    IS DISTINCT FROM p_source_deal_id
                THEN
                    database_outcome :=
                        'source_identity_conflict';
                    intake_result := NULL;
                    case_id := NULL;
                    correlation_id := NULL;
                    case_state := NULL;
                    should_dispatch_wf02 := false;
                    http_status := 409;

                    RETURN NEXT;
                    RETURN;
                END IF;

                SELECT onboarding_case.*
                INTO v_case
                FROM onboarding_cases AS onboarding_case
                WHERE onboarding_case.id = v_event.case_id;

                IF NOT FOUND THEN
                    RAISE EXCEPTION
                        'WF01 persisted-data inconsistency: concurrent event case does not exist';
                END IF;

                database_outcome := 'accepted';
                intake_result := 'duplicate_event';
                case_id := v_case.id;
                correlation_id := v_case.correlation_id;
                case_state := v_case.state;

                should_dispatch_wf02 :=
                    v_case.state = 'created'
                    AND NOT EXISTS (
                        SELECT 1
                        FROM external_operations AS operation
                        WHERE operation.case_id = v_case.id
                          AND operation.operation_type =
                              'send_client_data_request'
                          AND operation.status = 'succeeded'
                    );

                http_status := 200;

                RETURN NEXT;
                RETURN;
            END IF;

            SELECT onboarding_case.*
            INTO v_case
            FROM onboarding_cases AS onboarding_case
            WHERE onboarding_case.source_system =
                    p_source_system
              AND onboarding_case.source_event_id =
                    p_source_event_id;

            IF FOUND THEN
                IF v_case.source_deal_id
                    IS DISTINCT FROM p_source_deal_id
                THEN
                    database_outcome :=
                        'source_identity_conflict';
                    intake_result := NULL;
                    case_id := NULL;
                    correlation_id := NULL;
                    case_state := NULL;
                    should_dispatch_wf02 := false;
                    http_status := 409;

                    RETURN NEXT;
                    RETURN;
                END IF;

                RAISE EXCEPTION
                    'WF01 persisted-data inconsistency: concurrent case exists but event is missing';
            END IF;

            SELECT onboarding_case.*
            INTO v_case
            FROM onboarding_cases AS onboarding_case
            WHERE onboarding_case.source_system =
                    p_source_system
              AND onboarding_case.source_deal_id =
                    p_source_deal_id;

            IF NOT FOUND THEN
                RAISE EXCEPTION
                    'WF01 could not resolve authoritative onboarding case';
            END IF;
        END IF;
    END IF;

    v_provisional_result :=
        CASE
            WHEN v_case_inserted THEN 'created'
            ELSE 'existing_deal'
        END;

    /*
     * Record the source event once.
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
        v_case.id,
        v_source_event_key,
        'crm_deal_won_received',
        'external_system',
        p_source_system,
        NULL,
        NULL,
        jsonb_build_object(
            'source_system',
            p_source_system,
            'source_event_id',
            p_source_event_id,
            'source_deal_id',
            p_source_deal_id,
            'source_event_type',
            'deal.won',
            'intake_result',
            v_provisional_result
        ),
        v_case.correlation_id,
        v_now
    )
    ON CONFLICT (event_key) DO NOTHING
    RETURNING *
    INTO v_event;

    v_source_event_inserted := FOUND;

    IF NOT v_source_event_inserted THEN
        SELECT event.*
        INTO v_event
        FROM onboarding_events AS event
        WHERE event.event_key = v_source_event_key;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'WF01 persisted-data inconsistency: source event conflict could not be resolved';
        END IF;

        IF v_event.event_data ->> 'source_deal_id'
            IS DISTINCT FROM p_source_deal_id
        THEN
            database_outcome := 'source_identity_conflict';
            intake_result := NULL;
            case_id := NULL;
            correlation_id := NULL;
            case_state := NULL;
            should_dispatch_wf02 := false;
            http_status := 409;

            RETURN NEXT;
            RETURN;
        END IF;

        IF v_event.case_id IS DISTINCT FROM v_case.id THEN
            RAISE EXCEPTION
                'WF01 persisted-data inconsistency: source event points to another case';
        END IF;
    END IF;

    /*
     * Record case creation only when this transaction
     * created the onboarding case.
     */
    IF v_case_inserted THEN
        v_case_created_event_key :=
            'onboarding:' ||
            v_case.id::text ||
            ':case-created';

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
            v_case.id,
            v_case_created_event_key,
            'onboarding_case_created',
            'workflow',
            'WF01',
            NULL,
            'created',
            jsonb_build_object(
                'source_system',
                p_source_system,
                'source_event_id',
                p_source_event_id,
                'source_deal_id',
                p_source_deal_id
            ),
            v_case.correlation_id,
            v_now
        )
        ON CONFLICT (event_key) DO NOTHING;
    END IF;

    database_outcome := 'accepted';

    intake_result :=
        CASE
            WHEN NOT v_source_event_inserted
                THEN 'duplicate_event'
            WHEN v_case_inserted
                THEN 'created'
            ELSE 'existing_deal'
        END;

    case_id := v_case.id;
    correlation_id := v_case.correlation_id;
    case_state := v_case.state;

    should_dispatch_wf02 :=
        v_case.state = 'created'
        AND NOT EXISTS (
            SELECT 1
            FROM external_operations AS operation
            WHERE operation.case_id = v_case.id
              AND operation.operation_type =
                  'send_client_data_request'
              AND operation.status = 'succeeded'
        );

    http_status :=
        CASE
            WHEN intake_result = 'created' THEN 201
            ELSE 200
        END;

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION process_wf01_intake(
    text,
    text,
    text,
    text,
    text,
    text,
    text,
    text,
    jsonb
) IS
'Atomically resolves WF01 Deal Won intake, creates idempotent business events, and determines whether WF02 dispatch is required.';

COMMIT;
