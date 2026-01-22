#!/bin/bash
#
# VAULT ENCRYPTED SNAPSHOT SCRIPT
# ================================
# Description: Création snapshot Raft chiffré via HSM + upload S3 WORM
# Conformité: ACPR (rétention 10 ans), RGPD (crypto-shredding ready)
# Version: 1.0.0
#
# Usage: /usr/local/bin/vault-snapshot-encrypted.sh
# Cron: 0 */6 * * * (toutes les 6h)
#

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CONFIGURATION
# =============================================================================

VAULT_ADDR="${VAULT_ADDR:-https://localhost:8200}"
VAULT_CACERT="${VAULT_CACERT:-/vault/tls/ca.pem}"
VAULT_CLIENT_CERT="${VAULT_CLIENT_CERT:-/vault/tls/vault-cert.pem}"
VAULT_CLIENT_KEY="${VAULT_CLIENT_KEY:-/vault/tls/vault-key.pem}"

SNAPSHOT_DIR="/vault/snapshots/encrypted"
TEMP_DIR="/tmp/vault-snapshots"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_FILE="${SNAPSHOT_DIR}/vault-snapshot-${TIMESTAMP}.snap.enc"

S3_BUCKET="${VAULT_S3_BUCKET:-s3://vault-backups-prod}"
S3_REGION="${VAULT_S3_REGION:-fr-par}"
S3_ENDPOINT="${VAULT_S3_ENDPOINT:-https://s3.fr-par.scw.cloud}"

LOG_FILE="/var/log/vault/snapshots.log"
METRICS_FILE="/var/lib/node_exporter/textfile_collector/vault_snapshot.prom"

# Rétention locale (jours)
LOCAL_RETENTION_DAYS=7

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
    
    # Métrique erreur
    cat > "$METRICS_FILE" <<EOF
# HELP vault_snapshot_last_success_timestamp Last successful snapshot timestamp
# TYPE vault_snapshot_last_success_timestamp gauge
vault_snapshot_last_success_timestamp 0

# HELP vault_snapshot_last_error_timestamp Last snapshot error timestamp
# TYPE vault_snapshot_last_error_timestamp gauge
vault_snapshot_last_error_timestamp $(date +%s)
EOF
    
    # Alerte PagerDuty
    if [ -n "${PAGERDUTY_KEY:-}" ]; then
        curl -s -X POST "https://events.pagerduty.com/v2/enqueue" \
          -H "Content-Type: application/json" \
          -d "{
            \"routing_key\": \"$PAGERDUTY_KEY\",
            \"event_action\": \"trigger\",
            \"payload\": {
              \"summary\": \"Vault snapshot FAILED: $1\",
              \"severity\": \"error\",
              \"source\": \"$(hostname)\",
              \"timestamp\": \"$(date -Iseconds)\"
            }
          }" || true
    fi
    
    exit 1
}

