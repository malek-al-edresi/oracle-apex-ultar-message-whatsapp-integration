# Architecture — Oracle APEX Enterprise WhatsApp Messaging System

## 1. System Overview

This document describes the architecture of the production-grade WhatsApp messaging platform built on Oracle Database and Oracle APEX, using the UltraMsg API as the WhatsApp delivery gateway.

The system decouples message creation from message delivery through an asynchronous queue, ensuring no APEX page process ever blocks on an outbound HTTP call.

---

## 2. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Oracle APEX                             │
│  (Page Buttons / Dynamic Actions / PL/SQL Process blocks)       │
└────────────────────────┬────────────────────────────────────────┘
                         │  WA_APEX_SEND  /  WA_MSG_PKG.ENQUEUE
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                     WA_MESSAGE_QUEUE                            │
│  STATUS: PENDING → PROCESSING → SENT | FAILED                  │
│  Priority: 1 (OTP/Alert) … 5 (General) … 10 (Low)             │
└────────────────────────┬────────────────────────────────────────┘
                         │  DBMS_SCHEDULER — every 5 minutes
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                   WA_ENGINE_PKG.PROCESS_QUEUE                   │
│  • Reads PENDING batch (up to 50 rows, FOR UPDATE SKIP LOCKED)  │
│  • Marks PROCESSING to prevent duplicate dispatch               │
│  • Calls WA_GET_API_CONFIG → WA_API_CONFIG                      │
│  • Builds JSON → APEX_WEB_SERVICE.MAKE_REST_REQUEST             │
│  • Evaluates HTTP status code                                   │
│  • Retry logic: max 3 attempts, then FAILED                     │
│  • Writes to WA_API_LOG (autonomous transaction)                │
└────────────────────────┬────────────────────────────────────────┘
                         │  HTTPS POST  (Content-Type: application/json)
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                        UltraMsg API                             │
│  https://api.ultramsg.com/{instance_id}/messages/chat           │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
                    WhatsApp Network
```

---

## 3. Component Breakdown

### 3.1 API Configuration Module (`config/api_config.sql`)

| Object | Type | Purpose |
|---|---|---|
| `WA_API_CONFIG` | Table | Stores UltraMsg credentials, endpoint URLs, and per-service retry limits |
| `WA_GET_API_CONFIG` | Function | Returns the active config row; raises `ORA-20001` if not found |

**Security:** API tokens are stored in the database table, not in application code or environment files. For maximum security in production, combine this with Oracle Transparent Data Encryption (TDE) on the `API_TOKEN` column.

---

### 3.2 Logging System (`logging/logs.sql`)

| Object | Type | Purpose |
|---|---|---|
| `WA_API_LOG` | Table | One row per API call attempt: request, response, HTTP status, latency |
| `WA_ENGINE_ERROR_LOG` | Table | Engine-level PL/SQL exceptions and batch run summaries |
| `WA_LOG_PKG` | Package | Centralised logging API using `PRAGMA AUTONOMOUS_TRANSACTION` |

Both log tables use `PRAGMA AUTONOMOUS_TRANSACTION` so that log writes always commit independently of the outer transaction — meaning a rolled-back message delivery still produces an audit record.

---

### 3.3 Messaging Queue System (`src/send_whatsapp.sql`)

| Object | Type | Purpose |
|---|---|---|
| `WA_MESSAGE_QUEUE` | Table | Every outbound message; lifecycle tracked by STATUS column |
| `WA_MSG_PKG` | Package | Public enqueue API: `ENQUEUE`, `ENQUEUE_OTP`, `ENQUEUE_NOTIFICATION`, `ENQUEUE_ALERT` |
| `WA_APEX_SEND` | Procedure | Thin APEX-facing wrapper; called directly from APEX page processes |

**Message lifecycle:**

```
PENDING  ─►  PROCESSING  ─►  SENT
                 │
                 └──(HTTP error, retry_count < max_retries)──► PENDING
                 │
                 └──(retry_count >= max_retries)──────────────► FAILED
