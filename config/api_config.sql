-- =============================================================================
-- FILE        : config/api_config.sql
-- MODULE      : API Configuration Module
-- PURPOSE     : Creates and seeds the API configuration table used by the
--               WhatsApp messaging engine. All API credentials are stored
--               here; no tokens are hardcoded in application code.
-- AUTHOR      : ENG. Malek Mohammed Al-edresi
-- DATE        : 2026-01-01
-- VERSION     : 2.0
-- =============================================================================


-- -----------------------------------------------------------------------------
-- TABLE: WA_API_CONFIG
-- Stores all external API service credentials and endpoints.
-- One row per service (e.g., ULTRAMSG_WHATSAPP).
-- -----------------------------------------------------------------------------
CREATE TABLE WA_API_CONFIG (
    CONFIG_ID          NUMBER          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    SERVICE_NAME       VARCHAR2(100)   NOT NULL,
    INSTANCE_ID        VARCHAR2(100)   NOT NULL,
    API_TOKEN          VARCHAR2(500)   NOT NULL,
    API_HOST           VARCHAR2(255)   NOT NULL,
    API_ENDPOINT       VARCHAR2(255)   NOT NULL,
    COUNTRY_CODE       VARCHAR2(10)    DEFAULT '+966',
    IS_ACTIVE          VARCHAR2(1)     DEFAULT 'Y'  NOT NULL CHECK (IS_ACTIVE IN ('Y', 'N')),
    MAX_RETRIES        NUMBER(2)       DEFAULT 3    NOT NULL,
    TIMEOUT_SECONDS    NUMBER(5)       DEFAULT 30   NOT NULL,
    CREATED_BY         VARCHAR2(100)   DEFAULT 'SYSTEM',
    CREATED_DATE       DATE            DEFAULT SYSDATE,
    UPDATED_BY         VARCHAR2(100),
    UPDATED_DATE       DATE,
    CONSTRAINT WA_API_CONFIG_SVC_UQ UNIQUE (SERVICE_NAME)
);

COMMENT ON TABLE  WA_API_CONFIG IS 'Stores API service credentials and endpoint configuration for the WhatsApp messaging engine.';
COMMENT ON COLUMN WA_API_CONFIG.SERVICE_NAME    IS 'Unique logical name identifying the API service (e.g., ULTRAMSG_WHATSAPP).';
COMMENT ON COLUMN WA_API_CONFIG.INSTANCE_ID     IS 'UltraMsg instance identifier (e.g., instance12345).';
COMMENT ON COLUMN WA_API_CONFIG.API_TOKEN       IS 'Bearer authentication token for the UltraMsg API. Keep secret.';
COMMENT ON COLUMN WA_API_CONFIG.API_HOST        IS 'Base URL of the UltraMsg API (e.g., https://api.ultramsg.com).';
COMMENT ON COLUMN WA_API_CONFIG.API_ENDPOINT    IS 'Relative path for the messages/chat endpoint.';
COMMENT ON COLUMN WA_API_CONFIG.COUNTRY_CODE    IS 'Default international dialling prefix prepended to phone numbers.';
COMMENT ON COLUMN WA_API_CONFIG.IS_ACTIVE       IS 'Y = configuration is live; N = disabled.';
COMMENT ON COLUMN WA_API_CONFIG.MAX_RETRIES     IS 'Maximum number of delivery retries before marking a message as FAILED.';
COMMENT ON COLUMN WA_API_CONFIG.TIMEOUT_SECONDS IS 'HTTP request timeout in seconds for REST calls to UltraMsg.';


-- -----------------------------------------------------------------------------
-- INDEX: faster lookup by service name (used at runtime)
-- -----------------------------------------------------------------------------
CREATE INDEX IDX_WA_API_CONFIG_SVC ON WA_API_CONFIG (SERVICE_NAME, IS_ACTIVE);


-- -----------------------------------------------------------------------------
-- SEED: Default UltraMsg configuration
-- Replace the placeholder values with real credentials before deployment.
-- NEVER commit real tokens to source control — use a secrets manager or
-- run this block via a protected CI/CD pipeline variable.
-- -----------------------------------------------------------------------------
INSERT INTO WA_API_CONFIG (
    SERVICE_NAME,
    INSTANCE_ID,
    API_TOKEN,
    API_HOST,
    API_ENDPOINT,
    COUNTRY_CODE,
    IS_ACTIVE,
    MAX_RETRIES,
    TIMEOUT_SECONDS,
    CREATED_BY
) VALUES (
    'ULTRAMSG_WHATSAPP',
    'instance00000',                          -- TODO: Replace with your UltraMsg instance ID
    'YOUR_ULTRAMSG_TOKEN_HERE',               -- TODO: Replace with your UltraMsg API token
    'https://api.ultramsg.com',
    '/messages/chat',
    '+966',
    'Y',
    3,
    30,
    'SYSTEM'
);

COMMIT;


-- -----------------------------------------------------------------------------
-- FUNCTION: WA_GET_API_CONFIG
-- Returns the active API configuration row for a given service name.
-- Called by the processing engine; never exposes tokens to application layers.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION WA_GET_API_CONFIG (
    p_service_name IN VARCHAR2
) RETURN WA_API_CONFIG%ROWTYPE
-- ----------------------------------------------------------------------------
-- FUNCTION NAME  : WA_GET_API_CONFIG
-- PURPOSE        : Retrieve the active API configuration for the specified
--                  service from WA_API_CONFIG.
-- PARAMETERS     : p_service_name (IN VARCHAR2) - logical service identifier
-- RETURNS        : WA_API_CONFIG%ROWTYPE — full configuration row
-- ERROR HANDLING : Raises application errors for missing/inactive config.
--                  All exceptions are propagated to the caller.
-- AUTHOR         : ENG. Malek Mohammed Al-edresi
-- DATE           : 2026-01-01
-- VERSION        : 2.0
-- ----------------------------------------------------------------------------
IS
    l_config WA_API_CONFIG%ROWTYPE;
BEGIN
    SELECT *
    INTO   l_config
    FROM   WA_API_CONFIG
    WHERE  SERVICE_NAME = p_service_name
    AND    IS_ACTIVE    = 'Y'
    AND    ROWNUM       = 1;

    RETURN l_config;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(
            -20001,
            'WA_GET_API_CONFIG: No active configuration found for service [' || p_service_name || '].'
        );
    WHEN OTHERS THEN
        RAISE_APPLICATION_ERROR(
            -20002,
            'WA_GET_API_CONFIG: Unexpected error — ' || SQLERRM
        );
END WA_GET_API_CONFIG;
/

SHOW ERRORS FUNCTION WA_GET_API_CONFIG;
