-- =============================================================================
-- FILE        : logging/logs.sql
-- MODULE      : Logging System
-- PURPOSE     : Creates the API call log table and the package used by
--               all engine components to record every outbound request,
--               its HTTP response, and any application-level errors.
-- AUTHOR      : ENG. Malek Mohammed Al-edresi
-- DATE        : 2026-01-01
-- VERSION     : 2.0
-- =============================================================================


-- -----------------------------------------------------------------------------
-- TABLE: WA_API_LOG
-- Stores one row per API call attempt, including request payload, HTTP status
-- code, raw response body, and error details where applicable.
-- -----------------------------------------------------------------------------
CREATE TABLE WA_API_LOG (
    LOG_ID          NUMBER          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    MESSAGE_ID      NUMBER,                         -- FK to WA_MESSAGE_QUEUE
    SERVICE_NAME    VARCHAR2(100),
    PHONE_NUMBER    VARCHAR2(30),
    REQUEST_BODY    CLOB,
    HTTP_STATUS     NUMBER(5),
    RESPONSE_BODY   CLOB,
    STATUS          VARCHAR2(20)    NOT NULL        -- SUCCESS | ERROR | TIMEOUT
                        CHECK (STATUS IN ('SUCCESS', 'ERROR', 'TIMEOUT')),
    ERROR_CODE      VARCHAR2(50),
    ERROR_MESSAGE   VARCHAR2(4000),
    ATTEMPT_NUMBER  NUMBER(2)       DEFAULT 1,
    DURATION_MS     NUMBER(10),                     -- round-trip milliseconds
    LOGGED_BY       VARCHAR2(100)   DEFAULT 'SYSTEM',
    LOG_DATE        TIMESTAMP       DEFAULT SYSTIMESTAMP
);

COMMENT ON TABLE  WA_API_LOG IS 'Audit log for every outbound UltraMsg API call made by the messaging engine.';
COMMENT ON COLUMN WA_API_LOG.LOG_ID         IS 'Surrogate primary key.';
COMMENT ON COLUMN WA_API_LOG.MESSAGE_ID     IS 'References WA_MESSAGE_QUEUE.MESSAGE_ID — the originating queued message.';
COMMENT ON COLUMN WA_API_LOG.HTTP_STATUS    IS 'HTTP response status code returned by UltraMsg (200, 400, 401, 429, 500, …).';
COMMENT ON COLUMN WA_API_LOG.DURATION_MS   IS 'Time elapsed from request dispatch to response receipt in milliseconds.';
COMMENT ON COLUMN WA_API_LOG.STATUS         IS 'SUCCESS = 2xx from API; ERROR = non-2xx or exception; TIMEOUT = request timed out.';


-- -----------------------------------------------------------------------------
-- TABLE: WA_ENGINE_ERROR_LOG
-- Captures unexpected engine-level exceptions (not API call failures).
-- These represent bugs, configuration problems, or DBA-level issues.
-- -----------------------------------------------------------------------------
CREATE TABLE WA_ENGINE_ERROR_LOG (
    ERROR_LOG_ID    NUMBER          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    SOURCE_MODULE   VARCHAR2(200)   NOT NULL,
    ERROR_CODE      VARCHAR2(50),
    ERROR_MESSAGE   VARCHAR2(4000)  NOT NULL,
    STACK_TRACE     CLOB,
    SESSION_USER    VARCHAR2(100)   DEFAULT SYS_CONTEXT('USERENV', 'SESSION_USER'),
    OS_USER         VARCHAR2(100)   DEFAULT SYS_CONTEXT('USERENV', 'OS_USER'),
    LOG_DATE        TIMESTAMP       DEFAULT SYSTIMESTAMP
);

COMMENT ON TABLE WA_ENGINE_ERROR_LOG IS 'Captures unexpected PL/SQL engine-level errors separate from individual API call failures.';


-- -----------------------------------------------------------------------------
-- INDEXES: Support common reporting and queue-processing queries
-- -----------------------------------------------------------------------------
CREATE INDEX IDX_WA_API_LOG_MSG_ID   ON WA_API_LOG (MESSAGE_ID);
CREATE INDEX IDX_WA_API_LOG_DATE     ON WA_API_LOG (LOG_DATE DESC);
CREATE INDEX IDX_WA_ENG_ERR_DATE     ON WA_ENGINE_ERROR_LOG (LOG_DATE DESC);


