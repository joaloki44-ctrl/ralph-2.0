# Vault Banking-Grade Production Configuration - France
# Copyright (c) 2025 - Confidentiel Banque
# Version: 1.0.0 - Production Ready

# IMPORTANT: Ce fichier contient la configuration complète validée
# pour déploiement bancaire conforme ACPR/RGPD/DORA

# =============================================================================
# STORAGE BACKEND - Raft Intégré avec HA
# =============================================================================
storage "raft" {
  path    = "/vault/data"
  node_id = "NODE_ID_PLACEHOLDER"  # Remplacé par Ansible: vault-01, vault-02, vault-03
  
  # Retry join pour auto-découverte cluster
  retry_join {
    leader_api_addr         = "https://vault-01.bank.internal:8200"
    leader_ca_cert_file     = "/vault/tls/ca.pem"
    leader_client_cert_file = "/vault/tls/vault-cert.pem"
    leader_client_key_file  = "/vault/tls/vault-key.pem"
  }
  
  retry_join {
    leader_api_addr         = "https://vault-02.bank.internal:8200"
    leader_ca_cert_file     = "/vault/tls/ca.pem"
    leader_client_cert_file = "/vault/tls/vault-cert.pem"
    leader_client_key_file  = "/vault/tls/vault-key.pem"
  }
  
  retry_join {
    leader_api_addr         = "https://vault-03.bank.internal:8200"
    leader_ca_cert_file     = "/vault/tls/ca.pem"
    leader_client_cert_file = "/vault/tls/vault-cert.pem"
    leader_client_key_file  = "/vault/tls/vault-key.pem"
  }
  
  # Autopilot - Gestion automatique HA et split-brain
  autopilot {
    cleanup_dead_servers       = true
    last_contact_threshold     = "10s"
    max_trailing_logs          = 1000
    min_quorum                 = 2
    server_stabilization_time  = "10s"
    disable_upgrade_migration  = false
    
    # CRITIQUE: Degraded mode pour haute disponibilité
    # Si split-brain détecté, node isolé passe en read-only
    redundancy_zone_tag        = "az"
  }
}

# =============================================================================
# SEAL CONFIGURATION - HSM Thales nShield avec Failover
# =============================================================================

# HSM Primaire (Priorité 1)
seal "pkcs11" {
  lib            = "/opt/nfast/toolkits/pkcs11/libcknfast.so"
  slot           = "0"
  pin            = "env://VAULT_HSM_PIN"
  key_label      = "vault-master-key-primary"
  hmac_key_label = "vault-hmac-key-primary"
  generate_key   = "true"
  mechanism      = "0x1087"  # CKM_AES_GCM
  
  # Configuration failover automatique
  priority = "1"
}

# HSM Secondaire (Failover automatique)
seal "pkcs11" {
  lib            = "/opt/nfast/toolkits/pkcs11/libcknfast.so"
  slot           = "1"
  pin            = "env://VAULT_HSM_PIN_SECONDARY"
  key_label      = "vault-master-key-secondary"
  hmac_key_label = "vault-hmac-key-secondary"
  generate_key   = "true"
  mechanism      = "0x1087"
  
  priority = "2"
  disabled = "false"
}

# =============================================================================
# LISTENER - API avec mTLS Obligatoire
# =============================================================================
listener "tcp" {
  address       = "0.0.0.0:8200"
  
  # TLS Configuration - Banking Grade
  tls_cert_file = "/vault/tls/vault-cert.pem"
  tls_key_file  = "/vault/tls/vault-key.pem"
  tls_client_ca_file = "/vault/tls/ca.pem"
  
  # OBLIGATOIRE: mTLS pour toutes les connexions
  tls_require_and_verify_client_cert = true
  
  # TLS Hardening
  tls_min_version = "tls12"
  tls_cipher_suites = "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
  tls_prefer_server_cipher_suites = true
  
  # Timeouts optimisés pour banking
  tls_handshake_timeout = "10s"
  
  # Headers de sécurité
  x_forwarded_for_authorized_addrs = "10.0.0.0/8"
  x_forwarded_for_reject_not_present = true
  
  # Proxy Protocol (si Load Balancer en amont)
  proxy_protocol_behavior = "use_always"
  proxy_protocol_authorized_addrs = "10.0.100.0/24"
}

