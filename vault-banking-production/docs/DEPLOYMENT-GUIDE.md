# GUIDE DE DÉPLOIEMENT VAULT BANKING-GRADE
## Production France - Conformité ACPR/RGPD/DORA

**Version:** 1.0.0  
**Date:** 20 Janvier 2025  
**Audience:** Équipe Infrastructure, SecOps, Compliance  
**Classification:** CONFIDENTIEL - Usage Interne Uniquement

---

## TABLE DES MATIÈRES

1. [Prérequis](#prérequis)
2. [Architecture Cible](#architecture-cible)
3. [Timeline Déploiement](#timeline-déploiement)
4. [Phase 1: Préparation Infrastructure](#phase-1-préparation-infrastructure)
5. [Phase 2: Installation HSM](#phase-2-installation-hsm)
6. [Phase 3: Déploiement Vault Cluster](#phase-3-déploiement-vault-cluster)
7. [Phase 4: Configuration Initiale](#phase-4-configuration-initiale)
8. [Phase 5: Tests & Validation](#phase-5-tests--validation)
9. [Phase 6: Go-Live Production](#phase-6-go-live-production)
10. [Troubleshooting](#troubleshooting)

---

## PRÉREQUIS

### Infrastructure Physique

| Composant | Quantité | Spécifications | Localisation |
|-----------|----------|----------------|--------------|
| **Serveurs Vault** | 3 | Dell R650, 16C/64GB, 2TB NVMe | Paris DC1 (1), Paris DC2 (1), Lyon (1) |
| **HSM Thales Luna** | 3 | FIPS 140-2 L3 | Paris DC1 (1), Paris DC2 (1), Lyon (1) |
| **Firewall** | 2 | Fortinet 600E (HA) | Paris DC1 |
| **Switches** | 2 | Cisco Catalyst 9300 | Chaque DC |
| **LTO-9 Drive** | 1 | Backup offline | Paris DC1 |

### Réseau

```
VLAN 10 (Vault Cluster):     10.0.10.0/24
  - vault-01.bank.internal:  10.0.10.10
  - vault-02.bank.internal:  10.0.10.11
  - vault-03.bank.internal:  10.0.10.12

VLAN 20 (Monitoring):        10.0.20.0/24
VLAN 30 (Audit Logs):        10.0.30.0/24
VLAN 100 (Applications):     10.0.100.0/24

Firewall Rules: Voir annexe A
```

### Logiciels

- **OS:** RHEL 9.3 ou Ubuntu 24.04 LTS (hardened selon ANSSI)
- **Vault Enterprise:** 1.18.3+ent (licence validée)
- **Ansible:** 2.15+
- **Terraform:** 1.7+ (optionnel, pour IaC S3)
- **AWS CLI:** 2.15+ (pour S3 Scaleway)

### Accès & Permissions

- [ ] Compte root sur les 3 serveurs Vault
- [ ] Accès physique datacenters (dual custody pour HSM)
- [ ] Credentials S3 Scaleway (région fr-par)
- [ ] Certificats TLS (CA interne + certificats nodes)
- [ ] Licence Vault Enterprise (fichier .hclic)
- [ ] Accès LDAP banque (pour tests auth)

---

## ARCHITECTURE CIBLE

```
┌─────────────────────────────────────────────────────────────┐
│                    CLUSTER VAULT HA                         │
│                                                             │
│  [vault-01]──┐                                             │
│   Paris DC1  │                                             │
│   10.0.10.10 │                                             │
│              │                                             │
│  [vault-02]──┼──► [Raft Consensus] ◄──► [HSM Cluster]     │
│   Paris DC2  │         Quorum 2/3        FIPS 140-2 L3    │
│   10.0.10.11 │                                             │
│              │                                             │
│  [vault-03]──┘                                             │
│   Lyon DC    │                                             │
│   10.0.10.12 │                                             │
│                                                             │
│  Snapshots: S3 Scaleway (fr-par) + LTO-9 Offline          │
└─────────────────────────────────────────────────────────────┘
```

**SLA Cible:**
- Disponibilité: 99.95% (21.9 min/mois)
- RTO: 30 minutes
- RPO: 10 secondes

---

## TIMELINE DÉPLOIEMENT

**Durée totale:** 9 mois (37 semaines)

```
Mois 1-2:  Infrastructure & HSM          [████████░░░░░░░░░] 
Mois 3-4:  Vault Cluster & Config        [░░░░░░░░████████░░]
Mois 5-6:  Observability & Compliance    [░░░░░░░░░░░░████░░]
Mois 7-8:  Intégration Apps              [░░░░░░░░░░░░░░████]
Mois 9:    Validation & Go-Live          [░░░░░░░░░░░░░░░░██]
```

**Jalons critiques:**
- **J+56 (Sem 8):** HSM opérationnels
- **J+112 (Sem 16):** Vault cluster test opérationnel
- **J+168 (Sem 24):** Audit sécurité externe passé
- **J+224 (Sem 32):** Première app en production
- **J+252 (Sem 36):** GO-LIVE général

---

## PHASE 1: PRÉPARATION INFRASTRUCTURE

### 1.1 Installation Serveurs (Semaine 1-4)

**Sur chaque serveur Vault (vault-01, vault-02, vault-03):**

```bash
# 1. Installation OS (RHEL 9.3 minimal)
# Utiliser ISO officiel Red Hat
# Partitionnement:
#   /boot:  1 GB
#   /:      50 GB
#   /vault: 2 TB (LVM, RAID-1 si possible)
#   swap:   16 GB

# 2. Hardening ANSSI
curl -O https://github.com/...../anssi-rhel9-hardening.sh
chmod +x anssi-rhel9-hardening.sh
./anssi-rhel9-hardening.sh

# 3. Configuration réseau
nmcli con mod eth0 ipv4.addresses 10.0.10.10/24  # Adapter par node
nmcli con mod eth0 ipv4.gateway 10.0.10.1
nmcli con mod eth0 ipv4.dns "10.0.1.53 10.0.1.54"
nmcli con mod eth0 ipv4.method manual
nmcli con up eth0

# 4. Configuration hostname
hostnamectl set-hostname vault-01.bank.internal  # Adapter

# 5. Mise à jour système
dnf update -y
reboot

# 6. Installation packages de base
dnf install -y \
  vim git unzip wget curl \
  python3 python3-pip \
  chrony firewalld \
  aide auditd

# 7. Configuration NTP (synchronisation temps critique)
systemctl enable --now chronyd
chronyc sources

# 8. Configuration firewall
firewall-cmd --permanent --add-port=8200/tcp  # Vault API
firewall-cmd --permanent --add-port=8201/tcp  # Vault cluster
firewall-cmd --permanent --add-port=9100/tcp  # Node exporter
firewall-cmd --reload
```

### 1.2 Configuration Stockage

```bash
# LVM pour /vault (flexibilité)
pvcreate /dev/sdb
vgcreate vg_vault /dev/sdb
lvcreate -L 1.8T -n lv_vault vg_vault

# Filesystem XFS (performance Raft)
mkfs.xfs /dev/vg_vault/lv_vault

# Mount permanent
echo "/dev/vg_vault/lv_vault /vault xfs defaults,noatime 0 2" >> /etc/fstab
mkdir -p /vault
mount /vault

# Permissions
chmod 750 /vault
```

### 1.3 Génération Certificats TLS

**Sur poste de travail sécurisé (pas sur serveurs Vault):**

```bash
# Création CA interne
mkdir -p ~/vault-pki && cd ~/vault-pki

# Clé privée CA (4096 bits)
openssl genrsa -out ca-key.pem 4096

# Certificat CA (10 ans)
openssl req -x509 -new -nodes -key ca-key.pem \
  -sha256 -days 3650 -out ca.pem \
  -subj "/C=FR/ST=Ile-de-France/L=Paris/O=Banque/OU=IT Security/CN=Vault Internal CA"

# Certificats par node
for node in vault-01 vault-02 vault-03; do
  # Clé privée node
  openssl genrsa -out ${node}-key.pem 4096
  
  # CSR
  openssl req -new -key ${node}-key.pem -out ${node}.csr \
    -subj "/C=FR/ST=Ile-de-France/O=Banque/OU=IT/CN=${node}.bank.internal"
  
  # SAN (Subject Alternative Names)
  cat > ${node}-san.cnf <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req

[req_distinguished_name]

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${node}.bank.internal
DNS.2 = ${node}
IP.1 = 10.0.10.X  # Adapter
EOF
  
  # Signature certificat (2 ans)
  openssl x509 -req -in ${node}.csr \
    -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
    -out ${node}-cert.pem -days 730 -sha256 \
    -extfile ${node}-san.cnf -extensions v3_req
done

# Vérification
openssl x509 -in vault-01-cert.pem -text -noout | grep -A3 "Subject Alternative Name"

# ⚠️  SÉCURITÉ: Stocker ca-key.pem dans coffre-fort physique
# NE JAMAIS copier ca-key.pem sur les serveurs Vault
```

**Distribution certificats:**

```bash
# Sur poste de travail
for node in vault-01 vault-02 vault-03; do
  scp ca.pem ${node}-cert.pem ${node}-key.pem root@${node}:/tmp/
done

# Sur chaque node Vault
ssh root@vault-01
mkdir -p /vault/tls
mv /tmp/ca.pem /tmp/vault-01-cert.pem /tmp/vault-01-key.pem /vault/tls/
chmod 644 /vault/tls/ca.pem /vault/tls/vault-01-cert.pem
chmod 400 /vault/tls/vault-01-key.pem
```

---

## PHASE 2: INSTALLATION HSM

### 2.1 Installation Hardware Thales nShield

**⚠️  ATTENTION: Intervention Thales obligatoire (dual custody)**

**Sur site Paris DC1, DC2, Lyon:**

1. Installation physique HSM dans baie serveur
2. Connexion réseau HSM ↔ Serveur Vault
3. Configuration Security World (Thales)
4. Génération clés master (jamais exportées)

**Documentation Thales:** Suivre "nShield Connect Installation Guide"

### 2.2 Configuration Software nShield

**Sur chaque serveur Vault:**

```bash
# Installation drivers Thales (fourni par Thales)
cd /tmp
tar xzf linux64-12.80.3.tar.gz
cd linux64/amd64/nfast
./install -p

# Vérification installation
/opt/nfast/bin/enquiry

# Output attendu:
# Server:
#  enquiry reply flags  none
#  enquiry reply level  Six
#  serial number        XXXX-XXXX-XXXX
#  mode                 operational
#  version              12.80.3
#  Module #1:
#   enquiry reply flags  none
#   enquiry reply level  Six
#   serial number        YYYY-YYYY-YYYY
#   mode                 operational
#   version              12.80.3

# Test connectivité
/opt/nfast/bin/nfkminfo
```

### 2.3 Création Clés Master Vault

**⚠️  PROCÉDURE DUAL CUSTODY - 2 personnes obligatoires**

```bash
# Génération clé master dans HSM (jamais exportée)
/opt/nfast/bin/generatekey \
  --protect=module \
  --type=AES-256 \
  --label="vault-master-key-primary" \
  --ident="vault-master-key-primary"

# Génération clé HMAC
/opt/nfast/bin/generatekey \
  --protect=module \
  --type=HMAC-SHA256 \
  --label="vault-hmac-key-primary" \
  --ident="vault-hmac-key-primary"

# Vérification clés
/opt/nfast/bin/nfkminfo | grep vault

# Backup Security World (coffre-fort physique)
tar czf /tmp/security-world-backup.tar.gz /opt/nfast/kmdata
# → Stocker dans coffre-fort banque (dual custody)
```

---

## PHASE 3: DÉPLOIEMENT VAULT CLUSTER

### 3.1 Déploiement via Ansible

**Sur poste de contrôle Ansible:**

```bash
# 1. Clone repository
git clone https://github.com/banque/vault-banking-production.git
cd vault-banking-production

# 2. Configuration inventaire
cat > ansible/inventory/production.ini <<EOF
[vault_cluster]
vault-01 ansible_host=10.0.10.10 node_id=vault-01
vault-02 ansible_host=10.0.10.11 node_id=vault-02
vault-03 ansible_host=10.0.10.12 node_id=vault-03

[vault_cluster:vars]
ansible_user=root
ansible_python_interpreter=/usr/bin/python3
vault_version=1.18.3+ent
vault_hsm_pin={{ vault_password }}
vault_hsm_pin_secondary={{ vault_password_secondary }}
EOF

# 3. Secrets HSM (Ansible Vault encrypted)
ansible-vault create ansible/secrets.yml
# Contenu:
# vault_hsm_pin: "XXXX"  # PIN HSM primaire
# vault_hsm_pin_secondary: "YYYY"  # PIN HSM secondaire

# 4. Dry-run
ansible-playbook -i ansible/inventory/production.ini \
  ansible/deploy-vault-cluster.yml \
  --ask-vault-pass \
  --check

# 5. Déploiement réel
ansible-playbook -i ansible/inventory/production.ini \
  ansible/deploy-vault-cluster.yml \
  --ask-vault-pass

# Durée estimée: 15-20 minutes
```

### 3.2 Vérification Post-Déploiement

```bash
# Sur chaque node
for node in vault-01 vault-02 vault-03; do
  echo "=== $node ==="
  ssh root@${node} "systemctl status vault"
  ssh root@${node} "vault status || true"
done

# Output attendu:
# vault-01: Active, Sealed (normal avant init)
# vault-02: Active, Sealed
# vault-03: Active, Sealed
```

---

## PHASE 4: CONFIGURATION INITIALE

### 4.1 Initialisation Cluster (PREMIER DÉMARRAGE UNIQUEMENT)

**⚠️  CRITIQUE: À exécuter une seule fois, sur vault-01 uniquement**

```bash
# Sur vault-01
export VAULT_ADDR=https://vault-01.bank.internal:8200
export VAULT_CACERT=/vault/tls/ca.pem
export VAULT_CLIENT_CERT=/vault/tls/vault-cert.pem
export VAULT_CLIENT_KEY=/vault/tls/vault-key.pem

# Initialisation avec recovery keys (auto-unseal HSM)
vault operator init \
  -recovery-shares=5 \
  -recovery-threshold=3 \
  -format=json > /tmp/vault-init.json

# ⚠️  SAUVEGARDER IMMÉDIATEMENT recovery keys
cat /tmp/vault-init.json | jq -r '.recovery_keys_b64[]'

# Output: 5 recovery keys
# Key 1: xxx...
# Key 2: xxx...
# Key 3: xxx...
# Key 4: xxx...
# Key 5: xxx...

# PROCÉDURE:
# 1. Imprimer sur 5 feuilles séparées
# 2. Placer dans 5 enveloppes scellées numérotées
# 3. Signature responsable sécurité
# 4. Stockage coffre-fort physique (dual custody)

# Root token initial
cat /tmp/vault-init.json | jq -r '.root_token'

# Suppression fichier init (sécurité)
shred -uvz /tmp/vault-init.json
```

**Vérification auto-unseal:**

```bash
vault status

# Output attendu:
# Seal Type: pkcs11  ← Auto-unseal HSM actif
# Sealed: false      ← Déjà unsealed automatiquement
# Total Shares: 5
# Threshold: 3
```

### 4.2 Configuration Audit Device

```bash
# Activation audit primaire (fichier)
vault audit enable file file_path=/vault/audit/audit.log

# Activation audit secondaire (syslog redondance)
vault audit enable syslog facility=AUTH tag=vault-audit

# Vérification
vault audit list
```

### 4.3 Configuration Secrets Engines

```bash
# 1. Transit engine (pour chiffrement snapshots)
vault secrets enable transit
vault write -f transit/keys/snapshot-key \
  type=aes256-gcm96 \
  exportable=false \
  allow_plaintext_backup=false \
  deletion_allowed=false

# 2. KV v2 (secrets généraux)
vault secrets enable -path=secret kv-v2

# 3. Database (credentials dynamiques)
vault secrets enable database

# 4. PKI (certificats internes)
vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki  # 10 ans
```

### 4.4 Configuration Auth Methods

```bash
# 1. LDAP (authentification employés)
vault auth enable ldap

vault write auth/ldap/config \
  url="ldaps://ldap.bank.internal" \
  userdn="ou=users,dc=bank,dc=internal" \
  groupdn="ou=groups,dc=bank,dc=internal" \
  binddn="cn=vault,ou=service-accounts,dc=bank,dc=internal" \
  bindpass="${LDAP_BIND_PASSWORD}" \
  starttls=false \
  insecure_tls=false \
  certificate=@/vault/tls/ldap-ca.pem

# Test auth LDAP
vault login -method=ldap username=test.user

# 2. AppRole (authentification applications)
vault auth enable approle

# 3. Kubernetes (si apps dans K8s)
vault auth enable kubernetes
```

### 4.5 Policies de Base

```bash
# Policy admin
vault policy write admin - <<EOF
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

# Policy lecture seule
vault policy write readonly - <<EOF
path "secret/data/*" {
  capabilities = ["read", "list"]
}
EOF

# Policy app bancaire (exemple)
vault policy write core-banking - <<EOF
path "secret/data/core-banking/*" {
  capabilities = ["read"]
}
path "database/creds/core-banking" {
  capabilities = ["read"]
}
EOF
```

---

## PHASE 5: TESTS & VALIDATION

### 5.1 Tests Fonctionnels

```bash
# Test 1: Write/Read secret
vault kv put secret/test password=changeme
vault kv get secret/test
vault kv delete secret/test

# Test 2: Transit encryption
vault write transit/encrypt/snapshot-key plaintext=$(echo "test" | base64)
# Vérifier ciphertext retourné

# Test 3: LDAP auth
vault login -method=ldap username=test.user

# Test 4: AppRole
vault write auth/approle/role/test-app \
  token_policies="readonly" \
  token_ttl=1h

ROLE_ID=$(vault read -field=role_id auth/approle/role/test-app/role-id)
SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/test-app/secret-id)

vault write auth/approle/login \
  role_id=$ROLE_ID \
  secret_id=$SECRET_ID
```

### 5.2 Tests Haute Disponibilité

```bash
# Test failover automatique
# Sur node actif (identifier avec `vault status | grep "HA Mode"`)

# 1. Identifier leader
vault status -format=json | jq -r '.leader_address'

# 2. Arrêter leader
ssh root@vault-01 "systemctl stop vault"

# 3. Vérifier élection nouveau leader (doit être < 30s)
watch -n 1 'vault status -format=json | jq -r ".leader_address"'

# 4. Redémarrer ancien leader
ssh root@vault-01 "systemctl start vault"

# Résultat attendu: Failover < 30s, pas d'erreur applicative
```

### 5.3 Tests Disaster Recovery

**Voir:** `scripts/vault-restore-encrypted.sh`

```bash
# Simulation restore complet
./scripts/vault-snapshot-encrypted.sh  # Créer snapshot
./scripts/vault-restore-encrypted.sh vault-snapshot-YYYYMMDD-HHMMSS.snap.enc

# Vérifier: Toutes les données restaurées
```

### 5.4 Tests Sécurité

```bash
# Suite de validation (créée précédemment)
cd tests
./security-validation.sh

# Tous les tests doivent passer (7/7 ✓)
```

---

## PHASE 6: GO-LIVE PRODUCTION

### 6.1 Checklist Pré-Production

**VALIDATION OBLIGATOIRE AVANT GO-LIVE:**

- [ ] 3 nodes Vault actifs et en quorum Raft
- [ ] Auto-unseal HSM fonctionnel (sealed=false)
- [ ] Audit logs actifs (fichier + syslog)
- [ ] Snapshots automatiques (cron 6h)
- [ ] Backup S3 WORM opérationnel
- [ ] Backup LTO-9 offline testé
- [ ] Monitoring Prometheus actif
- [ ] Alerting PagerDuty configuré
- [ ] Tests failover passés (< 30s)
- [ ] Tests restore passés
- [ ] Audit sécurité externe validé
- [ ] Formation équipe ops effectuée
- [ ] Runbooks opérationnels rédigés
- [ ] Approbation RSSI obtenue
- [ ] Approbation Compliance (ACPR) obtenue
- [ ] Validation Direction Technique

### 6.2 Migration Première Application

**Exemple: Core Banking**

```bash
# 1. Création policy spécifique
vault policy write core-banking /path/to/core-banking-policy.hcl

# 2. Création AppRole
vault write auth/approle/role/core-banking \
  secret_id_ttl=0 \
  token_policies=core-banking \
  token_ttl=1h \
  token_max_ttl=24h

# 3. Migration secrets
# (scripts custom selon source actuelle)

# 4. Configuration app pour utiliser Vault
# (dépend de l'app, généralement variables environnement)
# VAULT_ADDR=https://vault-01.bank.internal:8200
# VAULT_ROLE_ID=xxx
# VAULT_SECRET_ID=xxx

# 5. Tests intégration
# 6. Bascule production (blue/green)
# 7. Monitoring 48h intensif
```

### 6.3 Communication Go-Live

**Email template:**

```
Objet: [PRODUCTION] Vault Secret Management - Go-Live

Bonjour,

Le système Vault de gestion centralisée des secrets est désormais 
en production.

Disponibilité:
- API principale: https://vault.bank.internal:8200
- Monitoring: https://grafana.bank.internal/d/vault

Support:
- Heures ouvrables: servicedesk@bank.internal
- Astreinte 24/7: +33 X XX XX XX XX

Documentation:
- Confluence: https://wiki.bank.internal/vault
- Runbooks: https://runbooks.bank.internal/vault

Première application migrée: Core Banking
Prochaines migrations: API PSD2 (S+2), CRM (S+4)

Équipe Infrastructure
```

---

## TROUBLESHOOTING

### Problème: Vault sealed après reboot

**Symptôme:**
```bash
vault status
# Sealed: true
# Seal Type: pkcs11
```

**Solution:**
```bash
# Vérifier HSM accessible
/opt/nfast/bin/enquiry

# Vérifier variable env HSM PIN
cat /etc/vault.d/vault.env | grep VAULT_HSM_PIN

# Redémarrer Vault
systemctl restart vault

# Si toujours sealed → unseal manuel (break-glass)
# Utiliser recovery keys du coffre-fort
```

### Problème: Leader election failed

**Symptôme:**
```
Error: no leader elected
```

**Solution:**
```bash
# Vérifier réseau inter-nodes
for node in vault-01 vault-02 vault-03; do
  nc -zv $node 8201
done

# Vérifier logs Raft
journalctl -u vault | grep -i raft

# Si split-brain: redémarrer tous les nodes
# (perte service temporaire acceptable en DR)
```

### Problème: Audit device blocked

**Symptôme:**
```
Error writing audit log: disk full
```

**Solution:**
```bash
# Vérification espace disque
df -h /vault/audit

# Rotation manuelle si besoin
logrotate -f /etc/logrotate.d/vault

# Augmenter FluentBit buffer si backlog S3
```

---

## ANNEXES

### Annexe A: Firewall Rules Complètes

*Voir fichier séparé: `docs/firewall-rules.md`*

### Annexe B: Matrice RACI

*Voir fichier séparé: `docs/RACI-matrix.xlsx`*

### Annexe C: Plan de Formation

*Voir fichier séparé: `docs/training-plan.pdf`*

### Annexe D: Procédures Compliance

*Voir fichier séparé: `docs/compliance-procedures.md`*

---

**FIN DU GUIDE DE DÉPLOIEMENT**

**Support:** vault-support@bank.internal  
**Urgences:** +33 X XX XX XX XX (24/7)

---

*Document confidentiel - Distribution restreinte*
