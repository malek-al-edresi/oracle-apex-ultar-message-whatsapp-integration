-- =============================================================================
-- FILE        : src/send_whatsapp.sql
-- MODULE      : Messaging Queue System + APEX Integration Entry Point
-- PURPOSE     : Creates the WA_MESSAGE_QUEUE table and the WA_MSG_PKG package.
--               WA_MSG_PKG.ENQUEUE is the single public entry point called from
--               Oracle APEX buttons, process actions, or any PL/SQL context.
-- AUTHOR      : ENG. Malek Mohammed Al-edresi
-- DATE        : 2026-01-01
-- VERSION     : 2.0
-- DEPENDENCIES: config/api_config.sql, logging/logs.sql (run those first)
-- =============================================================================


-- -----------------------------------------------------------------------------
-- TABLE: WA_MESSAGE_QUEUE
-- Central queue table. Every outbound WhatsApp message passes through here.
-- The processing engine reads PENDING rows; the scheduler drives the engine.
-- -----------------------------------------------------------------------------
CREATE TABLE WA_MESSAGE_QUEUE (
    MESSAGE_ID       NUMBER          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    PHONE_NUMBER     VARCHAR2(30)    NOT NULL,
    MESSAGE_BODY     CLOB            NOT NULL,
    STATUS           VARCHAR2(20)    DEFAULT 'PENDING'  NOT NULL
                         CHECK (STATUS IN ('PENDING', 'PROCESSING', 'SENT', 'FAILED')),
    RETRY_COUNT      NUMBER(2)       DEFAULT 0          NOT NULL,
    MAX_RETRIES      NUMBER(2)       DEFAULT 3          NOT NULL,
    PRIORITY         NUMBER(2)       DEFAULT 5          NOT NULL, -- 1 = highest
    MESSAGE_TYPE     VARCHAR2(50)    DEFAULT 'GENERAL', -- OTP | NOTIFICATION | ALERT | GENERAL
    REFERENCE_ID     VARCHAR2(200),                     -- caller's correlation key
    REFERENCE_TYPE   VARCHAR2(100),                     -- e.g., ORDER_ID, USER_ID
    SCHEDULED_AT     TIMESTAMP       DEFAULT SYSTIMESTAMP,
    SENT_AT          TIMESTAMP,
    FAILED_AT        TIMESTAMP,
    LAST_ERROR       VARCHAR2(4000),
    API_RESPONSE     CLOB,
    CREATED_BY       VARCHAR2(100)   DEFAULT NVL(SYS_CONTEXT('APEX$SESSION','APP_USER'), SYS_CONTEXT('USERENV','SESSION_USER')),
    CREATED_DATE     TIMESTAMP       DEFAULT SYSTIMESTAMP,
    UPDATED_DATE     TIMESTAMP
);

COMMENT ON TABLE  WA_MESSAGE_QUEUE IS 'Central message queue for all outbound WhatsApp messages. Status lifecycle: PENDING -> PROCESSING -> SENT | FAILED.';
COMMENT ON COLUMN WA_MESSAGE_QUEUE.STATUS         IS 'Lifecycle status: PENDING=awaiting dispatch; PROCESSING=in flight; SENT=delivered; FAILED=exceeded retries.';
COMMENT ON COLUMN WA_MESSAGE_QUEUE.RETRY_COUNT    IS 'Number of delivery attempts made so far.';
COMMENT ON COLUMN WA_MESSAGE_QUEUE.PRIORITY       IS 'Processing priority: 1 (urgent) to 10 (low). The engine processes lower numbers first.';
COMMENT ON COLUMN WA_MESSAGE_QUEUE.MESSAGE_TYPE   IS 'Logical category: OTP, NOTIFICATION, ALERT, or GENERAL.';
COMMENT ON COLUMN WA_MESSAGE_QUEUE.REFERENCE_ID   IS 'Caller-supplied correlation key (e.g., order number, user ID) for traceability.';
COMMENT ON COLUMN WA_MESSAGE_QUEUE.SCHEDULED_AT   IS 'Earliest date-time the message may be dispatched.';