```

The `FOR UPDATE SKIP LOCKED` clause on the queue cursor ensures safe concurrent execution across multiple scheduler threads or RAC nodes.

---

### 3.4 Processing Engine (`src/process_queue.sql`)

| Object | Type | Purpose |
|---|---|---|
| `WA_ENGINE_PKG` | Package | Core engine: `PROCESS_QUEUE`, `RESET_FAILED_FOR_RETRY`, `SEND_IMMEDIATE` |

**Batch processing flow:**
1. Load config once (single `SELECT` from `WA_API_CONFIG`).
2. Bulk-update eligible `PENDING` rows to `PROCESSING` (atomic, commit).
3. Loop through `PROCESSING` rows, call `DISPATCH_ONE` per row.
4. On success → `SENT`; on HTTP error → decrement retry and `PENDING`/`FAILED`; on exception → `PENDING`.
5. Each iteration uses a `SAVEPOINT` so a failure on one message does not roll back the entire batch.
6. Write a run-summary line to `WA_ENGINE_ERROR_LOG`.

---

### 3.5 Scheduler Automation (`scheduler/job.sql`)

| Object | Type | Purpose |
|---|---|---|
| `WA_PROCESS_QUEUE_PROG` | Scheduler Program | Points to `WA_ENGINE_PKG.PROCESS_QUEUE` |
| `WA_EVERY_5_MIN_SCHED` | Scheduler Schedule | `FREQ=MINUTELY; INTERVAL=5` |
| `WA_MSG_PROCESSOR_JOB` | Scheduler Job | Binds program + schedule; disabled by default for safety |
| `WA_SCHEDULER_CONTROL` | Procedure | `START \| STOP \| RUN_NOW \| STATUS` convenience control |

The job is created **disabled** (`enabled => FALSE`). Enable it explicitly after verifying configuration:

```sql
BEGIN WA_SCHEDULER_CONTROL('START'); END;
/
```

---

## 4. Deployment Order

> Objects must be created in dependency order. Execute scripts in the sequence below.

```
1.  config/api_config.sql      -- WA_API_CONFIG table + WA_GET_API_CONFIG function
2.  logging/logs.sql           -- WA_API_LOG, WA_ENGINE_ERROR_LOG, WA_LOG_PKG
3.  src/send_whatsapp.sql      -- WA_MESSAGE_QUEUE, WA_MSG_PKG, WA_APEX_SEND
4.  src/process_queue.sql      -- WA_ENGINE_PKG
5.  scheduler/job.sql          -- DBMS_SCHEDULER objects + WA_SCHEDULER_CONTROL
```

---

## 5. Retry Policy

| Attempt | Action |
|---------|--------|
| 1st failure | `RETRY_COUNT = 1`, status → `PENDING`, re-queued next cycle |
| 2nd failure | `RETRY_COUNT = 2`, status → `PENDING`, re-queued next cycle |
| 3rd failure | `RETRY_COUNT = 3`, status → `FAILED`, `FAILED_AT` recorded |

The maximum retry count is configurable per message (`WA_MESSAGE_QUEUE.MAX_RETRIES`) and defaults to the value set in `WA_API_CONFIG.MAX_RETRIES`.

To manually re-enqueue FAILED messages with remaining attempts:

```sql
BEGIN WA_ENGINE_PKG.RESET_FAILED_FOR_RETRY; END;
/
```

---

## 6. Security Considerations

- API tokens are never hardcoded in application code — always read from `WA_API_CONFIG`.
- The `IS_ACTIVE = 'N'` flag allows instant revocation of a service key without code changes.
- Apply Oracle VPD or row-level security to `WA_API_CONFIG` to restrict read access to the engine schema only.
- Use Oracle Wallet / `DBMS_CRYPTO` for at-rest encryption of the `API_TOKEN` column in sensitive environments.
- Grant `EXECUTE` on `WA_APEX_SEND` and `WA_MSG_PKG` to the APEX parsing schema only; do not expose `WA_ENGINE_PKG` or log tables directly.

---

## 7. Monitoring Queries

```sql
-- Current queue health
SELECT STATUS, COUNT(*) AS MSG_COUNT
FROM   WA_MESSAGE_QUEUE
GROUP  BY STATUS;

-- Recent API call audit (last 100)
SELECT LOG_DATE, PHONE_NUMBER, HTTP_STATUS, STATUS, DURATION_MS, ATTEMPT_NUMBER
FROM   WA_API_LOG
ORDER  BY LOG_DATE DESC
FETCH  FIRST 100 ROWS ONLY;

-- Engine errors in the last 24 hours
SELECT LOG_DATE, SOURCE_MODULE, ERROR_MESSAGE
FROM   WA_ENGINE_ERROR_LOG
WHERE  LOG_DATE >= SYSTIMESTAMP - INTERVAL '24' HOUR
ORDER  BY LOG_DATE DESC;

-- Scheduler job history
SELECT ACTUAL_START_DATE, STATUS, RUN_DURATION
FROM   USER_SCHEDULER_JOB_LOG
WHERE  JOB_NAME = 'WA_MSG_PROCESSOR_JOB'
ORDER  BY ACTUAL_START_DATE DESC
FETCH  FIRST 20 ROWS ONLY;
```

---

## 8. Use Case Patterns

### OTP Verification
```sql
DECLARE l_id NUMBER; BEGIN
  WA_MSG_PKG.ENQUEUE_OTP('+96650XXXXXXX', '847291', 'MyApp', 'USER_12345', l_id);
  COMMIT;
END;
```

### System Alert
```sql
DECLARE l_id NUMBER; BEGIN
  WA_MSG_PKG.ENQUEUE_ALERT('+96650XXXXXXX', 'CRITICAL: Database backup failed at 03:00 UTC.', 'BACKUP_JOB', l_id);
  COMMIT;
END;
```

### APEX Button Process
```sql
DECLARE l_id NUMBER; BEGIN
  WA_APEX_SEND(:P1_PHONE, :P1_MESSAGE, 'NOTIFICATION', :P1_ORDER_ID, l_id);
  :P1_MESSAGE_ID := l_id;
END;
```
