<div align="center">

# 📲 Oracle APEX × UltraMsg — Enterprise WhatsApp Messaging Platform

**Production-grade, queue-based WhatsApp messaging system built on Oracle Database & Oracle APEX**

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Oracle APEX](https://img.shields.io/badge/Oracle-APEX-red.svg)](https://apex.oracle.com)
[![PL/SQL](https://img.shields.io/badge/Language-PL%2FSQL-orange.svg)]()
[![UltraMsg API](https://img.shields.io/badge/API-UltraMsg-25D366.svg)](https://ultramsg.com)
[![Status](https://img.shields.io/badge/Status-Production%20Ready-brightgreen.svg)]()

</div>

---

## 🏗️ System Architecture

```
Oracle APEX (Button / Dynamic Action / PL/SQL Process)
            │
            │  WA_APEX_SEND  /  WA_MSG_PKG.ENQUEUE
            ▼
    ┌──────────────────┐
    │  WA_MESSAGE_QUEUE │   PENDING → PROCESSING → SENT | FAILED
    └────────┬─────────┘
             │  DBMS_SCHEDULER (every 5 minutes)
             ▼
    ┌───────────────────────┐
    │  WA_ENGINE_PKG        │   Batch processor + retry logic
    │  .PROCESS_QUEUE()     │   FOR UPDATE SKIP LOCKED (RAC-safe)
    └────────┬──────────────┘
             │  HTTPS POST  (application/json)
             ▼
    ┌─────────────────────────────────────────┐
    │  UltraMsg API                           │
    │  https://api.ultramsg.com/{instance}/   │
    │  messages/chat                          │
    └────────┬────────────────────────────────┘
             │
             ▼
       WhatsApp Network
```

---

## ✨ Features

| Feature | Detail |
|---|---|
| **Async Queue** | `WA_MESSAGE_QUEUE` decouples APEX pages from HTTP calls |
| **Priority Routing** | OTP/Alert (P1) delivered before General (P5) |
| **Retry Logic** | Up to 3 attempts per message, configurable per row |
| **Full Audit Trail** | Every API call logged with request, response, status, and latency |
| **Engine Error Log** | Separate table for PL/SQL exceptions and batch run summaries |
| **DBMS_SCHEDULER** | Runs every 5 minutes, fully observable via `USER_SCHEDULER_JOB_LOG` |
| **Secure Config** | API tokens in database table — zero hardcoded credentials |
| **APEX-Native** | Uses `APEX_WEB_SERVICE` — no external Java or middleware required |
| **RAC-Safe** | `FOR UPDATE SKIP LOCKED` prevents duplicate dispatches |
| **Modular Design** | 5 independent SQL scripts; deploy in strict dependency order |

---

## 📁 Project Structure

```
oracle-apex-ultramsg-whatsapp/
│
├── config/
│   └── api_config.sql          # WA_API_CONFIG table + WA_GET_API_CONFIG function
│
├── logging/
│   └── logs.sql                # WA_API_LOG, WA_ENGINE_ERROR_LOG, WA_LOG_PKG
│
├── src/
│   ├── send_whatsapp.sql       # WA_MESSAGE_QUEUE, WA_MSG_PKG, WA_APEX_SEND
│   └── process_queue.sql       # WA_ENGINE_PKG (core processing engine)
│
├── scheduler/
│   └── job.sql                 # DBMS_SCHEDULER job + WA_SCHEDULER_CONTROL
│
├── docs/
│   └── architecture.md         # Full architecture documentation
│
├── script.sql                  # Original v1 procedure (preserved for reference)
├── LICENSE                     # Apache License 2.0
└── README.md                   # This file
```

---

## 🚀 Quick Start

### Prerequisites

- Oracle Database 12c Release 2+ (or Oracle Autonomous Database)
- Oracle APEX (any version with `APEX_WEB_SERVICE` support)
- Active UltraMsg account with a paired WhatsApp instance
- `CREATE TABLE`, `CREATE PROCEDURE`, `CREATE JOB` privileges
- ACL allowing outbound HTTPS to `api.ultramsg.com`

### Step 1 — Grant Network ACL

```sql
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host       => 'api.ultramsg.com',
    lower_port => 443,
    upper_port => 443,
    ace        => xs$ace_type(
                    privilege_list => xs$name_list('connect','resolve'),
                    principal_name => 'YOUR_APEX_SCHEMA',
                    principal_type => xs_acl.ptype_db
                  )
  );
END;
/
```

### Step 2 — Deploy Scripts (in order)

```sql
@config/api_config.sql
@logging/logs.sql
@src/send_whatsapp.sql
@src/process_queue.sql
@scheduler/job.sql
```

### Step 3 — Configure API Credentials

```sql
UPDATE WA_API_CONFIG
SET    INSTANCE_ID = 'instance12345',    -- your UltraMsg instance
       API_TOKEN   = 'your_token_here',  -- your UltraMsg token
       COUNTRY_CODE = '+966'             -- your default country code
WHERE  SERVICE_NAME = 'ULTRAMSG_WHATSAPP';
COMMIT;
```

### Step 4 — Start the Scheduler

```sql
BEGIN WA_SCHEDULER_CONTROL('START'); END;
/
```

### Step 5 — Send Your First Message

```sql
DECLARE
  l_id NUMBER;
BEGIN
  WA_MSG_PKG.ENQUEUE(
    p_phone_number => '+96650XXXXXXX',
    p_message_body => 'Hello from Oracle APEX!',
    p_message_id   => l_id
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Queued message ID: ' || l_id);
END;
/
```

---

## 🔌 APEX Integration

Add a **PL/SQL Process** to any APEX page button:

```sql
DECLARE
  l_message_id NUMBER;
BEGIN
  WA_APEX_SEND(
    p_phone      => :P1_PHONE_NUMBER,
    p_message    => :P1_MESSAGE,
    p_type       => 'GENERAL',         -- OTP | NOTIFICATION | ALERT | GENERAL
    p_ref_id     => :P1_ORDER_ID,      -- optional correlation key
    p_out_msg_id => l_message_id
  );
  :P1_QUEUED_ID := l_message_id;
END;
```

The message is queued instantly; the scheduler dispatches it within 5 minutes.

---

## 📦 Use Cases

### 1. OTP Verification System

Send time-sensitive one-time passwords with highest priority (P1) so they bypass the general backlog.

```sql
DECLARE l_id NUMBER; BEGIN
  WA_MSG_PKG.ENQUEUE_OTP(
    p_phone_number => '+96650XXXXXXX',
    p_otp_code     => '847291',
    p_app_name     => 'MyPortal',
    p_reference_id => 'USER_42',
    p_message_id   => l_id
  );
  COMMIT;
END;
```

**Delivered message:** *Your MyPortal verification code is: **847291**. This code expires in 10 minutes. Do not share it with anyone.*

---

### 2. Notification System

Trigger order confirmations, appointment reminders, or status updates directly from APEX workflows.

```sql
DECLARE l_id NUMBER; BEGIN
  WA_MSG_PKG.ENQUEUE_NOTIFICATION(
    p_phone_number => '+96650XXXXXXX',
    p_message_body => 'Your order #ORD-2026-00123 has been shipped. Expected delivery: 18 Apr 2026.',
    p_reference_id => 'ORD-2026-00123',
    p_message_id   => l_id
  );
  COMMIT;
END;
```

---

### 3. Alert System

Dispatch production alerts — database down, backup failures, threshold breaches — at P1 priority.

```sql
DECLARE l_id NUMBER; BEGIN
  WA_MSG_PKG.ENQUEUE_ALERT(
    p_phone_number  => '+96650XXXXXXX',
    p_alert_message => 'CRITICAL: Tablespace USERS at 95% capacity on PRODDB. Immediate action required.',
    p_reference_id  => 'DBMON_20260416',
    p_message_id    => l_id
  );
  COMMIT;
END;
```

---

### 4. Customer Communication

Send HR announcements, invoice summaries, or renewal reminders from any APEX application or scheduled PL/SQL job.

```sql
DECLARE l_id NUMBER; BEGIN
  WA_MSG_PKG.ENQUEUE(
    p_phone_number   => '+96650XXXXXXX',
    p_message_body   => 'Dear Malek, your subscription renews on 01 May 2026. Reply STOP to unsubscribe.',
    p_message_type   => 'GENERAL',
    p_priority       => 5,
    p_reference_id   => 'CUST_0042',
    p_reference_type => 'RENEWAL',
    p_message_id     => l_id
  );
  COMMIT;
END;
```

---

## 📊 Monitoring & Operations

```sql
-- Queue health dashboard
SELECT STATUS, COUNT(*) AS CNT, MAX(RETRY_COUNT) AS MAX_RETRY
FROM   WA_MESSAGE_QUEUE
GROUP  BY STATUS;

-- Last 20 API calls
SELECT LOG_DATE, PHONE_NUMBER, HTTP_STATUS, STATUS, DURATION_MS
FROM   WA_API_LOG
ORDER  BY LOG_DATE DESC FETCH FIRST 20 ROWS ONLY;

-- Engine error log (last 24 h)
SELECT LOG_DATE, SOURCE_MODULE, ERROR_MESSAGE
FROM   WA_ENGINE_ERROR_LOG
WHERE  LOG_DATE >= SYSTIMESTAMP - INTERVAL '24' HOUR
ORDER  BY LOG_DATE DESC;

-- Scheduler control
BEGIN WA_SCHEDULER_CONTROL('STATUS');  END; /
BEGIN WA_SCHEDULER_CONTROL('RUN_NOW'); END; /
BEGIN WA_SCHEDULER_CONTROL('STOP');    END; /
BEGIN WA_SCHEDULER_CONTROL('START');   END; /
```

---

## 🔐 Security Best Practices

- Store API tokens only in `WA_API_CONFIG` — never commit real tokens to Git
- Apply Oracle ACL to restrict which schemas can call `APEX_WEB_SERVICE`
- Grant `EXECUTE` on `WA_APEX_SEND` / `WA_MSG_PKG` to the APEX parsing schema only
- Consider Oracle TDE encryption for the `API_TOKEN` column at rest
- Rotate UltraMsg tokens by updating `WA_API_CONFIG` — no code deployment needed

---

## 📋 Object Inventory

| Object | Type | Script |
|---|---|---|
| `WA_API_CONFIG` | Table | `config/api_config.sql` |
| `WA_GET_API_CONFIG` | Function | `config/api_config.sql` |
| `WA_API_LOG` | Table | `logging/logs.sql` |
| `WA_ENGINE_ERROR_LOG` | Table | `logging/logs.sql` |
| `WA_LOG_PKG` | Package | `logging/logs.sql` |
| `WA_MESSAGE_QUEUE` | Table | `src/send_whatsapp.sql` |
| `WA_MSG_PKG` | Package | `src/send_whatsapp.sql` |
| `WA_APEX_SEND` | Procedure | `src/send_whatsapp.sql` |
| `WA_ENGINE_PKG` | Package | `src/process_queue.sql` |
| `WA_PROCESS_QUEUE_PROG` | Scheduler Program | `scheduler/job.sql` |
| `WA_EVERY_5_MIN_SCHED` | Scheduler Schedule | `scheduler/job.sql` |
| `WA_MSG_PROCESSOR_JOB` | Scheduler Job | `scheduler/job.sql` |
| `WA_SCHEDULER_CONTROL` | Procedure | `scheduler/job.sql` |

---

## 🛠️ Requirements

| Requirement | Minimum Version |
|---|---|
| Oracle Database | 12c Release 2 (12.2) |
| Oracle APEX | 5.0+ |
| UltraMsg Account | Any active plan |
| Network ACL | HTTPS outbound to `api.ultramsg.com:443` |

---

## 📄 License

Copyright 2026 Malek Al-edresi

Licensed under the **Apache License, Version 2.0**. See [LICENSE](LICENSE) for the full text.

---

<div align="center">

Built with ❤️ by **ENG. Malek Mohammed Al-edresi**

</div>
