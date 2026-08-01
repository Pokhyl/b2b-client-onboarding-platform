\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE wf01_test_context (
    case_id uuid PRIMARY KEY,
    correlation_id uuid NOT NULL,
    source_event_id text NOT NULL,
    source_deal_id text NOT NULL
) ON COMMIT DROP;

DO $$
DECLARE
    v_suffix text := replace(gen_random_uuid()::text, '-', '');
    v_event_id text;
    v_deal_id text;
    v_result record;
    v_case_count integer;
    v_step_count integer;
    v_event_count integer;
    v_case_created_count integer;
    v_source_event_count integer;
    v_sensitive_event_count integer;
BEGIN
    v_event_id := 'wf01-test-event-' || v_suffix;
    v_deal_id := 'wf01-test-deal-' || v_suffix;

    SELECT *
    INTO STRICT v_result
    FROM process_wf01_intake(
        'mock_crm',
        v_event_id,
        v_deal_id,
        'WF01 Test Company',
        'Intake',
        'Tester',
        'wf01-test@example.com',
        '+48000000000',
        jsonb_build_object(
            'event_type',
            'deal.won',
            'crm',
            jsonb_build_object(
                'pipeline_id',
                'wf01-test',
                'owner_id',
                'automation'
            )
        )
    );

    IF v_result.database_outcome <> 'accepted'
        OR v_result.intake_result <> 'created'
        OR v_result.case_id IS NULL
        OR v_result.correlation_id IS NULL
        OR v_result.case_state <> 'created'
        OR v_result.should_dispatch_wf02 IS DISTINCT FROM true
        OR v_result.http_status <> 201
    THEN
        RAISE EXCEPTION
            'Unexpected WF01 create result: %',
            row_to_json(v_result);
    END IF;

    INSERT INTO wf01_test_context (
        case_id,
        correlation_id,
        source_event_id,
        source_deal_id
    )
    VALUES (
        v_result.case_id,
        v_result.correlation_id,
        v_event_id,
        v_deal_id
    );

    SELECT count(*)
    INTO v_case_count
    FROM onboarding_cases
    WHERE source_system = 'mock_crm'
      AND source_deal_id = v_deal_id;

    SELECT count(*)
    INTO v_step_count
    FROM onboarding_steps
    WHERE case_id = v_result.case_id;

    SELECT
        count(*),
        count(*) FILTER (
            WHERE event_type = 'onboarding_case_created'
        ),
        count(*) FILTER (
            WHERE event_type = 'crm_deal_won_received'
        ),
        count(*) FILTER (
            WHERE event_data ?| ARRAY[
                'intake_contact_email',
                'intake_contact_phone',
                'authorization',
                'headers'
            ]
        )
    INTO
        v_event_count,
        v_case_created_count,
        v_source_event_count,
        v_sensitive_event_count
    FROM onboarding_events
    WHERE case_id = v_result.case_id;

    IF v_case_count <> 1
        OR v_step_count <> 7
        OR v_event_count <> 2
        OR v_case_created_count <> 1
        OR v_source_event_count <> 1
        OR v_sensitive_event_count <> 0
    THEN
        RAISE EXCEPTION
            'WF01 create invariants failed: cases=%, steps=%, events=%, created_events=%, source_events=%, sensitive_events=%',
            v_case_count,
            v_step_count,
            v_event_count,
            v_case_created_count,
            v_source_event_count,
            v_sensitive_event_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM onboarding_cases
        WHERE id = v_result.case_id
          AND correlation_id = v_result.correlation_id
          AND source_event_id = v_event_id
          AND source_deal_id = v_deal_id
          AND state = 'created'
          AND client_id IS NULL
          AND accepted_submission_id IS NULL
          AND intake_company_name = 'WF01 Test Company'
          AND intake_contact_email = 'wf01-test@example.com'
          AND intake_metadata = jsonb_build_object(
              'event_type',
              'deal.won',
              'crm',
              jsonb_build_object(
                  'pipeline_id',
                  'wf01-test',
                  'owner_id',
                  'automation'
              )
          )
    ) THEN
        RAISE EXCEPTION
            'WF01 persisted case does not match normalized input';
    END IF;

    RAISE NOTICE
        'PASS: WF01 creates one authoritative case, seven steps, and sanitized idempotent events';
END;
$$;

DO $$
DECLARE
    v_context wf01_test_context%ROWTYPE;
    v_result record;
    v_event_count integer;
