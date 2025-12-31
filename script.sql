-- 
-- create or replace function to get API configuration based on service name
--
create or replace FUNCTION GET_API_CONFIG (
    p_service_name IN VARCHAR2 DEFAULT NULL
) RETURN MANAG_SYS_SEC_L_SETTING_API_SERVICES%ROWTYPE
---------------------------------------------------------------------- 
-- FUNCTION NAME     : GET_API_CONFIG  
-- PURPOSE           : Retrieve API configuration dynamically based on service name
-- PARAMETERS        :  
--                     P_SERVICE_NAME (IN VARCHAR2) - Name of the service for which API configuration is required
-- DESCRIPTION       : This function retrieves the API configuration for a specified service from the MANAG_SYS_SEC_L_SETTING_API_SERVICES table.
-- RETURNS           : A row of type MANAG_SYS_SEC_L_SETTING_API_SERVICES%ROWTYPE containing the API configuration details for the specified service 
-- ERROR HANDLING    : Logs any processing errors to ERROR_LOG_PKG_SYSTEM_ALL  
--                     with source identification and user context  
-- Author            : ENG.Malek Mohammed Al-edresi  
-- Date              : 2025-12-23  
-- Version           : 1.0  
---------------------------------------------------------------------
IS
    l_config MANAG_SYS_SEC_L_SETTING_API_SERVICES%ROWTYPE; -- API Configuration
    l_error_info        file_processing_error_type := file_processing_error_type(NULL, NULL, 'PROCESSING', NVL(v('APP_USER'), 'SYSTEM'));  -- Error handling
BEGIN
    SELECT *
    INTO l_config
    FROM MANAG_SYS_SEC_L_SETTING_API_SERVICES
    WHERE SERVICE_NAME = p_service_name
    AND ROWNUM = 1;

    RETURN l_config;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        l_error_info.error_message := 'API configuration not found for service: ' || p_service_name;
        l_error_info.error_source := 'GET_API_CONFIG - API Configuration Retrieval';
        l_error_info.processing_status := 'ERROR';

          -- Log the error  
        BEGIN  
            ERROR_LOG_PKG_SYSTEM_ALL.INSERT_FUNCTIONS_SEC_LOG (  
                l_error_info.error_message,  
                l_error_info.error_source,  
                l_error_info.user_name  
            );  
        EXCEPTION  
            WHEN OTHERS THEN  
                NULL;  
        END;  

        RETURN NULL;

    WHEN OTHERS THEN  
        l_error_info.error_message := 'Error in file processing pipeline: ' || SQLERRM;  
        l_error_info.error_source := 'GET_API_CONFIG - Main Process';  
        l_error_info.processing_status := 'ERROR';  

        -- Log the error  
        BEGIN  
            ERROR_LOG_PKG_SYSTEM_ALL.INSERT_FUNCTIONS_SEC_LOG (  
                l_error_info.error_message,  
                l_error_info.error_source,  
                l_error_info.user_name  
            );  
        EXCEPTION  
            WHEN OTHERS THEN  
                NULL;  
        END;  

        RETURN NULL; 
