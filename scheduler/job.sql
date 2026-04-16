-- =============================================================================
-- FILE        : scheduler/job.sql
-- MODULE      : Scheduler Automation
-- PURPOSE     : Creates the DBMS_SCHEDULER program, schedule, and job that
--               drive the WhatsApp message processing engine every 5 minutes.
--               Also provides helper procedures for manual control.
-- AUTHOR      : ENG. Malek Mohammed Al-edresi
-- DATE        : 2026-01-01
-- VERSION     : 2.0
-- DEPENDENCIES: src/process_queue.sql (WA_ENGINE_PKG must exist)
-- PRIVILEGES  : Requires CREATE JOB or DBA role to execute.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- STEP 1: Create a named PROGRAM pointing to the engine entry point
-- -----------------------------------------------------------------------------
BEGIN
    DBMS_SCHEDULER.CREATE_PROGRAM (
        program_name        => 'WA_PROCESS_QUEUE_PROG',
        program_type        => 'STORED_PROCEDURE',
        program_action      => 'WA_ENGINE_PKG.PROCESS_QUEUE',
        number_of_arguments => 0,
        comments            => 'WhatsApp engine: reads PENDING queue and dispatches messages via UltraMsg API.',
        enabled             => TRUE
    );
END;
/


-- -----------------------------------------------------------------------------
-- STEP 2: Create a named SCHEDULE (every 5 minutes, indefinite)
-- -----------------------------------------------------------------------------
BEGIN
    DBMS_SCHEDULER.CREATE_SCHEDULE (
        schedule_name   => 'WA_EVERY_5_MIN_SCHED',
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=5',
        comments        => 'Fires every 5 minutes. Used by the WhatsApp message processing job.'
    );
END;
/


-- -----------------------------------------------------------------------------
-- STEP 3: Create the JOB binding program + schedule
-- -----------------------------------------------------------------------------
BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name            => 'WA_MSG_PROCESSOR_JOB',
        program_name        => 'WA_PROCESS_QUEUE_PROG',
        schedule_name       => 'WA_EVERY_5_MIN_SCHED',
        job_class           => 'DEFAULT_JOB_CLASS',
        enabled             => FALSE,           -- enable explicitly after testing
        auto_drop           => FALSE,
        restartable         => TRUE,
        comments            => 'Main WhatsApp queue processor. Runs WA_ENGINE_PKG.PROCESS_QUEUE every 5 minutes.'
    );
END;
/


-- -----------------------------------------------------------------------------
-- STEP 4: Configure job logging and attributes
-- -----------------------------------------------------------------------------
BEGIN
    DBMS_SCHEDULER.SET_ATTRIBUTE(
        name      => 'WA_MSG_PROCESSOR_JOB',
        attribute => 'logging_level',
        value     => DBMS_SCHEDULER.LOGGING_FULL
    );

    DBMS_SCHEDULER.SET_ATTRIBUTE(
        name      => 'WA_MSG_PROCESSOR_JOB',
        attribute => 'max_failures',
        value     => 5          -- stop job after 5 consecutive failures
    );

    DBMS_SCHEDULER.SET_ATTRIBUTE(
        name      => 'WA_MSG_PROCESSOR_JOB',
        attribute => 'max_run_duration',
        value     => INTERVAL '4' MINUTE  -- kill run if it exceeds 4 minutes
    );
END;
/


-- -----------------------------------------------------------------------------
-- STEP 5: Enable the job (uncomment when ready for production)
-- -----------------------------------------------------------------------------
-- BEGIN
--     DBMS_SCHEDULER.ENABLE('WA_MSG_PROCESSOR_JOB');
-- END;
-- /


-- =============================================================================
-- HELPER PROCEDURES — operational control without touching the scheduler UI
-- =============================================================================