BEGIN
    SELECT *
    INTO STRICT v_context
    FROM wf01_test_context
    LIMIT 1;

    SELECT *
    INTO STRICT v_result
    FROM process_wf01_intake(
        'mock_crm',
        v_context.source_event_id,
        v_context.source_deal_id,
        'Changed Company Must Not Persist',
        'Changed',
        'Contact',
        'changed@example.com',
        '+48999999999',
        '{"event_type":"deal.won","crm":{}}'::jsonb
    );

    SELECT count(*)
    INTO v_event_count
    FROM onboarding_events
    WHERE case_id = v_context.case_id;

    IF v_result.database_outcome <> 'accepted'
        OR v_result.intake_result <> 'duplicate_event'
        OR v_result.case_id <> v_context.case_id
        OR v_result.correlation_id <> v_context.correlation_id
        OR v_result.should_dispatch_wf02 IS DISTINCT FROM true
        OR v_result.http_status <> 200
        OR v_event_count <> 2
        OR NOT EXISTS (
            SELECT 1
            FROM onboarding_cases
            WHERE id = v_context.case_id
              AND intake_company_name = 'WF01 Test Company'
              AND intake_contact_email = 'wf01-test@example.com'
        )
    THEN
        RAISE EXCEPTION
            'WF01 duplicate-event invariants failed: result=%, events=%',
            row_to_json(v_result),
            v_event_count;
    END IF;

    RAISE NOTICE
        'PASS: duplicate delivery returns the same immutable case without duplicate events';
END;
$$;

DO $$
DECLARE
    v_context wf01_test_context%ROWTYPE;
    v_new_event_id text;
    v_result record;
    v_event_count integer;
BEGIN
    SELECT *
    INTO STRICT v_context
    FROM wf01_test_context
    LIMIT 1;

    v_new_event_id :=
        'wf01-test-existing-' ||
        replace(gen_random_uuid()::text, '-', '');

    SELECT *
    INTO STRICT v_result
    FROM process_wf01_intake(
        'mock_crm',
        v_new_event_id,
        v_context.source_deal_id,
        'Another Company Name',
        NULL,
        NULL,
        'another@example.com',
        NULL,
        '{"event_type":"deal.won","crm":{}}'::jsonb
    );

    SELECT count(*)
    INTO v_event_count
    FROM onboarding_events
    WHERE case_id = v_context.case_id;

    IF v_result.intake_result <> 'existing_deal'
        OR v_result.case_id <> v_context.case_id
        OR v_result.correlation_id <> v_context.correlation_id
        OR v_result.should_dispatch_wf02 IS DISTINCT FROM true
        OR v_result.http_status <> 200
        OR v_event_count <> 3
        OR NOT EXISTS (
            SELECT 1
            FROM onboarding_cases
            WHERE id = v_context.case_id
              AND source_event_id = v_context.source_event_id
        )
        OR NOT EXISTS (
            SELECT 1
            FROM onboarding_events
            WHERE case_id = v_context.case_id
              AND event_key =
                  'crm:mock_crm:event:' ||
                  v_new_event_id ||
                  ':deal-won-received'
              AND event_data ->> 'intake_result' = 'existing_deal'
        )
    THEN
        RAISE EXCEPTION
            'WF01 existing-deal invariants failed: result=%, events=%',
            row_to_json(v_result),
            v_event_count;
    END IF;

    RAISE NOTICE
        'PASS: a new event for an existing deal reuses the case and records one intake event';
END;
$$;

DO $$
DECLARE
    v_context wf01_test_context%ROWTYPE;
    v_conflicting_deal_id text;
    v_result record;
    v_event_count_before integer;
    v_event_count_after integer;
BEGIN
    SELECT *
    INTO STRICT v_context
    FROM wf01_test_context
    LIMIT 1;

    v_conflicting_deal_id :=
        'wf01-test-conflict-' ||
        replace(gen_random_uuid()::text, '-', '');

    SELECT count(*)
    INTO v_event_count_before
    FROM onboarding_events
    WHERE case_id = v_context.case_id;

    SELECT *
    INTO STRICT v_result
    FROM process_wf01_intake(
        'mock_crm',
        v_context.source_event_id,
        v_conflicting_deal_id,
        'Conflict Company',
        NULL,
        NULL,
        'conflict@example.com',
        NULL,
        '{"event_type":"deal.won","crm":{}}'::jsonb
    );

    SELECT count(*)
    INTO v_event_count_after
    FROM onboarding_events
    WHERE case_id = v_context.case_id;

    IF v_result.database_outcome <> 'source_identity_conflict'
        OR v_result.case_id IS NOT NULL
        OR v_result.correlation_id IS NOT NULL
        OR v_result.should_dispatch_wf02 IS DISTINCT FROM false
        OR v_result.http_status <> 409
        OR v_event_count_after <> v_event_count_before
        OR EXISTS (
            SELECT 1
            FROM onboarding_cases
            WHERE source_system = 'mock_crm'
              AND source_deal_id = v_conflicting_deal_id
        )
    THEN
        RAISE EXCEPTION
            'WF01 source-identity conflict invariants failed: %',
            row_to_json(v_result);
    END IF;

    RAISE NOTICE
        'PASS: source identity conflicts are rejected without business writes';