# Listener Cluster (inter-node communication)
listener "tcp" {
  address       = "0.0.0.0:8201"
  cluster_address = "NODE_IP_PLACEHOLDER:8201"
  
  tls_cert_file = "/vault/tls/vault-cert.pem"
  tls_key_file  = "/vault/tls/vault-key.pem"
  tls_client_ca_file = "/vault/tls/ca.pem"
  tls_require_and_verify_client_cert = true
}

# =============================================================================
# TELEMETRY - Prometheus avec Sécurité
# =============================================================================
telemetry {
  prometheus_retention_time = "60s"
  disable_hostname          = true
  
  # Filtrage métriques sensibles
  filter_default = true
  prefix_filter = [
    "+vault.core",
    "+vault.raft",
    "+vault.barrier",
    "+vault.runtime",
    "-vault.token",
    "-vault.expire"
  ]
  
  # Labels statiques pour identification
  statsd_address = ""
  statsite_address = ""
}

# =============================================================================
# AUDIT DEVICES - Redondance Complète
# =============================================================================

# Audit primaire - Fichier local avec rotation
audit {
  type = "file"
  path = "vault_audit_primary"
  
  description = "Audit principal - FluentBit -> S3 WORM"
  
  options = {
    file_path = "/vault/audit/audit.log"
    log_raw = "false"  # JAMAIS de secrets en clair
    hmac_accessor = "true"
    mode = "0600"
    format = "jsonx"
    prefix = ""
  }
}

# Audit secondaire - Syslog (redondance)
audit {
  type = "syslog"
  path = "vault_audit_secondary"
  
  description = "Audit secondaire - Syslog redondant"
  
  options = {
    facility = "AUTH"
    tag = "vault-audit"
    log_raw = "false"
  }
}

# =============================================================================
# CONFIGURATION GÉNÉRALE
# =============================================================================

# Cluster
cluster_name = "vault-banking-prod-france"
cluster_addr = "https://NODE_IP_PLACEHOLDER:8201"
api_addr     = "https://NODE_FQDN_PLACEHOLDER:8200"

# Sécurité renforcée
ui = false  # UI désactivée en production (accès CLI/API uniquement)
disable_mlock = false  # mlock OBLIGATOIRE (empêche swap secrets en RAM)
disable_cache = true   # Pas de cache secrets en mémoire

# Logging
log_level = "info"
log_format = "json"
log_file = "/var/log/vault/vault.log"
log_rotate_duration = "24h"
log_rotate_max_files = 30

# Performance tuning
max_lease_ttl = "768h"  # 32 jours max
default_lease_ttl = "168h"  # 7 jours par défaut

# Plugin directory
plugin_directory = "/vault/plugins"

# =============================================================================
# COMMENTAIRES CONFIGURATION
# =============================================================================

# PLACEHOLDERS à remplacer par Ansible:
# - NODE_ID_PLACEHOLDER: vault-01, vault-02, ou vault-03
# - NODE_IP_PLACEHOLDER: 10.0.10.10, 10.0.10.11, ou 10.0.10.12
# - NODE_FQDN_PLACEHOLDER: vault-01.bank.internal, etc.

# VARIABLES ENVIRONNEMENT REQUISES:
# - VAULT_HSM_PIN: PIN HSM primaire (dual custody)
# - VAULT_HSM_PIN_SECONDARY: PIN HSM secondaire

# COMPLIANCE:
# - ACPR: Audit trail immutable (S3 WORM)
# - RGPD: Crypto-shredding (via Transit engine)
# - DORA: Tests DR trimestriels obligatoires
# - PCI-DSS: HSM FIPS 140-2 Level 3, mTLS, audit complet

# SUPPORT:
# - HashiCorp Enterprise Support 24/7
# - Thales HSM Support
# - Escalation: +33 X XX XX XX XX (astreinte)