END;
/
-- create or replace procedure to send WhatsApp messages using UltraMsg API
create or replace procedure send_whatsapp (
    p_to_phone_no     in varchar2,
    p_msg             in clob
) is    
---------------------------------------------------------------------- 
-- PROCEDURE NAME    :  send_whatsapp
-- PURPOSE           : This procedure is designed to send a WhatsApp message using the UltraMsg API.
-- PARAMETERS        :  
--                     p_to_phone_no     - The phone number to which the message will be sent.
--                     p_msg             - The message content to be sent. 
-- DESCRIPTION       :  
--                     This procedure retrieves the necessary API configuration for UltraMsg, constructs the API URL, and sends the message using the UltraMsg API.
--                     It includes proper cleanup after each call to prevent issues with subsequent messages.
--                     It logs the start and end of the procedure execution, and handles any exceptions that occur during the process. 
-- ERROR HANDLING    : Logs any processing errors to ERROR_LOG_PKG_SYSTEM_ALL  
--                     with source identification and user context  
-- Author            : ENG.Malek Mohammed Al-edresi  
-- Date              : 2025-12-25  
-- Version           : 1.1  
-- CHANGES           : Added proper cleanup of web service headers and variables after each call
----------------------------------------------------------------------

    -- Declare variables to hold API configuration details
    l_get_confgration MANAG_SYS_SEC_L_SETTING_API_SERVICES%ROWTYPE;

    -- Declare variables for API request details
    l_token           varchar2(255);
    l_instance_id     varchar2(255);
    l_host            varchar2(255);
    l_url_api         varchar2(255);
    l_method_url      varchar2(255);
    l_country_code    varchar2(20);
    l_full_phone_number varchar2(20);

    -- Declare variable to hold the result of the API call
    l_result          clob;

    -- Declare variable for JSON body
    l_json_body       clob;

    -- Declare debug template for logging
    l_debug_template  varchar2(4000) := 'ultramsg.send_whatsapp_msg %0 %1 %2 %3 %4 %5 %6 %7';

    -- Declare error handling variables
    l_error_info     file_processing_error_type := file_processing_error_type(NULL, NULL, 'PROCESSING', NVL(v('APP_USER'), 'SYSTEM')); 

