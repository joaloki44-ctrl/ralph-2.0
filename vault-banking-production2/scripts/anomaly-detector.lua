-- =============================================================================
-- FLUENT-BIT LUA SCRIPT - Détection Anomalies Audit Logs
-- =============================================================================
-- Fichier: /etc/fluent-bit/scripts/anomaly-detector.lua
-- Description: Détecte patterns suspects dans logs Vault
-- Alerting: PagerDuty pour comportements anormaux
-- =============================================================================

local json = require("cjson")
local http = require("socket.http")
local ltn12 = require("ltn12")

-- Configuration
local PAGERDUTY_KEY = os.getenv("PAGERDUTY_INTEGRATION_KEY")
local ALERT_THRESHOLD = {
    failed_logins = 5,           -- 5 échecs login en 1 minute
    secret_access_rate = 100,    -- 100 accès secrets en 1 minute
    privilege_escalation = 1,    -- Toute tentative = alerte immédiate
    unusual_hours = true          -- Accès hors heures (22h-6h)
}

-- Compteurs en mémoire (reset toutes les minutes)
local counters = {
    failed_logins = {},
    secret_access = {},
    last_reset = os.time()
}

-- =============================================================================
-- FONCTION: Reset Compteurs (toutes les 60 secondes)
-- =============================================================================
function reset_counters_if_needed()
    local current_time = os.time()
    if current_time - counters.last_reset >= 60 then
        counters.failed_logins = {}
        counters.secret_access = {}
        counters.last_reset = current_time
    end
end

-- =============================================================================
-- FONCTION: Alerte PagerDuty
-- =============================================================================
function send_pagerduty_alert(severity, summary, details)
    if not PAGERDUTY_KEY then
        return  -- PagerDuty non configuré
    end
    
    local payload = json.encode({
        routing_key = PAGERDUTY_KEY,
        event_action = "trigger",
        payload = {
            summary = summary,
            severity = severity,  -- critical, error, warning, info
            source = "vault-audit-pipeline",
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            custom_details = details
        }
    })
    
    local response_body = {}
    http.request{
        url = "https://events.pagerduty.com/v2/enqueue",
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#payload)
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(response_body)
    }
end

-- =============================================================================
-- DÉTECTION 1: Failed Login Attempts (Brute Force)
-- =============================================================================
function detect_failed_logins(record)
    if record.type ~= "response" then
        return
    end
    
    -- Vérifier erreur auth
    if record.error and record.error:match("permission denied") then
        local user = record.auth and record.auth.display_name or "unknown"
        
        -- Incrémenter compteur
        counters.failed_logins[user] = (counters.failed_logins[user] or 0) + 1
        
        -- Alerte si seuil dépassé
        if counters.failed_logins[user] >= ALERT_THRESHOLD.failed_logins then
            send_pagerduty_alert(
                "error",
                string.format("Brute force attempt detected: %s", user),
                {
                    user = user,
                    failed_attempts = counters.failed_logins[user],
                    threshold = ALERT_THRESHOLD.failed_logins,
                    client_ip = record.request and record.request.remote_address
                }
            )
            
            -- Marquer record
            record["_anomaly_detected"] = "brute_force_login"
            record["_anomaly_severity"] = "high"
        end
    end
end

-- =============================================================================
-- DÉTECTION 2: Excessive Secret Access (Data Exfiltration)
-- =============================================================================
function detect_excessive_secret_access(record)
    if record.type ~= "response" then
        return
    end
    
    -- Vérifier accès secret
    if record.request and record.request.path and record.request.path:match("^secret/data/") then
        local user = record.auth and record.auth.display_name or "unknown"
        
        -- Incrémenter compteur
        counters.secret_access[user] = (counters.secret_access[user] or 0) + 1
        
        -- Alerte si seuil dépassé
        if counters.secret_access[user] >= ALERT_THRESHOLD.secret_access_rate then
            send_pagerduty_alert(
                "warning",
                string.format("Excessive secret access: %s", user),
                {
                    user = user,
                    access_count = counters.secret_access[user],
                    threshold = ALERT_THRESHOLD.secret_access_rate,
                    time_window = "60 seconds"
                }
            )
            
            record["_anomaly_detected"] = "excessive_secret_access"
            record["_anomaly_severity"] = "medium"
        end
    end
end

-- =============================================================================
-- DÉTECTION 3: Privilege Escalation Attempts
-- =============================================================================
function detect_privilege_escalation(record)
    if record.type ~= "response" then
        return
    end
    
    -- Patterns suspects
    local suspicious_paths = {
        "sys/policies/",        -- Modification policies
        "sys/auth/",            -- Modification auth methods
        "sys/mounts/",          -- Modification secrets engines
        "auth/token/create-orphan",  -- Création tokens orphelins
        "sys/generate-root"     -- Génération root token
    }
    
    if record.request and record.request.path then
        for _, pattern in ipairs(suspicious_paths) do
            if record.request.path:match(pattern) then
                local user = record.auth and record.auth.display_name or "unknown"
                
                send_pagerduty_alert(
                    "critical",
                    string.format("Privilege escalation attempt: %s", user),
                    {
                        user = user,
                        path = record.request.path,
                        operation = record.request.operation,
                        client_ip = record.request.remote_address,
                        policies = record.auth and record.auth.policies
                    }
                )
                
                record["_anomaly_detected"] = "privilege_escalation"
                record["_anomaly_severity"] = "critical"
                break
            end
        end
    end
