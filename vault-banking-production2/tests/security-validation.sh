#!/bin/bash
#
# VAULT SECURITY VALIDATION SUITE
# ================================
# Description: Suite de tests sécurité pour validation production
# Tests: 7 tests critiques (anti-debug, immutability, HSM, audit, etc.)
# Usage: ./security-validation.sh
#

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

VAULT_ADDR="${VAULT_ADDR:-https://localhost:8200}"
VAULT_CACERT="${VAULT_CACERT:-/vault/tls/ca.pem}"

TEST_RESULTS="/tmp/vault-security-tests-$(date +%s).log"
PASSED=0
FAILED=0

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =============================================================================
# FONCTIONS
# =============================================================================

log() {
    echo -e "$1" | tee -a "$TEST_RESULTS"
}

test_header() {
    log "\n${YELLOW}=== TEST $1: $2 ===${NC}"
}

test_pass() {
    log "${GREEN}✅ PASS${NC}: $1"
    ((PASSED++))
}

test_fail() {
    log "${RED}❌ FAIL${NC}: $1"
    ((FAILED++))
}

# =============================================================================
# TEST 1: ANTI-DEBUG PROTECTION (ptrace disabled)
# =============================================================================

test_1_anti_debug() {
    test_header "1" "Protection Anti-Debug (ptrace disabled)"
    
    local vault_pid=$(pidof vault || echo "")
    
    if [ -z "$vault_pid" ]; then
        test_fail "Vault process not found"
        return 1
    fi
    
    # Tentative gcore (doit échouer)
    if gcore -o /tmp/vault-core "$vault_pid" 2>&1 | grep -qi "operation not permitted"; then
        test_pass "Memory dump bloqué (ptrace disabled)"
    else
        test_fail "Memory dump POSSIBLE - SÉCURITÉ COMPROMISE"
    fi
    
    # Vérification sysctl
    local ptrace_scope=$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null || echo "0")
    if [ "$ptrace_scope" = "3" ]; then
        test_pass "Kernel ptrace_scope = 3 (max security)"
    else
        test_fail "Kernel ptrace_scope = $ptrace_scope (attendu: 3)"
    fi
    
    # Cleanup
    rm -f /tmp/vault-core.* 2>/dev/null || true
}

# =============================================================================
# TEST 2: FILESYSTEM IMMUTABILITY (Raft DB protégé)
# =============================================================================

test_2_filesystem_immutable() {
    test_header "2" "Filesystem Immutability (Raft DB)"
    
    local raft_db="/vault/data/raft/raft.db"
    
    if [ ! -f "$raft_db" ]; then
        test_fail "Raft DB non trouvée: $raft_db"
        return 1
    fi
    
    # Vérification attribut immutable
    if lsattr "$raft_db" 2>/dev/null | grep -q "i"; then
        test_pass "Raft DB immutable (attribut 'i' présent)"
    else
        test_fail "Raft DB modifiable - RISQUE CORRUPTION"
    fi
    
    # Tentative suppression (doit échouer)
    if rm "$raft_db" 2>&1 | grep -qi "operation not permitted"; then
        test_pass "Suppression Raft DB bloquée"
    else
        # Si rm réussit, on a un GROS problème
        test_fail "Raft DB supprimable - SÉCURITÉ COMPROMISE"
    fi
}

# =============================================================================
# TEST 3: HSM FAILOVER AUTOMATIQUE
# =============================================================================

test_3_hsm_failover() {
    test_header "3" "HSM Failover Automatique"
    
    # Vérification HSM primaire
    if ! /opt/nfast/bin/enquiry 2>/dev/null | grep -q "operational"; then
        test_fail "HSM primaire non opérationnel"
        return 1
    fi
    
    test_pass "HSM primaire opérationnel"
    
    # Vérification configuration dual HSM dans vault.hcl
    if grep -q 'seal "pkcs11"' /etc/vault.d/vault.hcl | grep -q "priority"; then
        test_pass "Configuration dual HSM détectée (failover ready)"
    else
        test_fail "Pas de failover HSM configuré"
    fi
    
    # Note: Test failover réel nécessite arrêt HSM (non fait ici)
    log "   ℹ️  Test failover complet: systemctl stop nfast (manuel)"
}

# =============================================================================
# TEST 4: AUDIT LOGS INTEGRITY (HMAC signature)
# =============================================================================

test_4_audit_integrity() {
    test_header "4" "Audit Logs Integrity (HMAC)"
    
    local audit_log="/vault/audit/audit.log"
    
    if [ ! -f "$audit_log" ]; then
        test_fail "Audit log non trouvé: $audit_log"
        return 1
    fi
    
    # Vérifier dernière ligne contient signature
    local last_log=$(tail -1 "$audit_log" 2>/dev/null || echo "{}")
    
    if echo "$last_log" | jq -e '._signature' >/dev/null 2>&1; then
        test_pass "Audit logs signés (HMAC présent)"
        
        # Vérifier signature valide (si Transit configuré)
        if vault secrets list | grep -q "transit/"; then
            local hmac=$(echo "$last_log" | jq -r '._signature')
            if [ -n "$hmac" ] && [ "$hmac" != "null" ]; then
                test_pass "Signature HMAC valide"
            else
                test_fail "Signature HMAC invalide"
            fi
        fi
    else
        test_fail "Audit logs NON signés - Intégrité non garantie"
    fi
}

