## Oracle APEX + UltraMsg WhatsApp API Integration

This project demonstrates how to integrate **UltraMsg WhatsApp API** with **Oracle APEX / Oracle Database (PL/SQL)** to send WhatsApp messages programmatically.
It includes example SQL scripts, a stored procedure for sending WhatsApp messages, configuration steps, and sample usage.

---
![procedure](screenshot/temp.jpg) 

| Procedure Code | Run Preview |
|----------------|-------------|
| ![procedure](screenshot/procedure.png) | ![message](screenshot/message.jpg) |

---

## Overview

This integration enables Oracle Database and APEX applications to send WhatsApp messages directly through the UltraMsg API. The solution provides a production-ready PL/SQL procedure that handles API communication, error handling, and credential management.

## Features

* Send WhatsApp messages directly from Oracle Database using UltraMsg API
* Ready-to-use `PL/SQL` procedure for message sending
* Works with **Oracle APEX** and **Autonomous Database**
* Simple configuration & customizable message body
* Example SQL script included
* Dynamic API configuration retrieval from database tables
* Proper error handling and logging
* Secure credential management

---

## How It Works

The integration uses Oracle's built-in `UTL_HTTP` package to make REST API calls to the UltraMsg WhatsApp API. The PL/SQL procedure:

1. Retrieves API credentials from a configuration table
2. Constructs the HTTP request with proper headers and payload
3. Sends the WhatsApp message via the UltraMsg API endpoint
4. Handles responses and errors appropriately

This approach allows seamless integration with Oracle APEX applications, enabling WhatsApp notifications triggered by database events or user actions.

---

## Requirements

- Oracle Database 11g or higher (including Oracle Autonomous Database)
- Oracle APEX (any version)
- UltraMsg account with API credentials
- Network access from Oracle Database to UltraMsg API endpoints
- `UTL_HTTP` package enabled and configured

---

## Project Structure

```
.
├── script.sql          # Complete PL/SQL implementation
├── screenshot/         # Visual examples and documentation
└── README.md          # This file
```

---

## License

This project is licensed under the Apache License 2.0.