begin
    -- Clear any existing cookies and headers to ensure clean state
    apex_web_service.clear_request_cookies;
    apex_web_service.clear_request_headers;

    -- Initialize variables to ensure clean state
    l_token := null;
    l_instance_id := null;
    l_host := null;
    l_url_api := null;
    l_method_url := null;
    l_country_code := null;
    l_full_phone_number := null;
    l_result := null;
    l_json_body := EMPTY_CLOB();

    -- Enable debug logging
    apex_debug.enable();
    -- Log start of procedure with parameters
    apex_debug.message(l_debug_template, 'START', 'p_to_phone_no', p_to_phone_no, 'p_msg', substr(p_msg, 1, 100) || '...');

    -- Retrieve API configuration
    l_get_confgration := GET_API_CONFIG ( p_service_name => 'ULTAR_MESSAGE_WHTASAPP');

    -- Retrieve API configuration details
    BEGIN
        -- Extract configuration details
        l_token        := TRIM(l_get_confgration.API_KEY);
        l_instance_id  := TRIM(l_get_confgration.ACCOUNT_SID);
        l_host         := TRIM(l_get_confgration.API_HOST);
        l_url_api      := TRIM(l_get_confgration.API_URL);
        l_country_code := TRIM(l_get_confgration.CODE_COUNTRY_CALL);

        -- Construct the full phone number with country code
        l_full_phone_number := l_country_code || p_to_phone_no;

        -- Construct the full API URL
        l_method_url := l_host || '/' || l_instance_id || l_url_api;

        -- Log the constructed URL
        apex_debug.message(l_debug_template, 'CONFIG_LOADED', 'URL', l_method_url);

    EXCEPTION
        WHEN OTHERS THEN
            l_error_info.error_message := 'Error for get data form table MANAG_SYS_SEC_L_SETTING_API_SERVICES' || SQLERRM; 
            l_error_info.error_source := 'send_whatsapp - Configuration Load';  
            l_error_info.processing_status := 'ERROR';  
            ERROR_LOG_PKG_SYSTEM_ALL.INSERT_FUNCTIONS_SEC_LOG (  
                l_error_info.error_message,  
                l_error_info.error_source,  
                l_error_info.user_name  
            );  
            -- Cleanup before exit
            -- Clear any existing cookies and headers to ensure clean state
            apex_web_service.clear_request_cookies;
            apex_web_service.clear_request_headers;
            raise;
    END;

    -- Construct the API request and make the call
    BEGIN
        -- Clear any existing headers
        apex_web_service.g_request_headers.delete();

        -- Set JSON headers
        apex_web_service.g_request_headers(1).name  := 'Content-Type';
        apex_web_service.g_request_headers(1).value := 'application/json';

        -- Build JSON body with proper CLOB handling
        l_json_body := l_json_body || '{"token":"' || l_token || '","to":"' || l_full_phone_number || '","body":"';

        -- Add the message content safely
        DECLARE
            l_safe_msg CLOB := replace(replace(p_msg, '"', '\"'), chr(10), '\n');
        BEGIN
            l_json_body := l_json_body || l_safe_msg;
        END;

        l_json_body := l_json_body || '"}';

        -- Log the request body (first 500 chars to avoid overflow)
        apex_debug.message(l_debug_template, 'REQUEST_BODY', substr(l_json_body, 1, 500) || '...');


        IF LENGTH(l_json_body) > 32000 THEN
            RAISE_APPLICATION_ERROR(-20004, 'JSON Body too large: ' || LENGTH(l_json_body));
        END IF;

        -- Make API request with JSON body
        l_result := apex_web_service.make_rest_request(
            p_url           => l_method_url,
            p_http_method   => 'POST',
            p_body          => l_json_body,
            p_transfer_timeout => 30
        );

        -- Log the API response
        apex_debug.message(l_debug_template, 'API_SUCCESS', 'Response Length', length(l_result));
        apex_debug.message(l_debug_template, 'API_RESPONSE', substr(l_result, 1, 500) || '...');

    EXCEPTION
        WHEN OTHERS THEN
            l_error_info.error_message := 'Error in making API request: ' || SQLERRM; 
            l_error_info.error_source := 'send_whatsapp - API Call';  
            l_error_info.processing_status := 'ERROR';  
            ERROR_LOG_PKG_SYSTEM_ALL.INSERT_FUNCTIONS_SEC_LOG (  
                l_error_info.error_message,  
                l_error_info.error_source,  
                l_error_info.user_name  
            ); 

            -- Cleanup before exit
            -- Clear any existing cookies and headers to ensure clean state
            apex_web_service.clear_request_cookies;
            apex_web_service.clear_request_headers;
            raise;
    END;

    -- Log the result of the API call
    apex_debug.message(l_debug_template, 'l_result', substr(l_result, 1, 500) || '...');

    -- Perform cleanup after successful operation
    BEGIN
        -- Cleanup before exit
        -- Clear any existing cookies and headers to ensure clean state
        apex_web_service.clear_request_cookies;
        apex_web_service.clear_request_headers;

        -- Reset variables to null
        l_token := null;
        l_instance_id := null;
        l_host := null;
        l_url_api := null;
        l_method_url := null;
        l_country_code := null;
        l_full_phone_number := null;
        l_json_body := null;

        apex_debug.message(l_debug_template, 'CLEANUP_COMPLETED', 'All variables reset');
    EXCEPTION
        WHEN OTHERS THEN
            -- If cleanup fails, log but don't re-raise
            apex_debug.message(l_debug_template, 'CLEANUP_ERROR', SQLERRM);
    END;

    -- Log the end of the procedure
    apex_debug.message(l_debug_template, 'END');
    -- Disable debug logging
    apex_debug.disable();

    -- Cleanup before exit
    -- Clear any existing cookies and headers to ensure clean state
    apex_web_service.clear_request_cookies;
    apex_web_service.clear_request_headers;

exception
    when others then
        -- Log the error but don't re-raise to maintain system stability
        l_error_info.error_message := 'Unexpected error in send_whatsapp: ' || SQLERRM; 
        l_error_info.error_source := 'send_whatsapp - Exception Block';  
        l_error_info.processing_status := 'ERROR';  
        ERROR_LOG_PKG_SYSTEM_ALL.INSERT_FUNCTIONS_SEC_LOG (  
            l_error_info.error_message,  
            l_error_info.error_source,  
            l_error_info.user_name  
        );  
        -- Log cleanup after error
        apex_debug.message(l_debug_template, 'ERROR_CLEANUP_COMPLETED');
        apex_debug.disable();

        -- Clear any existing cookies and headers to ensure clean state
        apex_web_service.clear_request_cookies;
        apex_web_service.clear_request_headers;
end send_whatsapp;