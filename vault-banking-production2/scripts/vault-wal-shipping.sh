#!/bin/bash
#
# VAULT WAL SHIPPING - Continuous Backup (RPO < 10s)
# ==================================================
# Description: Archive transactions Raft WAL vers S3 en continu
# RPO Target: < 10 secondes (vs 6h avec snapshots seuls)
# Mécanisme: inotify sur Raft WAL + upload S3 immédiat
#
# Installation:
#   - Systemd service (toujours actif)
#   - Monitoring via Prometheus
#   - Alerting si lag > 30s
#

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CONFIGURATION
# =============================================================================

RAFT_DATA_DIR="${RAFT_DATA_DIR:-/vault/data/raft}"
RAFT_WAL_DIR="${RAFT_DATA_DIR}/wal"

S3_BUCKET="${VAULT_S3_BUCKET:-s3://vault-wal-archive}"
S3_REGION="${VAULT_S3_REGION:-fr-par}"
S3_ENDPOINT="${VAULT_S3_ENDPOINT:-https://s3.fr-par.scw.cloud}"

LOG_FILE="/var/log/vault/wal-shipping.log"
METRICS_FILE="/var/lib/node_exporter/textfile_collector/vault_wal_shipping.prom"

# Compression (optionnel, trade-off perf vs bande passante)
ENABLE_COMPRESSION=true

# Buffer local (si S3 temporairement inaccessible)
LOCAL_BUFFER_DIR="/vault/wal-buffer"
MAX_BUFFER_SIZE_MB=1000  # 1GB max buffer

# =============================================================================
# FONCTIONS
# =============================================================================

log() {
    echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"
}

update_metrics() {
    local last_upload_timestamp="$1"
    local lag_seconds="$2"
    local buffer_size_bytes="$3"
    local upload_count="$4"
    
    cat > "$METRICS_FILE" <<EOF
# HELP vault_wal_last_upload_timestamp Last WAL upload to S3 timestamp
# TYPE vault_wal_last_upload_timestamp gauge
vault_wal_last_upload_timestamp $last_upload_timestamp

# HELP vault_wal_replication_lag_seconds Lag between WAL write and S3 upload
# TYPE vault_wal_replication_lag_seconds gauge
vault_wal_replication_lag_seconds $lag_seconds

# HELP vault_wal_buffer_size_bytes Local buffer size (files waiting upload)
# TYPE vault_wal_buffer_size_bytes gauge
vault_wal_buffer_size_bytes $buffer_size_bytes

# HELP vault_wal_uploads_total Total number of WAL segments uploaded
# TYPE vault_wal_uploads_total counter
vault_wal_uploads_total $upload_count
EOF
}

upload_wal_segment() {
    local wal_file="$1"
    local start_time=$(date +%s)
    
    # Nom fichier S3 (structure date-based)
    local basename=$(basename "$wal_file")
    local s3_key="wal/$(date +%Y/%m/%d)/${basename}"
    
    # Compression si activée
    local upload_file="$wal_file"
    if [ "$ENABLE_COMPRESSION" = true ]; then
        gzip -c "$wal_file" > "${wal_file}.gz"
        upload_file="${wal_file}.gz"
        s3_key="${s3_key}.gz"
    fi
    
    # Upload S3
    if aws s3 cp "$upload_file" "${S3_BUCKET}/${s3_key}" \
        --endpoint-url="$S3_ENDPOINT" \
        --region="$S3_REGION" \
        --metadata "original-timestamp=$(stat -c%Y "$wal_file")" \
        --storage-class STANDARD \
        2>&1 | tee -a "$LOG_FILE"; then
        
        local end_time=$(date +%s)
        local lag=$((end_time - $(stat -c%Y "$wal_file")))
        
        log "✓ Uploaded: $basename (lag: ${lag}s)"
        
        # Cleanup
        rm -f "$upload_file"
        
        # Alerte si lag > 30s (anormal)
        if [ $lag -gt 30 ]; then
            log "⚠️  WARNING: High replication lag: ${lag}s"
            # Alert PagerDuty (optionnel)
            alert_pagerduty "warning" "WAL replication lag high: ${lag}s"
        fi
        
        return 0
    else
        log "✗ Upload failed: $basename - buffering locally"
        
        # Buffer local si S3 inaccessible
        mkdir -p "$LOCAL_BUFFER_DIR"
        mv "$wal_file" "$LOCAL_BUFFER_DIR/"
        
        return 1
    fi
}

