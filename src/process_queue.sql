-- =============================================================================
-- FILE        : src/process_queue.sql
-- MODULE      : Message Processing Engine
-- PURPOSE     : WA_ENGINE_PKG — reads PENDING messages from WA_MESSAGE_QUEUE,
--               calls the UltraMsg API via APEX_WEB_SERVICE, handles HTTP
--               responses, enforces retry logic, and writes full audit logs.
-- AUTHOR      : ENG. Malek Mohammed Al-edresi
-- DATE        : 2026-01-01
-- VERSION     : 2.0
-- DEPENDENCIES: config/api_config.sql, logging/logs.sql, src/send_whatsapp.sql
-- =============================================================================


CREATE OR REPLACE PACKAGE WA_ENGINE_PKG AS
-- ----------------------------------------------------------------------------
-- PACKAGE NAME : WA_ENGINE_PKG
-- PURPOSE      : Core message processing engine for the WhatsApp queue.
--                Reads PENDING messages, calls the UltraMsg REST API,
--                and manages status transitions with retry logic.
-- AUTHOR       : ENG. Malek Mohammed Al-edresi
-- DATE         : 2026-01-01
-- VERSION      : 2.0
-- ----------------------------------------------------------------------------

    -- Main entry point. Called by the DBMS_SCHEDULER job every 5 minutes.
    PROCEDURE PROCESS_QUEUE (
        p_batch_size   IN NUMBER DEFAULT 50,    -- max messages per run
        p_service_name IN VARCHAR2 DEFAULT 'ULTRAMSG_WHATSAPP'
    );

    -- Re-queue FAILED messages that still have remaining retries.
    -- Called automatically by PROCESS_QUEUE; can also be called manually.
    PROCEDURE RESET_FAILED_FOR_RETRY (
        p_service_name IN VARCHAR2 DEFAULT 'ULTRAMSG_WHATSAPP'
    );

    -- Emergency: send a single message immediately, bypassing the queue.
    -- Use sparingly (e.g., from a critical APEX page process).
    PROCEDURE SEND_IMMEDIATE (
        p_message_id   IN NUMBER
    );

END WA_ENGINE_PKG;
/