CREATE OR REPLACE PROCEDURE WA_SCHEDULER_CONTROL (
    p_action IN VARCHAR2   -- START | STOP | RUN_NOW | STATUS
)
-- ----------------------------------------------------------------------------
-- PROCEDURE NAME : WA_SCHEDULER_CONTROL
-- PURPOSE        : Provides a single-call interface for enabling, disabling,
--                  or immediately running the WA_MSG_PROCESSOR_JOB.
-- PARAMETERS     : p_action - START    => enable the job
--                             STOP     => disable the job
--                             RUN_NOW  => run immediately (one-off)
--                             STATUS   => prints current job state to DBMS_OUTPUT
-- AUTHOR         : ENG. Malek Mohammed Al-edresi
-- DATE           : 2026-01-01
-- VERSION        : 2.0
-- ----------------------------------------------------------------------------
IS
    l_state   USER_SCHEDULER_JOBS.STATE%TYPE;
    l_enabled USER_SCHEDULER_JOBS.ENABLED%TYPE;
BEGIN
    CASE UPPER(TRIM(p_action))
        WHEN 'START' THEN
            DBMS_SCHEDULER.ENABLE('WA_MSG_PROCESSOR_JOB');
            DBMS_OUTPUT.PUT_LINE('WA_MSG_PROCESSOR_JOB => ENABLED');

        WHEN 'STOP' THEN
            DBMS_SCHEDULER.DISABLE('WA_MSG_PROCESSOR_JOB', FORCE => TRUE);
            DBMS_OUTPUT.PUT_LINE('WA_MSG_PROCESSOR_JOB => DISABLED');

        WHEN 'RUN_NOW' THEN
            DBMS_SCHEDULER.RUN_JOB(
                job_name            => 'WA_MSG_PROCESSOR_JOB',
                use_current_session => FALSE
            );
            DBMS_OUTPUT.PUT_LINE('WA_MSG_PROCESSOR_JOB => Triggered for immediate execution.');

        WHEN 'STATUS' THEN
            SELECT STATE, ENABLED
            INTO   l_state, l_enabled
            FROM   USER_SCHEDULER_JOBS
            WHERE  JOB_NAME = 'WA_MSG_PROCESSOR_JOB';

            DBMS_OUTPUT.PUT_LINE('Job: WA_MSG_PROCESSOR_JOB');
            DBMS_OUTPUT.PUT_LINE('  Enabled : ' || l_enabled);
            DBMS_OUTPUT.PUT_LINE('  State   : ' || l_state);

        ELSE
            RAISE_APPLICATION_ERROR(
                -20040,
                'WA_SCHEDULER_CONTROL: Unknown action [' || p_action || ']. Use START | STOP | RUN_NOW | STATUS.'
            );
    END CASE;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('WA_MSG_PROCESSOR_JOB not found. Run scheduler/job.sql to create it.');
    WHEN OTHERS THEN
        WA_LOG_PKG.LOG_ENGINE_ERROR(
            p_source_module => 'WA_SCHEDULER_CONTROL',
            p_error_code    => SQLCODE,
            p_error_message => SQLERRM,
            p_stack_trace   => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
        );
        RAISE;
END WA_SCHEDULER_CONTROL;
/

SHOW ERRORS PROCEDURE WA_SCHEDULER_CONTROL;


-- =============================================================================
-- VERIFICATION QUERIES
-- Run these after deployment to confirm scheduler state.
-- =============================================================================

-- Check job status
SELECT JOB_NAME, ENABLED, STATE, NEXT_RUN_DATE,
       RUN_COUNT, FAILURE_COUNT, LAST_START_DATE, LAST_RUN_DURATION
FROM   USER_SCHEDULER_JOBS
WHERE  JOB_NAME = 'WA_MSG_PROCESSOR_JOB';

-- Review recent job runs
SELECT LOG_ID, JOB_NAME, STATUS, RUN_DURATION,
       ACTUAL_START_DATE, ADDITIONAL_INFO
FROM   USER_SCHEDULER_JOB_LOG
WHERE  JOB_NAME = 'WA_MSG_PROCESSOR_JOB'
ORDER  BY ACTUAL_START_DATE DESC
FETCH  FIRST 20 ROWS ONLY;