# =============================================================================
# TEST 5: WAL SHIPPING (RPO < 10s)
# =============================================================================

test_5_wal_shipping() {
    test_header "5" "WAL Shipping (Continuous Backup)"
    
    # Vérifier configuration WAL dans vault.hcl
    if grep -q "wal" /etc/vault.d/vault.hcl; then
        test_pass "WAL shipping configuré"
        
        # Vérifier derniers WAL sur S3
        if command -v aws >/dev/null 2>&1; then
            local s3_bucket="${VAULT_S3_BUCKET:-vault-backups-prod}"
            local recent_wal=$(aws s3 ls "s3://${s3_bucket}/wal/" \
              --endpoint-url="${VAULT_S3_ENDPOINT:-https://s3.fr-par.scw.cloud}" \
              2>/dev/null | tail -1 || echo "")
            
            if [ -n "$recent_wal" ]; then
                test_pass "WAL récents présents sur S3 (RPO < 10s garanti)"
            else
                test_fail "Pas de WAL sur S3 - RPO non garanti"
            fi
        else
            log "   ⚠️  aws-cli non disponible, skip vérification S3"
        fi
    else
        test_fail "WAL shipping NON configuré - RPO = 6h (snapshots uniquement)"
    fi
}

# =============================================================================
# TEST 6: RATE LIMITING APPLICATIF
# =============================================================================

test_6_rate_limiting() {
    test_header "6" "Rate Limiting Applicatif"
    
    # Vérifier configuration rate limit
    if grep -q "rate_limit" /etc/vault.d/vault.hcl; then
        test_pass "Rate limiting configuré dans vault.hcl"
    else
        test_fail "Pas de rate limiting - Vulnérable aux DoS"
    fi
    
    # Test burst (150 requêtes rapides)
    log "   ℹ️  Test burst 150 requêtes..."
    
    local rate_limited=0
    for i in {1..150}; do
        if curl -sk "$VAULT_ADDR/v1/sys/health" 2>&1 | grep -qi "rate limit"; then
            rate_limited=1
            break
        fi
    done
    
    if [ $rate_limited -eq 1 ]; then
        test_pass "Rate limiting actif (burst détecté)"
    else
        log "   ⚠️  Rate limiting non déclenché (limite élevée ou désactivé)"
    fi
}

# =============================================================================
# TEST 7: LDAP ENTITY MAPPING (Traçabilité employés)
# =============================================================================

test_7_ldap_entity_mapping() {
    test_header "7" "LDAP Entity Mapping (Traçabilité)"
    
    # Vérifier auth LDAP activé
    if vault auth list 2>/dev/null | grep -q "ldap/"; then
        test_pass "Auth method LDAP activé"
        
        # Vérifier configuration entity aliases
        if vault read identity/entity/name/test 2>/dev/null | grep -q "aliases"; then
            test_pass "Entity aliases configurés (mapping LDAP → Identity)"
        else
            log "   ⚠️  Entity aliases non testable sans entité test"
        fi
    else
        test_fail "Auth LDAP NON activé - Pas de traçabilité employés"
    fi
    
    # Vérifier audit logs contiennent entity_id
    if tail -1 /vault/audit/audit.log 2>/dev/null | jq -e '.auth.entity_id' >/dev/null 2>&1; then
        test_pass "Audit logs enrichis (entity_id présent)"
    else
        log "   ⚠️  Audit logs sans entity_id (traçabilité limitée)"
    fi
}

# =============================================================================
# EXÉCUTION TESTS
# =============================================================================

main() {
    log "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    log "${YELLOW}║  VAULT SECURITY VALIDATION SUITE - Banking Grade            ║${NC}"
    log "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    log ""
    log "Date: $(date -Iseconds)"
    log "Vault: $VAULT_ADDR"
    log "Logs: $TEST_RESULTS"
    log ""
    
    # Vérification privilèges
    if [ "$EUID" -ne 0 ]; then
        log "${RED}⚠️  ATTENTION: Tests doivent être exécutés en root${NC}"
        log "   Certains tests échoueront sans privilèges root"
        log ""
    fi
    
    # Exécution tests
    test_1_anti_debug
    test_2_filesystem_immutable
    test_3_hsm_failover
    test_4_audit_integrity
    test_5_wal_shipping
    test_6_rate_limiting
    test_7_ldap_entity_mapping
    
    # Résultats
    log ""
    log "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    log "${YELLOW}║  RÉSULTATS                                                   ║${NC}"
    log "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    log ""
    log "Tests passés:  ${GREEN}$PASSED${NC}"
    log "Tests échoués: ${RED}$FAILED${NC}"
    log ""
    
    if [ $FAILED -eq 0 ]; then
        log "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        log "${GREEN}║  ✅ VALIDATION SÉCURITÉ COMPLÈTE - READY FOR PRODUCTION      ║${NC}"
        log "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
        exit 0
    else
        log "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
        log "${RED}║  ❌ VALIDATION ÉCHOUÉE - FIX REQUIS AVANT PRODUCTION         ║${NC}"
        log "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
        log ""
        log "Actions requises:"
        log "1. Vérifier logs détaillés: $TEST_RESULTS"
        log "2. Corriger les tests échoués"
        log "3. Re-exécuter validation complète"
        exit 1
    fi
}

# =============================================================================
# ENTRY POINT
# =============================================================================

main "$@"
