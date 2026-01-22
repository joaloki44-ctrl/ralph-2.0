#!/bin/bash
#
# VAULT ENCRYPTED SNAPSHOT RESTORE SCRIPT
# ========================================
# Description: Restauration snapshot Raft chiffré depuis S3
# Usage: ./vault-restore-encrypted.sh <snapshot-filename>
# Exemple: ./vault-restore-encrypted.sh vault-snapshot-20250120-120000.snap.enc
#
# ATTENTION: Ce script arrête Vault et restaure l'état complet.
#            Utiliser UNIQUEMENT en cas de disaster recovery.
#

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CONFIGURATION
# =============================================================================

VAULT_ADDR="${VAULT_ADDR:-https://localhost:8200}"
VAULT_CACERT="${VAULT_CACERT:-/vault/tls/ca.pem}"

S3_BUCKET="${VAULT_S3_BUCKET:-s3://vault-backups-prod}"
S3_REGION="${VAULT_S3_REGION:-fr-par}"
S3_ENDPOINT="${VAULT_S3_ENDPOINT:-https://s3.fr-par.scw.cloud}"

TEMP_DIR="/tmp/vault-restore-$$"
LOG_FILE="/var/log/vault/restore.log"

# =============================================================================
# FONCTIONS
# =============================================================================

log() {
    local level="$1"
    shift
    echo "[$(date -Iseconds)] [$level] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR" "$1"
    cleanup
    exit 1
}

cleanup() {
    log "INFO" "Nettoyage fichiers temporaires..."
    if [ -d "$TEMP_DIR" ]; then
        # Suppression sécurisée (shred sur fichiers sensibles)
        find "$TEMP_DIR" -type f -exec shred -uvz {} \; 2>/dev/null || true
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

confirm_restore() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  ⚠️  ATTENTION - OPÉRATION CRITIQUE DE RESTORE"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Cette opération va:"
    echo "  1. Arrêter Vault sur ce node"
    echo "  2. Remplacer TOUTES les données Raft existantes"
    echo "  3. Restaurer l'état depuis: $1"
    echo ""
    echo "Perte de données possible depuis la date du snapshot!"
    echo ""
    read -p "Confirmez-vous cette opération? (tapez 'YES' en majuscules): " confirm
    
    if [ "$confirm" != "YES" ]; then
        log "INFO" "Restore annulé par l'utilisateur"
        exit 0
    fi
    
    echo ""
    read -p "Dernière confirmation - tapez le nom du fichier snapshot: " confirm_file
    
    if [ "$confirm_file" != "$(basename $1)" ]; then
        error_exit "Nom de fichier incorrect. Restore annulé."
    fi
}

# =============================================================================
# VALIDATION ARGUMENTS
# =============================================================================