-- -----------------------------------------------------------------------------
-- PACKAGE: WA_LOG_PKG
-- Centralised logging API. All engine components call only this package;
-- direct DML against the log tables is prohibited from application code.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE WA_LOG_PKG AS
-- ----------------------------------------------------------------------------
-- PACKAGE NAME : WA_LOG_PKG
-- PURPOSE      : Provides logging utilities for the WhatsApp messaging engine.
-- AUTHOR       : ENG. Malek Mohammed Al-edresi
-- DATE         : 2026-01-01
-- VERSION      : 2.0
-- ----------------------------------------------------------------------------

    -- Log a single API call attempt
    PROCEDURE LOG_API_CALL (
        p_message_id     IN NUMBER,
        p_service_name   IN VARCHAR2,
        p_phone_number   IN VARCHAR2,
        p_request_body   IN CLOB,
        p_http_status    IN NUMBER,
        p_response_body  IN CLOB,
        p_status         IN VARCHAR2,   -- SUCCESS | ERROR | TIMEOUT
        p_error_code     IN VARCHAR2    DEFAULT NULL,
        p_error_message  IN VARCHAR2    DEFAULT NULL,
        p_attempt_number IN NUMBER      DEFAULT 1,
        p_duration_ms    IN NUMBER      DEFAULT NULL,
        p_logged_by      IN VARCHAR2    DEFAULT 'SYSTEM'
    );

    -- Log an unexpected engine-level exception
    PROCEDURE LOG_ENGINE_ERROR (
        p_source_module  IN VARCHAR2,
        p_error_code     IN VARCHAR2    DEFAULT NULL,
        p_error_message  IN VARCHAR2,
        p_stack_trace    IN CLOB        DEFAULT NULL
    );

END WA_LOG_PKG;
/

CREATE OR REPLACE PACKAGE BODY WA_LOG_PKG AS

    PROCEDURE LOG_API_CALL (
        p_message_id     IN NUMBER,
        p_service_name   IN VARCHAR2,
        p_phone_number   IN VARCHAR2,
        p_request_body   IN CLOB,
        p_http_status    IN NUMBER,
        p_response_body  IN CLOB,
        p_status         IN VARCHAR2,
        p_error_code     IN VARCHAR2    DEFAULT NULL,
        p_error_message  IN VARCHAR2    DEFAULT NULL,
        p_attempt_number IN NUMBER      DEFAULT 1,
        p_duration_ms    IN NUMBER      DEFAULT NULL,
        p_logged_by      IN VARCHAR2    DEFAULT 'SYSTEM'
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO WA_API_LOG (
            MESSAGE_ID, SERVICE_NAME, PHONE_NUMBER, REQUEST_BODY,
            HTTP_STATUS, RESPONSE_BODY, STATUS, ERROR_CODE,
            ERROR_MESSAGE, ATTEMPT_NUMBER, DURATION_MS, LOGGED_BY
        ) VALUES (
            p_message_id, p_service_name, p_phone_number, p_request_body,
            p_http_status, p_response_body, p_status, p_error_code,
            p_error_message, p_attempt_number, p_duration_ms, p_logged_by
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            -- Never let log failure crash the main transaction
            ROLLBACK;
    END LOG_API_CALL;


    PROCEDURE LOG_ENGINE_ERROR (
        p_source_module  IN VARCHAR2,
        p_error_code     IN VARCHAR2    DEFAULT NULL,
        p_error_message  IN VARCHAR2,
        p_stack_trace    IN CLOB        DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO WA_ENGINE_ERROR_LOG (
            SOURCE_MODULE, ERROR_CODE, ERROR_MESSAGE, STACK_TRACE
        ) VALUES (
            p_source_module, p_error_code, SUBSTR(p_error_message, 1, 4000), p_stack_trace
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
    END LOG_ENGINE_ERROR;

END WA_LOG_PKG;
/

SHOW ERRORS PACKAGE      WA_LOG_PKG;
SHOW ERRORS PACKAGE BODY WA_LOG_PKG;