-- -----------------------------------------------------------------------------
-- INDEXES: Optimise queue-reader queries and reporting
-- -----------------------------------------------------------------------------
CREATE INDEX IDX_WA_MQ_STATUS_PRIO ON WA_MESSAGE_QUEUE (STATUS, PRIORITY, SCHEDULED_AT);
CREATE INDEX IDX_WA_MQ_PHONE       ON WA_MESSAGE_QUEUE (PHONE_NUMBER);
CREATE INDEX IDX_WA_MQ_REF         ON WA_MESSAGE_QUEUE (REFERENCE_ID, REFERENCE_TYPE);
CREATE INDEX IDX_WA_MQ_CREATED     ON WA_MESSAGE_QUEUE (CREATED_DATE DESC);


-- -----------------------------------------------------------------------------
-- PACKAGE: WA_MSG_PKG
-- Public interface for all message enqueue operations.
-- Application code must only call ENQUEUE; internal engine calls are routed
-- through WA_ENGINE_PKG (defined in process_queue.sql).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE WA_MSG_PKG AS
-- ----------------------------------------------------------------------------
-- PACKAGE NAME : WA_MSG_PKG
-- PURPOSE      : Provides ENQUEUE procedures to insert messages into the
--                WA_MESSAGE_QUEUE from Oracle APEX or any PL/SQL caller.
-- AUTHOR       : ENG. Malek Mohammed Al-edresi
-- DATE         : 2026-01-01
-- VERSION      : 2.0
-- ----------------------------------------------------------------------------

    -- Generic enqueue (supports all message types)
    PROCEDURE ENQUEUE (
        p_phone_number   IN VARCHAR2,
        p_message_body   IN CLOB,
        p_message_type   IN VARCHAR2    DEFAULT 'GENERAL',
        p_priority       IN NUMBER      DEFAULT 5,
        p_reference_id   IN VARCHAR2    DEFAULT NULL,
        p_reference_type IN VARCHAR2    DEFAULT NULL,
        p_scheduled_at   IN TIMESTAMP   DEFAULT SYSTIMESTAMP,
        p_created_by     IN VARCHAR2    DEFAULT NULL,
        p_message_id    OUT NUMBER
    );

    -- Convenience: OTP message (priority 1 — urgent)
    PROCEDURE ENQUEUE_OTP (
        p_phone_number   IN VARCHAR2,
        p_otp_code       IN VARCHAR2,
        p_app_name       IN VARCHAR2    DEFAULT 'System',
        p_reference_id   IN VARCHAR2    DEFAULT NULL,
        p_message_id    OUT NUMBER
    );

    -- Convenience: System notification
    PROCEDURE ENQUEUE_NOTIFICATION (
        p_phone_number   IN VARCHAR2,
        p_message_body   IN CLOB,
        p_reference_id   IN VARCHAR2    DEFAULT NULL,
        p_message_id    OUT NUMBER
    );

    -- Convenience: Critical alert (priority 1)
    PROCEDURE ENQUEUE_ALERT (
        p_phone_number   IN VARCHAR2,
        p_alert_message  IN CLOB,
        p_reference_id   IN VARCHAR2    DEFAULT NULL,
        p_message_id    OUT NUMBER
    );

END WA_MSG_PKG;
/