if [ $# -ne 1 ]; then
    echo "Usage: $0 <snapshot-filename>"
    echo "Exemple: $0 vault-snapshot-20250120-120000.snap.enc"
    echo ""
    echo "Snapshots disponibles:"
    aws s3 ls "${S3_BUCKET}/snapshots/" \
      --endpoint-url="$S3_ENDPOINT" \
      --region="$S3_REGION" | tail -10
    exit 1
fi

SNAPSHOT_FILENAME="$1"
SNAPSHOT_PATH="${TEMP_DIR}/${SNAPSHOT_FILENAME}"
HMAC_PATH="${SNAPSHOT_PATH}.hmac"

# Vérification privilèges root
if [ "$EUID" -ne 0 ]; then
    error_exit "Ce script doit être exécuté en tant que root"
fi

# Confirmation interactive
confirm_restore "$SNAPSHOT_FILENAME"

log "INFO" "=== DÉBUT RESTORE VAULT SNAPSHOT ==="
log "INFO" "Snapshot: $SNAPSHOT_FILENAME"

# =============================================================================
# PHASE 1: TÉLÉCHARGEMENT DEPUIS S3
# =============================================================================

mkdir -p "$TEMP_DIR"

log "INFO" "Téléchargement snapshot depuis S3..."

aws s3 cp \
  "${S3_BUCKET}/snapshots/${SNAPSHOT_FILENAME}" \
  "$SNAPSHOT_PATH" \
  --endpoint-url="$S3_ENDPOINT" \
  --region="$S3_REGION" \
  || error_exit "Échec téléchargement snapshot depuis S3"

aws s3 cp \
  "${S3_BUCKET}/snapshots/${SNAPSHOT_FILENAME}.hmac" \
  "$HMAC_PATH" \
  --endpoint-url="$S3_ENDPOINT" \
  --region="$S3_REGION" \
  || error_exit "Échec téléchargement HMAC depuis S3"

log "INFO" "Snapshot téléchargé: $(stat -f%z "$SNAPSHOT_PATH" 2>/dev/null || stat -c%s "$SNAPSHOT_PATH") bytes"

# =============================================================================
# PHASE 2: VÉRIFICATION INTÉGRITÉ HMAC
# =============================================================================

log "INFO" "Vérification intégrité HMAC..."

EXPECTED_HMAC=$(cat "$HMAC_PATH")
log "INFO" "HMAC attendu: ${EXPECTED_HMAC:0:32}..."

# Calcul HMAC via Vault Transit
ACTUAL_HMAC=$(vault write -field=hmac transit/hmac/snapshot-key \
  input="$(base64 -w 0 < "$SNAPSHOT_PATH")") \
  || error_exit "Échec calcul HMAC"

log "INFO" "HMAC calculé: ${ACTUAL_HMAC:0:32}..."

if [ "$EXPECTED_HMAC" != "$ACTUAL_HMAC" ]; then
    error_exit "HMAC MISMATCH! Snapshot corrompu ou altéré. Restore annulé."
fi

log "INFO" "Intégrité HMAC vérifiée ✓"

# =============================================================================
# PHASE 3: DÉCHIFFREMENT VIA VAULT TRANSIT
# =============================================================================

log "INFO" "Déchiffrement snapshot via Transit engine..."

# Lecture ciphertext
CIPHERTEXT=$(cat "$SNAPSHOT_PATH")

# Déchiffrement via Transit
PLAINTEXT_B64=$(vault write -field=plaintext transit/decrypt/snapshot-key \
  ciphertext="$CIPHERTEXT") \
  || error_exit "Échec déchiffrement snapshot"

# Décodage base64 → snapshot Raft clair
DECRYPTED_SNAPSHOT="${TEMP_DIR}/vault-snapshot-decrypted.snap"
echo "$PLAINTEXT_B64" | base64 -d > "$DECRYPTED_SNAPSHOT"

log "INFO" "Snapshot déchiffré: $(stat -f%z "$DECRYPTED_SNAPSHOT" 2>/dev/null || stat -c%s "$DECRYPTED_SNAPSHOT") bytes"

# =============================================================================
# PHASE 4: ARRÊT VAULT
# =============================================================================

log "WARN" "Arrêt du service Vault..."

systemctl stop vault || error_exit "Échec arrêt Vault"

# Attente arrêt complet
sleep 5

if systemctl is-active --quiet vault; then
    error_exit "Vault encore actif après arrêt"
fi

log "INFO" "Vault arrêté ✓"

# =============================================================================
# PHASE 5: BACKUP ÉTAT ACTUEL (SÉCURITÉ)
# =============================================================================

log "INFO" "Sauvegarde état actuel (rollback possible)..."

BACKUP_DIR="/vault/data-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

if [ -d "/vault/data" ]; then
    cp -a /vault/data/* "$BACKUP_DIR/" || log "WARN" "Backup partiel de l'état actuel"
    log "INFO" "Backup actuel sauvegardé: $BACKUP_DIR"
fi

# =============================================================================
# PHASE 6: RESTORE RAFT SNAPSHOT
# =============================================================================

log "INFO" "Restauration snapshot Raft..."

# Utilisation vault operator raft snapshot restore
vault operator raft snapshot restore -force "$DECRYPTED_SNAPSHOT" \
  || error_exit "Échec restore snapshot Raft"

log "INFO" "Snapshot Raft restauré ✓"

# =============================================================================
# PHASE 7: REDÉMARRAGE VAULT
# =============================================================================

log "INFO" "Redémarrage Vault..."

systemctl start vault || error_exit "Échec démarrage Vault"

# Attente démarrage
sleep 10

# Healthcheck
log "INFO" "Vérification healthcheck..."

RETRIES=12
for i in $(seq 1 $RETRIES); do
    if vault status >/dev/null 2>&1; then
        log "INFO" "Vault démarré ✓"
        break
    fi
    
    if [ $i -eq $RETRIES ]; then
        error_exit "Vault ne répond pas après restore"
    fi
    
    log "INFO" "Attente démarrage Vault... ($i/$RETRIES)"
    sleep 5
done

# =============================================================================
# PHASE 8: VALIDATION POST-RESTORE
# =============================================================================

log "INFO" "Validation post-restore..."

# Vérification seal status
SEAL_STATUS=$(vault status -format=json | jq -r '.sealed')
log "INFO" "Seal status: $SEAL_STATUS"

if [ "$SEAL_STATUS" = "true" ]; then
    log "WARN" "Vault est SEALED après restore (normal si auto-unseal HSM configuré)"
    log "INFO" "Vault devrait s'unsealer automatiquement via HSM..."
    
    # Attente auto-unseal
    sleep 30
    
    SEAL_STATUS=$(vault status -format=json | jq -r '.sealed')
    if [ "$SEAL_STATUS" = "true" ]; then
        error_exit "Vault toujours SEALED après 30s. Vérifier HSM."
    fi
fi

log "INFO" "Vault unsealed ✓"

# Vérification version
VAULT_VERSION=$(vault status -format=json | jq -r '.version')
log "INFO" "Version Vault: $VAULT_VERSION"

# Test lecture secret (si accessible)
if vault kv list secret/ >/dev/null 2>&1; then
    SECRET_COUNT=$(vault kv list -format=json secret/ | jq '. | length')
    log "INFO" "Secrets accessibles: $SECRET_COUNT dans secret/"
fi

# =============================================================================
# PHASE 9: NETTOYAGE SÉCURISÉ
# =============================================================================

log "INFO" "Suppression sécurisée snapshot déchiffré..."

shred -uvz "$DECRYPTED_SNAPSHOT" || log "WARN" "Shred non disponible, utilisation rm"
rm -f "$SNAPSHOT_PATH" "$HMAC_PATH"

# =============================================================================
# FIN
# =============================================================================

log "INFO" "═══════════════════════════════════════════════════════════════"
log "INFO" "  ✅ RESTORE TERMINÉ AVEC SUCCÈS"
log "INFO" "═══════════════════════════════════════════════════════════════"
log "INFO" ""
log "INFO" "Snapshot restauré: $SNAPSHOT_FILENAME"
log "INFO" "Backup ancien état: $BACKUP_DIR"
log "INFO" "Vault status: UNSEALED"
log "INFO" ""
log "INFO" "Actions recommandées:"
log "INFO" "  1. Vérifier accès applications: vault kv list secret/"
log "INFO" "  2. Tester authentification: vault login -method=ldap"
log "INFO" "  3. Consulter audit logs: tail -f /vault/audit/audit.log"
log "INFO" "  4. Notifier équipes de la restauration"
log "INFO" ""
log "INFO" "En cas de problème, rollback possible depuis: $BACKUP_DIR"
log "INFO" "═══════════════════════════════════════════════════════════════"

exit 0