CREATE OR REPLACE PACKAGE BODY WA_ENGINE_PKG AS

    -- =========================================================================
    -- PRIVATE CONSTANTS
    -- =========================================================================
    C_SERVICE       CONSTANT VARCHAR2(100) := 'ULTRAMSG_WHATSAPP';
    C_SUCCESS_CODE  CONSTANT NUMBER        := 200;


    -- =========================================================================
    -- PRIVATE: Build JSON body for UltraMsg /messages/chat
    -- =========================================================================
    FUNCTION BUILD_JSON_BODY (
        p_token  IN VARCHAR2,
        p_to     IN VARCHAR2,
        p_body   IN CLOB
    ) RETURN CLOB
    IS
        l_safe_body CLOB;
        l_json      CLOB;
    BEGIN
        -- Escape double-quotes and newlines inside the message text
        l_safe_body := REPLACE(REPLACE(p_body, '\', '\\'), '"', '\"');
        l_safe_body := REPLACE(REPLACE(l_safe_body, CHR(13)||CHR(10), '\n'), CHR(10), '\n');

        l_json := '{"token":"'  || p_token || '",'
               || '"to":"'      || p_to    || '",'
               || '"body":"'    || l_safe_body || '"}';

        RETURN l_json;
    END BUILD_JSON_BODY;


    -- =========================================================================
    -- PRIVATE: Dispatch one message row to the UltraMsg API.
    -- Returns the raw API response CLOB.
    -- Raises exceptions on network failure (caller handles retry logic).
    -- =========================================================================
    PROCEDURE DISPATCH_ONE (
        p_msg_rec    IN OUT NOCOPY WA_MESSAGE_QUEUE%ROWTYPE,
        p_config     IN            WA_API_CONFIG%ROWTYPE
    ) IS
        l_full_phone    VARCHAR2(50);
        l_api_url       VARCHAR2(500);
        l_json_body     CLOB;
        l_response      CLOB;
        l_http_status   NUMBER;
        l_start_ts      TIMESTAMP;
        l_duration_ms   NUMBER;
        l_status_str    VARCHAR2(20);
        l_error_msg     VARCHAR2(4000);
    BEGIN
        -- Construct the full E.164 phone number
        l_full_phone := p_config.COUNTRY_CODE || REGEXP_REPLACE(p_msg_rec.PHONE_NUMBER, '[^0-9]', '');

        -- Construct the API endpoint URL
        l_api_url := RTRIM(p_config.API_HOST, '/') || '/'
                  || TRIM(p_config.INSTANCE_ID)
                  || p_config.API_ENDPOINT;

        -- Build the JSON payload
        l_json_body := BUILD_JSON_BODY(
            p_token => p_config.API_TOKEN,
            p_to    => l_full_phone,
            p_body  => p_msg_rec.MESSAGE_BODY
        );

        -- Prepare HTTP headers
        apex_web_service.g_request_headers.DELETE;
        apex_web_service.g_request_headers(1).name  := 'Content-Type';
        apex_web_service.g_request_headers(1).value := 'application/json';

        -- Record start time for latency measurement
        l_start_ts := SYSTIMESTAMP;

        -- Execute REST call
        l_response := apex_web_service.make_rest_request(
            p_url              => l_api_url,
            p_http_method      => 'POST',
            p_body             => l_json_body,
            p_transfer_timeout => p_config.TIMEOUT_SECONDS
        );

        -- Capture HTTP status returned by APEX_WEB_SERVICE
        l_http_status := apex_web_service.g_status_code;

        -- Calculate round-trip latency
        l_duration_ms := ROUND(
            (CAST(SYSTIMESTAMP AS DATE) - CAST(l_start_ts AS DATE)) * 86400 * 1000
        );

        -- Determine outcome
        IF l_http_status = C_SUCCESS_CODE THEN
            l_status_str := 'SUCCESS';
            UPDATE WA_MESSAGE_QUEUE
            SET    STATUS       = 'SENT',
                   SENT_AT      = SYSTIMESTAMP,
                   API_RESPONSE = l_response,
                   UPDATED_DATE = SYSTIMESTAMP
            WHERE  MESSAGE_ID   = p_msg_rec.MESSAGE_ID;
        ELSE
            l_status_str  := 'ERROR';
            l_error_msg   := 'HTTP ' || l_http_status || ': ' || SUBSTR(l_response, 1, 500);

            p_msg_rec.RETRY_COUNT := p_msg_rec.RETRY_COUNT + 1;

            IF p_msg_rec.RETRY_COUNT >= p_msg_rec.MAX_RETRIES THEN
                -- Exceeded max retries — mark as permanently FAILED
                UPDATE WA_MESSAGE_QUEUE
                SET    STATUS       = 'FAILED',
                       RETRY_COUNT  = p_msg_rec.RETRY_COUNT,
                       FAILED_AT    = SYSTIMESTAMP,
                       LAST_ERROR   = SUBSTR(l_error_msg, 1, 4000),
                       API_RESPONSE = l_response,
                       UPDATED_DATE = SYSTIMESTAMP
                WHERE  MESSAGE_ID   = p_msg_rec.MESSAGE_ID;
            ELSE
                -- Still has retries remaining — revert to PENDING for next run
                UPDATE WA_MESSAGE_QUEUE
                SET    STATUS       = 'PENDING',
                       RETRY_COUNT  = p_msg_rec.RETRY_COUNT,
                       LAST_ERROR   = SUBSTR(l_error_msg, 1, 4000),
                       API_RESPONSE = l_response,
                       UPDATED_DATE = SYSTIMESTAMP
                WHERE  MESSAGE_ID   = p_msg_rec.MESSAGE_ID;
            END IF;
        END IF;

        -- Write API call audit record (autonomous transaction)
        WA_LOG_PKG.LOG_API_CALL(
            p_message_id     => p_msg_rec.MESSAGE_ID,
            p_service_name   => C_SERVICE,
            p_phone_number   => l_full_phone,
            p_request_body   => l_json_body,
            p_http_status    => l_http_status,
            p_response_body  => l_response,
            p_status         => l_status_str,
            p_error_message  => l_error_msg,
            p_attempt_number => p_msg_rec.RETRY_COUNT + 1,
            p_duration_ms    => l_duration_ms
        );

        -- Clean up APEX_WEB_SERVICE state
        apex_web_service.clear_request_cookies;
        apex_web_service.clear_request_headers;

    EXCEPTION
        WHEN OTHERS THEN
            -- Network / timeout error — count as a failed attempt
            apex_web_service.clear_request_cookies;
            apex_web_service.clear_request_headers;

            p_msg_rec.RETRY_COUNT := p_msg_rec.RETRY_COUNT + 1;
            l_error_msg := 'dispatch exception: ' || SQLERRM;

            IF p_msg_rec.RETRY_COUNT >= p_msg_rec.MAX_RETRIES THEN
                UPDATE WA_MESSAGE_QUEUE
                SET    STATUS       = 'FAILED',
                       RETRY_COUNT  = p_msg_rec.RETRY_COUNT,
                       FAILED_AT    = SYSTIMESTAMP,
                       LAST_ERROR   = SUBSTR(l_error_msg, 1, 4000),
                       UPDATED_DATE = SYSTIMESTAMP
                WHERE  MESSAGE_ID   = p_msg_rec.MESSAGE_ID;
            ELSE
                UPDATE WA_MESSAGE_QUEUE
                SET    STATUS       = 'PENDING',
                       RETRY_COUNT  = p_msg_rec.RETRY_COUNT,
                       LAST_ERROR   = SUBSTR(l_error_msg, 1, 4000),
                       UPDATED_DATE = SYSTIMESTAMP
                WHERE  MESSAGE_ID   = p_msg_rec.MESSAGE_ID;
            END IF;

            WA_LOG_PKG.LOG_API_CALL(
                p_message_id     => p_msg_rec.MESSAGE_ID,
                p_service_name   => C_SERVICE,
                p_phone_number   => p_msg_rec.PHONE_NUMBER,
                p_request_body   => NULL,
                p_http_status    => NULL,
                p_response_body  => NULL,
                p_status         => 'ERROR',
                p_error_message  => SUBSTR(l_error_msg, 1, 4000),
                p_attempt_number => p_msg_rec.RETRY_COUNT
            );

            WA_LOG_PKG.LOG_ENGINE_ERROR(
                p_source_module => 'WA_ENGINE_PKG.DISPATCH_ONE [MSG_ID=' || p_msg_rec.MESSAGE_ID || ']',
                p_error_code    => SQLCODE,
                p_error_message => SQLERRM,
                p_stack_trace   => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
    END DISPATCH_ONE;


    -- =========================================================================
    -- PUBLIC: PROCESS_QUEUE
    -- =========================================================================
    PROCEDURE PROCESS_QUEUE (
        p_batch_size   IN NUMBER DEFAULT 50,
        p_service_name IN VARCHAR2 DEFAULT 'ULTRAMSG_WHATSAPP'
    ) IS
        l_config        WA_API_CONFIG%ROWTYPE;
        l_msg_rec       WA_MESSAGE_QUEUE%ROWTYPE;
        l_processed     NUMBER := 0;
        l_sent          NUMBER := 0;
        l_failed        NUMBER := 0;

        CURSOR c_pending IS
            SELECT *
            FROM   WA_MESSAGE_QUEUE
            WHERE  STATUS        = 'PENDING'
            AND    SCHEDULED_AT <= SYSTIMESTAMP
            ORDER BY PRIORITY ASC, CREATED_DATE ASC
            FETCH FIRST p_batch_size ROWS ONLY
            FOR UPDATE SKIP LOCKED;         -- safe for concurrent scheduler runs
    BEGIN
        -- Load API configuration once per batch run
        l_config := WA_GET_API_CONFIG(p_service_name);

        -- Mark eligible rows as PROCESSING to prevent double-processing
        UPDATE WA_MESSAGE_QUEUE q
        SET    q.STATUS       = 'PROCESSING',
               q.UPDATED_DATE = SYSTIMESTAMP
        WHERE  q.MESSAGE_ID IN (
            SELECT MESSAGE_ID
            FROM   WA_MESSAGE_QUEUE
            WHERE  STATUS       = 'PENDING'
            AND    SCHEDULED_AT <= SYSTIMESTAMP
            ORDER BY PRIORITY ASC, CREATED_DATE ASC
            FETCH FIRST p_batch_size ROWS ONLY
        );
        COMMIT;

        -- Process each PROCESSING message
        FOR r IN (
            SELECT *
            FROM   WA_MESSAGE_QUEUE
            WHERE  STATUS = 'PROCESSING'
            ORDER  BY PRIORITY ASC, CREATED_DATE ASC
            FETCH  FIRST p_batch_size ROWS ONLY
        ) LOOP
            l_msg_rec := r;

            BEGIN
                SAVEPOINT sp_msg;
                DISPATCH_ONE(l_msg_rec, l_config);
                COMMIT;
                l_processed := l_processed + 1;

                IF l_msg_rec.STATUS = 'SENT' THEN
                    l_sent := l_sent + 1;
                ELSE
                    l_failed := l_failed + 1;
                END IF;

            EXCEPTION
                WHEN OTHERS THEN
                    ROLLBACK TO sp_msg;
                    -- Failsafe: reset stuck PROCESSING record back to PENDING
                    BEGIN
                        UPDATE WA_MESSAGE_QUEUE
                        SET    STATUS       = 'PENDING',
                               LAST_ERROR   = SUBSTR('Engine loop error: ' || SQLERRM, 1, 4000),
                               UPDATED_DATE = SYSTIMESTAMP
                        WHERE  MESSAGE_ID   = l_msg_rec.MESSAGE_ID;
                        COMMIT;
                    EXCEPTION
                        WHEN OTHERS THEN NULL;
                    END;

                    WA_LOG_PKG.LOG_ENGINE_ERROR(
                        p_source_module => 'WA_ENGINE_PKG.PROCESS_QUEUE.LOOP',
                        p_error_code    => SQLCODE,
                        p_error_message => SQLERRM,
                        p_stack_trace   => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
                    );
            END;
        END LOOP;

        -- Log a summary of this engine run into the engine error log
        -- (using INFO-style entry — error_code NULL, error_message = summary)
        WA_LOG_PKG.LOG_ENGINE_ERROR(
            p_source_module => 'WA_ENGINE_PKG.PROCESS_QUEUE',
            p_error_code    => NULL,
            p_error_message => 'Batch complete. Processed=' || l_processed
                             || ' Sent=' || l_sent
                             || ' Failed=' || l_failed
        );

    EXCEPTION
        WHEN OTHERS THEN
            WA_LOG_PKG.LOG_ENGINE_ERROR(
                p_source_module => 'WA_ENGINE_PKG.PROCESS_QUEUE',
                p_error_code    => SQLCODE,
                p_error_message => 'Fatal error in PROCESS_QUEUE: ' || SQLERRM,
                p_stack_trace   => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
            RAISE;
    END PROCESS_QUEUE;


    -- =========================================================================
    -- PUBLIC: RESET_FAILED_FOR_RETRY
    -- Resets FAILED messages that still have retries remaining back to PENDING.
    -- =========================================================================
    PROCEDURE RESET_FAILED_FOR_RETRY (
        p_service_name IN VARCHAR2 DEFAULT 'ULTRAMSG_WHATSAPP'
    ) IS
    BEGIN
        UPDATE WA_MESSAGE_QUEUE
        SET    STATUS       = 'PENDING',
               LAST_ERROR   = NULL,
               UPDATED_DATE = SYSTIMESTAMP
        WHERE  STATUS       = 'FAILED'
        AND    RETRY_COUNT  < MAX_RETRIES;

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            WA_LOG_PKG.LOG_ENGINE_ERROR(
                p_source_module => 'WA_ENGINE_PKG.RESET_FAILED_FOR_RETRY',
                p_error_code    => SQLCODE,
                p_error_message => SQLERRM,
                p_stack_trace   => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
            RAISE;
    END RESET_FAILED_FOR_RETRY;


    -- =========================================================================
    -- PUBLIC: SEND_IMMEDIATE
    -- Directly dispatches one queued message without waiting for the scheduler.
    -- =========================================================================
    PROCEDURE SEND_IMMEDIATE (
        p_message_id IN NUMBER
    ) IS
        l_msg_rec   WA_MESSAGE_QUEUE%ROWTYPE;
        l_config    WA_API_CONFIG%ROWTYPE;
    BEGIN
        SELECT * INTO l_msg_rec
        FROM   WA_MESSAGE_QUEUE
        WHERE  MESSAGE_ID = p_message_id;

        l_config := WA_GET_API_CONFIG(C_SERVICE);

        UPDATE WA_MESSAGE_QUEUE
        SET    STATUS = 'PROCESSING', UPDATED_DATE = SYSTIMESTAMP
        WHERE  MESSAGE_ID = p_message_id;
        COMMIT;

        DISPATCH_ONE(l_msg_rec, l_config);
        COMMIT;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20030, 'SEND_IMMEDIATE: MESSAGE_ID ' || p_message_id || ' not found.');
        WHEN OTHERS THEN
            ROLLBACK;
            WA_LOG_PKG.LOG_ENGINE_ERROR(
                p_source_module => 'WA_ENGINE_PKG.SEND_IMMEDIATE',
                p_error_code    => SQLCODE,
                p_error_message => SQLERRM,
                p_stack_trace   => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
            RAISE;
    END SEND_IMMEDIATE;

END WA_ENGINE_PKG;
/

SHOW ERRORS PACKAGE      WA_ENGINE_PKG;
SHOW ERRORS PACKAGE BODY WA_ENGINE_PKG;