CREATE OR REPLACE PACKAGE BODY WA_MSG_PKG AS

    -- -------------------------------------------------------------------------
    -- Internal helper: resolves caller identity from APEX session or DB session
    -- -------------------------------------------------------------------------
    FUNCTION RESOLVE_USER (p_override IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_override IS NOT NULL THEN
            RETURN p_override;
        END IF;
        RETURN NVL(
            SYS_CONTEXT('APEX$SESSION', 'APP_USER'),
            SYS_CONTEXT('USERENV', 'SESSION_USER')
        );
    END RESOLVE_USER;


    -- -------------------------------------------------------------------------
    PROCEDURE ENQUEUE (
        p_phone_number   IN VARCHAR2,
        p_message_body   IN CLOB,
        p_message_type   IN VARCHAR2    DEFAULT 'GENERAL',
        p_priority       IN NUMBER      DEFAULT 5,
        p_reference_id   IN VARCHAR2    DEFAULT NULL,
        p_reference_type IN VARCHAR2    DEFAULT NULL,
        p_scheduled_at   IN TIMESTAMP   DEFAULT SYSTIMESTAMP,
        p_created_by     IN VARCHAR2    DEFAULT NULL,
        p_message_id    OUT NUMBER
    ) IS
    BEGIN
        -- Basic input validation
        IF p_phone_number IS NULL OR TRIM(p_phone_number) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20010, 'WA_MSG_PKG.ENQUEUE: p_phone_number cannot be NULL.');
        END IF;
        IF p_message_body IS NULL OR DBMS_LOB.GETLENGTH(p_message_body) = 0 THEN
            RAISE_APPLICATION_ERROR(-20011, 'WA_MSG_PKG.ENQUEUE: p_message_body cannot be NULL or empty.');
        END IF;

        INSERT INTO WA_MESSAGE_QUEUE (
            PHONE_NUMBER, MESSAGE_BODY, STATUS, MESSAGE_TYPE,
            PRIORITY, REFERENCE_ID, REFERENCE_TYPE, SCHEDULED_AT, CREATED_BY
        ) VALUES (
            TRIM(p_phone_number), p_message_body, 'PENDING', UPPER(p_message_type),
            NVL(p_priority, 5), p_reference_id, p_reference_type,
            NVL(p_scheduled_at, SYSTIMESTAMP), RESOLVE_USER(p_created_by)
        )
        RETURNING MESSAGE_ID INTO p_message_id;

    EXCEPTION
        WHEN OTHERS THEN
            WA_LOG_PKG.LOG_ENGINE_ERROR(
                p_source_module => 'WA_MSG_PKG.ENQUEUE',
                p_error_code    => SQLCODE,
                p_error_message => SQLERRM,
                p_stack_trace   => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
            RAISE;
    END ENQUEUE;


    -- -------------------------------------------------------------------------
    PROCEDURE ENQUEUE_OTP (
        p_phone_number   IN VARCHAR2,
        p_otp_code       IN VARCHAR2,
        p_app_name       IN VARCHAR2    DEFAULT 'System',
        p_reference_id   IN VARCHAR2    DEFAULT NULL,
        p_message_id    OUT NUMBER
    ) IS
        l_body CLOB;
    BEGIN
        l_body := 'Your ' || p_app_name || ' verification code is: *' || p_otp_code ||
                  '*. This code expires in 10 minutes. Do not share it with anyone.';

        ENQUEUE(
            p_phone_number   => p_phone_number,
            p_message_body   => l_body,
            p_message_type   => 'OTP',
            p_priority       => 1,             -- highest priority
            p_reference_id   => p_reference_id,
            p_reference_type => 'OTP',
            p_message_id     => p_message_id
        );
    END ENQUEUE_OTP;


    -- -------------------------------------------------------------------------
    PROCEDURE ENQUEUE_NOTIFICATION (
        p_phone_number   IN VARCHAR2,
        p_message_body   IN CLOB,
        p_reference_id   IN VARCHAR2    DEFAULT NULL,
        p_message_id    OUT NUMBER
    ) IS
    BEGIN
        ENQUEUE(
            p_phone_number   => p_phone_number,
            p_message_body   => p_message_body,
            p_message_type   => 'NOTIFICATION',
            p_priority       => 3,
            p_reference_id   => p_reference_id,
            p_reference_type => 'NOTIFICATION',
            p_message_id     => p_message_id
        );
    END ENQUEUE_NOTIFICATION;


    -- -------------------------------------------------------------------------
    PROCEDURE ENQUEUE_ALERT (
        p_phone_number   IN VARCHAR2,
        p_alert_message  IN CLOB,
        p_reference_id   IN VARCHAR2    DEFAULT NULL,
        p_message_id    OUT NUMBER
    ) IS
    BEGIN
        ENQUEUE(
            p_phone_number   => p_phone_number,
            p_message_body   => p_alert_message,
            p_message_type   => 'ALERT',
            p_priority       => 1,
            p_reference_id   => p_reference_id,
            p_reference_type => 'ALERT',
            p_message_id     => p_message_id
        );
    END ENQUEUE_ALERT;

END WA_MSG_PKG;
/

SHOW ERRORS PACKAGE      WA_MSG_PKG;
SHOW ERRORS PACKAGE BODY WA_MSG_PKG;


-- =============================================================================
-- APEX INTEGRATION WRAPPER
-- Callable directly from an APEX button Process (PL/SQL Code block).
--
-- Example APEX Process code:
--   DECLARE
--     l_msg_id NUMBER;
--   BEGIN
--     WA_APEX_SEND(
--       p_phone   => :P1_PHONE,
--       p_message => :P1_MESSAGE,
--       p_type    => 'GENERAL',
--       p_out_msg_id => :P1_MESSAGE_ID
--     );
--   END;
-- =============================================================================
CREATE OR REPLACE PROCEDURE WA_APEX_SEND (
    p_phone      IN  VARCHAR2,
    p_message    IN  CLOB,
    p_type       IN  VARCHAR2   DEFAULT 'GENERAL',
    p_ref_id     IN  VARCHAR2   DEFAULT NULL,
    p_out_msg_id OUT NUMBER
)
-- ----------------------------------------------------------------------------
-- PROCEDURE NAME : WA_APEX_SEND
-- PURPOSE        : Thin APEX-facing wrapper over WA_MSG_PKG.ENQUEUE.
--                  Intended for use in APEX page processes and dynamic actions.
-- PARAMETERS     : p_phone      - Destination WhatsApp number (digits only)
--                  p_message    - Message text (supports unicode and newlines)
--                  p_type       - OTP | NOTIFICATION | ALERT | GENERAL
--                  p_ref_id     - Optional caller correlation key
--                  p_out_msg_id - Returns the generated MESSAGE_ID (bind to APEX item)
-- AUTHOR         : ENG. Malek Mohammed Al-edresi
-- DATE           : 2026-01-01
-- VERSION        : 2.0
-- ----------------------------------------------------------------------------
IS
    l_priority NUMBER := 5;
BEGIN
    -- Derive priority from message type
    IF UPPER(p_type) IN ('OTP', 'ALERT') THEN
        l_priority := 1;
    ELSIF UPPER(p_type) = 'NOTIFICATION' THEN
        l_priority := 3;
    END IF;

    WA_MSG_PKG.ENQUEUE(
        p_phone_number   => p_phone,
        p_message_body   => p_message,
        p_message_type   => NVL(UPPER(p_type), 'GENERAL'),
        p_priority       => l_priority,
        p_reference_id   => p_ref_id,
        p_reference_type => UPPER(p_type),
        p_created_by     => NVL(SYS_CONTEXT('APEX$SESSION','APP_USER'), 'APEX'),
        p_message_id     => p_out_msg_id
    );

EXCEPTION
    WHEN OTHERS THEN
        WA_LOG_PKG.LOG_ENGINE_ERROR(
            p_source_module => 'WA_APEX_SEND',
            p_error_code    => SQLCODE,
            p_error_message => SQLERRM,
            p_stack_trace   => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
        );
        RAISE_APPLICATION_ERROR(-20020, 'Failed to enqueue message: ' || SQLERRM);
END WA_APEX_SEND;
/

SHOW ERRORS PROCEDURE WA_APEX_SEND;