end

-- =============================================================================
-- DÉTECTION 4: Accès Heures Inhabituelles (22h-6h)
-- =============================================================================
function detect_unusual_hours(record)
    if not ALERT_THRESHOLD.unusual_hours then
        return
    end
    
    local hour = tonumber(os.date("%H"))
    
    -- Heures hors bureau (22h - 6h)
    if hour >= 22 or hour < 6 then
        local user = record.auth and record.auth.display_name or "unknown"
        
        -- Ignorer comptes service (AppRole)
        if user:match("^approle") then
            return
        end
        
        record["_anomaly_detected"] = "unusual_hours_access"
        record["_anomaly_severity"] = "low"
        record["_unusual_hour"] = hour
        
        -- Alerte PagerDuty (info severity)
        send_pagerduty_alert(
            "info",
            string.format("Unusual hours access: %s at %dh", user, hour),
            {
                user = user,
                hour = hour,
                path = record.request and record.request.path
            }
        )
    end
end

-- =============================================================================
-- DÉTECTION 5: Accès Secrets Sensibles (master-key, root, etc.)
-- =============================================================================
function detect_sensitive_secret_access(record)
    if record.type ~= "response" then
        return
    end
    
    local sensitive_patterns = {
        "master%-key",
        "root%-token",
        "admin%-password",
        "hsm%-pin",
        "recovery%-key"
    }
    
    if record.request and record.request.path then
        for _, pattern in ipairs(sensitive_patterns) do
            if record.request.path:match(pattern) then
                local user = record.auth and record.auth.display_name or "unknown"
                
                send_pagerduty_alert(
                    "critical",
                    string.format("Sensitive secret accessed: %s", user),
                    {
                        user = user,
                        secret_path = record.request.path,
                        operation = record.request.operation,
                        client_ip = record.request.remote_address
                    }
                )
                
                record["_anomaly_detected"] = "sensitive_secret_access"
                record["_anomaly_severity"] = "critical"
                break
            end
        end
    end
end

-- =============================================================================
-- DÉTECTION 6: Namespace Traversal (Enterprise Only)
-- =============================================================================
function detect_namespace_traversal(record)
    if record.request and record.request.path then
        -- Détection tentatives ../.. (path traversal)
        if record.request.path:match("%.%./") then
            local user = record.auth and record.auth.display_name or "unknown"
            
            send_pagerduty_alert(
                "critical",
                string.format("Path traversal attempt: %s", user),
                {
                    user = user,
                    path = record.request.path,
                    client_ip = record.request.remote_address
                }
            )
            
            record["_anomaly_detected"] = "path_traversal"
            record["_anomaly_severity"] = "critical"
        end
    end
end

-- =============================================================================
-- FONCTION PRINCIPALE: Détection Anomalies
-- =============================================================================
function detect_anomaly(tag, timestamp, record)
    -- Reset compteurs si nécessaire
    reset_counters_if_needed()
    
    -- Exécuter toutes les détections
    detect_failed_logins(record)
    detect_excessive_secret_access(record)
    detect_privilege_escalation(record)
    detect_unusual_hours(record)
    detect_sensitive_secret_access(record)
    detect_namespace_traversal(record)
    
    -- Retourner record modifié
    return 2, timestamp, record  -- Code 2 = modified
end

-- =============================================================================
-- NOTES CONFIGURATION
-- =============================================================================

--[[

CONFIGURATION REQUISE:
- Variable env: PAGERDUTY_INTEGRATION_KEY
- Ajuster ALERT_THRESHOLD selon votre contexte

PATTERNS DÉTECTÉS:
1. Brute force login (5+ échecs/min)
2. Data exfiltration (100+ accès secrets/min)
3. Privilege escalation (modification policies/auth)
4. Accès hors heures (22h-6h)
5. Secrets sensibles (master-key, root, etc.)
6. Path traversal (../ dans chemins)

TUNING:
- Threshold trop bas = false positives
- Threshold trop haut = missed attacks
- Adapter selon trafic normal de votre banque

PERFORMANCE:
- Compteurs en mémoire (pas de DB externe)
- Reset automatique toutes les 60s
- Overhead: < 1ms par log

FAUX POSITIFS COMMUNS:
- AppRole accès massif secrets = Normal pour apps
- Admin accès 23h = Maintenance planifiée
- Batch jobs = Ajuster whitelist

AMÉLIORATION FUTURE:
- Machine Learning (baseline comportement normal)
- Correlation multi-logs (attack chains)
- Geo-IP filtering (accès depuis pays suspects)

]]