END;
$$;

DO $$
DECLARE
    v_context wf01_test_context%ROWTYPE;
    v_result record;
BEGIN
    SELECT *
    INTO STRICT v_context
    FROM wf01_test_context
    LIMIT 1;

    UPDATE onboarding_cases
    SET state = 'awaiting_client_data'
    WHERE id = v_context.case_id;

    SELECT *
    INTO STRICT v_result
    FROM process_wf01_intake(
        'mock_crm',
        v_context.source_event_id,
        v_context.source_deal_id,
        'WF01 Test Company',
        'Intake',
        'Tester',
        'wf01-test@example.com',
        '+48000000000',
        '{"event_type":"deal.won","crm":{}}'::jsonb
    );

    IF v_result.case_state <> 'awaiting_client_data'
        OR v_result.should_dispatch_wf02 IS DISTINCT FROM false
    THEN
        RAISE EXCEPTION
            'WF01 did not suppress dispatch for a progressed case: %',
            row_to_json(v_result);
    END IF;

    RAISE NOTICE
        'PASS: a case past created suppresses WF02 dispatch';
END;
$$;

DO $$
DECLARE
    v_suffix text := replace(gen_random_uuid()::text, '-', '');
    v_event_id text;
    v_deal_id text;
    v_result record;
    v_duplicate record;
    v_operation_id uuid;
    v_lease_owner text;
BEGIN
    v_event_id := 'wf01-test-operation-event-' || v_suffix;
    v_deal_id := 'wf01-test-operation-deal-' || v_suffix;

    SELECT *
    INTO STRICT v_result
    FROM process_wf01_intake(
        'mock_crm',
        v_event_id,
        v_deal_id,
        'WF01 Operation Test',
        NULL,
        NULL,
        'operation@example.com',
        NULL,
        '{"event_type":"deal.won","crm":{}}'::jsonb
    );

    v_lease_owner := 'wf01-test-lease-' || v_suffix;

    SELECT claimed.operation_id
    INTO STRICT v_operation_id
    FROM claim_external_operation(
        'wf01-test-operation-' || v_suffix,
        'send_client_data_request',
        v_result.case_id,
        v_lease_owner,
        300,
        5,
        '{}'::jsonb
    ) AS claimed
    WHERE claimed.claim_outcome = 'claimed';

    IF NOT complete_external_operation_success(
        v_operation_id,
        v_lease_owner,
        'wf01-test-message-' || v_suffix,
        '{}'::jsonb
    ) THEN
        RAISE EXCEPTION
            'WF01 test could not complete the successful operation fixture';
    END IF;

    SELECT *
    INTO STRICT v_duplicate
    FROM process_wf01_intake(
        'mock_crm',
        v_event_id,
        v_deal_id,
        'WF01 Operation Test',
        NULL,
        NULL,
        'operation@example.com',
        NULL,
        '{"event_type":"deal.won","crm":{}}'::jsonb
    );

    IF v_duplicate.case_state <> 'created'
        OR v_duplicate.should_dispatch_wf02 IS DISTINCT FROM false
    THEN
        RAISE EXCEPTION
            'WF01 did not suppress dispatch after a successful operation: %',
            row_to_json(v_duplicate);
    END IF;

    RAISE NOTICE
        'PASS: a successful client-data operation suppresses duplicate dispatch';
END;
$$;

DO $$
DECLARE
    v_rejected boolean := false;
BEGIN
    BEGIN
        PERFORM *
        FROM process_wf01_intake(
            'mock_crm',
            '   ',
            'wf01-test-invalid-deal',
            'Invalid Test',
            NULL,
            NULL,
            'invalid@example.com',
            NULL,
            '{"event_type":"deal.won","crm":{}}'::jsonb
        );
    EXCEPTION
        WHEN raise_exception THEN
            v_rejected :=
                position(
                    'source_event_id must not be blank'
                    IN SQLERRM
                ) > 0;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'WF01 database boundary accepted a blank source event ID';
    END IF;

    RAISE NOTICE
        'PASS: PostgreSQL defensive validation rejects invalid identity data';
END;
$$;

ROLLBACK;