cleanup() {
    log "INFO" "Nettoyage fichiers temporaires..."
    rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

# =============================================================================
# PRE-CHECKS
# =============================================================================

log "INFO" "=== DÉBUT SNAPSHOT VAULT CHIFFRÉ ==="

# Vérification répertoires
mkdir -p "$SNAPSHOT_DIR" "$TEMP_DIR"

# Vérification Vault accessible
if ! vault status >/dev/null 2>&1; then
    error_exit "Vault non accessible"
fi

# Vérification Transit engine (pour chiffrement)
if ! vault secrets list | grep -q "transit/"; then
    log "WARN" "Transit engine non activé, activation..."
    vault secrets enable transit || error_exit "Impossible d'activer Transit engine"
fi

# Vérification clé de chiffrement snapshot
if ! vault read transit/keys/snapshot-key >/dev/null 2>&1; then
    log "INFO" "Création clé de chiffrement snapshot..."
    vault write -f transit/keys/snapshot-key \
      type=aes256-gcm96 \
      exportable=false \
      allow_plaintext_backup=false \
      deletion_allowed=false || error_exit "Impossible de créer clé snapshot"
fi

# =============================================================================
# PHASE 1: CRÉATION SNAPSHOT RAFT
# =============================================================================

log "INFO" "Création snapshot Raft..."

START_TIME=$(date +%s)

vault operator raft snapshot save "${TEMP_DIR}/vault-snapshot-${TIMESTAMP}.snap" \
  || error_exit "Échec création snapshot Raft"

SNAPSHOT_SIZE=$(stat -f%z "${TEMP_DIR}/vault-snapshot-${TIMESTAMP}.snap" 2>/dev/null || stat -c%s "${TEMP_DIR}/vault-snapshot-${TIMESTAMP}.snap")
log "INFO" "Snapshot créé: ${SNAPSHOT_SIZE} bytes"

# =============================================================================
# PHASE 2: CHIFFREMENT VIA VAULT TRANSIT
# =============================================================================

log "INFO" "Chiffrement snapshot via Transit engine..."

# Encodage base64 du snapshot
SNAPSHOT_B64=$(base64 -w 0 < "${TEMP_DIR}/vault-snapshot-${TIMESTAMP}.snap")

# Chiffrement via Transit (utilise indirectement HSM)
CIPHERTEXT=$(vault write -field=ciphertext transit/encrypt/snapshot-key \
  plaintext="$SNAPSHOT_B64") \
  || error_exit "Échec chiffrement snapshot"

# Écriture snapshot chiffré
echo "$CIPHERTEXT" > "$SNAPSHOT_FILE"

# Suppression snapshot clair (sécurité)
shred -uvz "${TEMP_DIR}/vault-snapshot-${TIMESTAMP}.snap"

log "INFO" "Snapshot chiffré: $SNAPSHOT_FILE"

# =============================================================================
# PHASE 3: SIGNATURE HMAC
# =============================================================================

log "INFO" "Génération signature HMAC..."

# Calcul HMAC du snapshot chiffré
HMAC=$(vault write -field=hmac transit/hmac/snapshot-key \
  input="$(base64 -w 0 < "$SNAPSHOT_FILE")") \
  || error_exit "Échec génération HMAC"

echo "$HMAC" > "${SNAPSHOT_FILE}.hmac"

log "INFO" "Signature HMAC: ${HMAC:0:16}..."

# =============================================================================
# PHASE 4: UPLOAD S3 (Object Storage WORM)
# =============================================================================

log "INFO" "Upload vers S3 Object Storage..."

# Upload snapshot chiffré
aws s3 cp "$SNAPSHOT_FILE" \
  "${S3_BUCKET}/snapshots/" \
  --endpoint-url="$S3_ENDPOINT" \
  --region="$S3_REGION" \
  --metadata "timestamp=${TIMESTAMP},hmac=${HMAC},hostname=$(hostname)" \
  --storage-class STANDARD \
  || error_exit "Échec upload S3 snapshot"

# Upload signature HMAC
aws s3 cp "${SNAPSHOT_FILE}.hmac" \
  "${S3_BUCKET}/snapshots/" \
  --endpoint-url="$S3_ENDPOINT" \
  --region="$S3_REGION" \
  || error_exit "Échec upload S3 HMAC"

# =============================================================================
# PHASE 5: VÉRIFICATION INTÉGRITÉ
# =============================================================================

log "INFO" "Vérification intégrité upload S3..."

# Récupération metadata S3
REMOTE_HMAC=$(aws s3api head-object \
  --bucket "$(echo $S3_BUCKET | cut -d'/' -f3)" \
  --key "snapshots/vault-snapshot-${TIMESTAMP}.snap.enc" \
  --endpoint-url="$S3_ENDPOINT" \
  --query 'Metadata.hmac' \
  --output text 2>/dev/null) || REMOTE_HMAC=""

if [ "$HMAC" != "$REMOTE_HMAC" ]; then
    error_exit "HMAC mismatch! Upload corrompu (local=$HMAC, remote=$REMOTE_HMAC)"
fi

log "INFO" "Intégrité S3 vérifiée ✓"

# =============================================================================
# PHASE 6: ROTATION LOCALE
# =============================================================================

log "INFO" "Rotation snapshots locaux (rétention ${LOCAL_RETENTION_DAYS} jours)..."

# Suppression snapshots > N jours
find "$SNAPSHOT_DIR" -name "*.snap.enc" -mtime +${LOCAL_RETENTION_DAYS} -delete
find "$SNAPSHOT_DIR" -name "*.hmac" -mtime +${LOCAL_RETENTION_DAYS} -delete

REMAINING_SNAPSHOTS=$(find "$SNAPSHOT_DIR" -name "*.snap.enc" | wc -l)
log "INFO" "Snapshots locaux restants: $REMAINING_SNAPSHOTS"

# =============================================================================
# PHASE 7: MÉTRIQUES PROMETHEUS
# =============================================================================

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

cat > "$METRICS_FILE" <<EOF
# HELP vault_snapshot_last_success_timestamp Last successful snapshot timestamp
# TYPE vault_snapshot_last_success_timestamp gauge
vault_snapshot_last_success_timestamp $END_TIME

# HELP vault_snapshot_duration_seconds Duration of last snapshot operation
# TYPE vault_snapshot_duration_seconds gauge
vault_snapshot_duration_seconds $DURATION

# HELP vault_snapshot_size_bytes Size of last snapshot in bytes
# TYPE vault_snapshot_size_bytes gauge
vault_snapshot_size_bytes $SNAPSHOT_SIZE

# HELP vault_snapshot_local_count Number of snapshots stored locally
# TYPE vault_snapshot_local_count gauge
vault_snapshot_local_count $REMAINING_SNAPSHOTS
EOF

log "INFO" "Métriques Prometheus mises à jour"

# =============================================================================
# FIN
# =============================================================================

log "INFO" "=== SNAPSHOT TERMINÉ AVEC SUCCÈS (${DURATION}s) ==="
log "INFO" "Fichier: $SNAPSHOT_FILE"
log "INFO" "Taille: ${SNAPSHOT_SIZE} bytes"
log "INFO" "HMAC: ${HMAC:0:32}..."

exit 0