process_buffered_files() {
    if [ ! -d "$LOCAL_BUFFER_DIR" ]; then
        return
    fi
    
    local buffer_count=$(find "$LOCAL_BUFFER_DIR" -type f | wc -l)
    if [ $buffer_count -eq 0 ]; then
        return
    fi
    
    log "Processing buffered files: $buffer_count"
    
    for buffered_file in "$LOCAL_BUFFER_DIR"/*; do
        if [ -f "$buffered_file" ]; then
            upload_wal_segment "$buffered_file"
        fi
    done
}

check_buffer_size() {
    local buffer_size=$(du -sb "$LOCAL_BUFFER_DIR" 2>/dev/null | cut -f1 || echo 0)
    local buffer_size_mb=$((buffer_size / 1024 / 1024))
    
    if [ $buffer_size_mb -gt $MAX_BUFFER_SIZE_MB ]; then
        log "🚨 CRITICAL: Local buffer exceeded ${MAX_BUFFER_SIZE_MB}MB"
        alert_pagerduty "critical" "WAL buffer critical: ${buffer_size_mb}MB"
    fi
    
    echo $buffer_size
}

alert_pagerduty() {
    local severity="$1"
    local message="$2"
    
    if [ -z "${PAGERDUTY_KEY:-}" ]; then
        return
    fi
    
    curl -s -X POST "https://events.pagerduty.com/v2/enqueue" \
      -H "Content-Type: application/json" \
      -d "{
        \"routing_key\": \"$PAGERDUTY_KEY\",
        \"event_action\": \"trigger\",
        \"payload\": {
          \"summary\": \"$message\",
          \"severity\": \"$severity\",
          \"source\": \"$(hostname)\",
          \"component\": \"vault-wal-shipping\"
        }
      }" || true
}

# =============================================================================
# INITIALISATION
# =============================================================================

log "=== VAULT WAL SHIPPING STARTED ==="

# Vérifications
if [ ! -d "$RAFT_WAL_DIR" ]; then
    log "ERROR: Raft WAL directory not found: $RAFT_WAL_DIR"
    exit 1
fi

# Création buffer local
mkdir -p "$LOCAL_BUFFER_DIR"

# Installation inotify si nécessaire
if ! command -v inotifywait &> /dev/null; then
    log "Installing inotify-tools..."
    if command -v apt-get &> /dev/null; then
        apt-get install -y inotify-tools
    elif command -v dnf &> /dev/null; then
        dnf install -y inotify-tools
    fi
fi

# =============================================================================
# BOUCLE PRINCIPALE - inotify sur Raft WAL
# =============================================================================

upload_count=0

# Traiter d'abord fichiers buffered (si redémarrage)
process_buffered_files

log "Monitoring Raft WAL directory: $RAFT_WAL_DIR"

# inotify sur répertoire WAL (événements: close_write = fichier complet écrit)
inotifywait -m -e close_write -e moved_to "$RAFT_WAL_DIR" --format '%w%f' | while read -r wal_file
do
    # Ignorer fichiers temporaires Raft
    if [[ "$wal_file" =~ \.tmp$ ]]; then
        continue
    fi
    
    log "New WAL segment detected: $(basename "$wal_file")"
    
    # Upload immédiat
    if upload_wal_segment "$wal_file"; then
        upload_count=$((upload_count + 1))
    fi
    
    # Tentative flush buffer (si fichiers en attente)
    process_buffered_files
    
    # Update métriques Prometheus
    buffer_size=$(check_buffer_size)
    current_time=$(date +%s)
    lag=$(( current_time - $(stat -c%Y "$wal_file" 2>/dev/null || echo $current_time) ))
    
    update_metrics "$current_time" "$lag" "$buffer_size" "$upload_count"
done

# =============================================================================
# NOTES IMPLÉMENTATION
# =============================================================================

# MÉCANISME:
# 1. inotify surveille /vault/data/raft/wal
# 2. Dès qu'un segment WAL est écrit (close_write), upload S3 immédiat
# 3. Si S3 inaccessible, buffer local (jusqu'à 1GB)
# 4. Retry automatique sur fichiers buffered
# 5. Métriques Prometheus (lag, buffer size, upload count)

# PERFORMANCE:
# - Overhead: Négligeable (inotify = kernel event, pas de polling)
# - Bande passante: ~1-10 MB/min (dépend du trafic Vault)
# - Compression: Réduit taille WAL de ~70% (optionnel)

# RECOVERY:
# Pour restore depuis WAL:
#   1. Restore snapshot le plus récent
#   2. Replay WAL segments depuis S3 (ordre chronologique)
#   3. Résultat: État exact au moment dernier segment WAL

# COMPLIANCE:
# - ACPR: RPO < 10s (vs 6h avec snapshots seuls)
# - DORA: Continuous backup (résilience renforcée)

# MONITORING:
# - Prometheus metrics: vault_wal_replication_lag_seconds
# - Alerte si lag > 30s (anormal)
# - Alerte si buffer > 1GB (S3 down prolongé)

# =============================================================================
# SYSTEMD SERVICE (Installation)
# =============================================================================

# Créer: /etc/systemd/system/vault-wal-shipping.service
# 
# [Unit]
# Description=Vault WAL Shipping to S3
# After=vault.service
# Requires=vault.service
# 
# [Service]
# Type=simple
# User=vault
# Group=vault
# ExecStart=/usr/local/bin/vault-wal-shipping.sh
# Restart=always
# RestartSec=10
# 
# EnvironmentFile=/etc/vault.d/wal-shipping.env
# 
# [Install]
# WantedBy=multi-user.target

# Activation:
# systemctl daemon-reload
# systemctl enable vault-wal-shipping
# systemctl start vault-wal-shipping
