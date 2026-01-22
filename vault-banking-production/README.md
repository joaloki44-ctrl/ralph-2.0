# 🏦 VAULT BANKING-GRADE PRODUCTION - FRANCE

[![Compliance](https://img.shields.io/badge/Compliance-ACPR%20%7C%20RGPD%20%7C%20DORA-green)](https://www.acpr.banque-france.fr/)
[![Security](https://img.shields.io/badge/Security-FIPS%20140--2%20Level%203-blue)](https://csrc.nist.gov/publications/detail/fips/140/2/final)
[![Version](https://img.shields.io/badge/Vault-1.18.3%2Bent-purple)](https://www.hashicorp.com/products/vault)

**Déploiement production HashiCorp Vault pour secteur bancaire français.**

## 📋 Vue d'Ensemble

Ce repository contient **l'infrastructure complète as-code** pour déployer un cluster Vault haute disponibilité (HA) conforme aux exigences réglementaires bancaires françaises (ACPR, RGPD, DORA, PCI-DSS).

### Caractéristiques Principales

- ✅ **Haute Disponibilité**: 3 nodes (Paris DC1, Paris DC2, Lyon)
- ✅ **Auto-unseal HSM**: Thales nShield Connect (FIPS 140-2 Level 3)
- ✅ **Souveraineté**: 100% infrastructure France, données UE uniquement
- ✅ **Audit Immutable**: Logs S3 WORM + backup offline LTO-9
- ✅ **RPO < 10s**: WAL shipping + snapshots chiffrés
- ✅ **RTO < 30min**: Failover automatique + DR automatisé
- ✅ **Zero Trust**: mTLS obligatoire, LDAP auth, AppRole

### Conformité Réglementaire

| Régulation | Statut | Détails |
|------------|--------|---------|
| **ACPR** | ✅ Conforme | Audit trail 10 ans, tests DR semestriels |
| **RGPD** | ✅ Conforme | Crypto-shredding, droit à l'oubli |
| **DORA** | ✅ Conforme | Résilience opérationnelle, tests chaos |
| **PCI-DSS** | ✅ Conforme | HSM requis, mTLS, audit complet |
| **SecNumCloud** | 🔄 En cours | Qualification ANSSI prévue Q2 2026 |

## 🚀 Démarrage Rapide

### Prérequis

```bash
# Infrastructure
- 3 serveurs: 16C/64GB/2TB NVMe (RHEL 9 ou Ubuntu 24.04)
- 3 HSM Thales nShield Connect
- Réseau: 3 VLANs dédiés, firewalls configurés
- S3 compatible: Scaleway Object Storage (région fr-par)

# Logiciels
- Ansible 2.15+
- Vault Enterprise 1.18.3+ (licence valide)
- Terraform 1.7+ (optionnel)
- AWS CLI 2.15+

# Accès
- Root SSH sur les 3 serveurs
- Dual custody pour HSM
- Certificats TLS (CA + nodes)
```

### Installation en 3 Étapes

```bash
# 1. Clone repository
git clone https://github.com/banque/vault-banking-production.git
cd vault-banking-production

# 2. Configuration inventaire
cp ansible/inventory/production.ini.example ansible/inventory/production.ini
# Éditer avec vos IPs et hostnames

# 3. Déploiement (15-20 min)
ansible-playbook -i ansible/inventory/production.ini \
  ansible/deploy-vault-cluster.yml \
  --ask-vault-pass
```

**Guide complet:** [docs/DEPLOYMENT-GUIDE.md](docs/DEPLOYMENT-GUIDE.md)

## 📁 Structure du Repository

```
vault-banking-production/
├── ansible/                      # Playbooks Ansible
│   ├── deploy-vault-cluster.yml  # Déploiement principal
│   ├── vault-hsm-failover.yml    # Failover HSM
│   ├── inventory/                # Inventaires par environnement
│   └── roles/                    # Rôles Ansible réutilisables
│
├── config/                       # Configurations Vault
│   ├── vault-production.hcl      # Config principale hardened
│   ├── policies/                 # Policies Vault (admin, apps)
│   └── auth-methods/             # Configuration LDAP, AppRole
│
├── scripts/                      # Scripts opérationnels
│   ├── vault-snapshot-encrypted.sh    # Backup chiffré
│   ├── vault-restore-encrypted.sh     # Restore DR
│   ├── vault-offline-backup.sh        # Backup LTO-9
│   └── security-validation.sh         # Tests sécurité
│
├── docs/                         # Documentation
│   ├── DEPLOYMENT-GUIDE.md       # Guide déploiement complet
│   ├── RUNBOOKS.md               # Procédures opérationnelles
│   ├── ARCHITECTURE.md           # Architecture détaillée
│   ├── COMPLIANCE.md             # Conformité réglementaire
│   └── THREAT-MODEL.md           # Analyse menaces
│
├── tests/                        # Tests automatisés
│   ├── security-validation.sh    # Suite tests sécurité
│   ├── ha-failover-test.sh       # Tests HA
│   └── dr-restore-test.sh        # Tests DR
│
└── README.md                     # Ce fichier
```

## 🔧 Configuration

### 1. Inventaire Ansible

**Fichier:** `ansible/inventory/production.ini`

```ini
[vault_cluster]
vault-01 ansible_host=10.0.10.10 node_id=vault-01
vault-02 ansible_host=10.0.10.11 node_id=vault-02
vault-03 ansible_host=10.0.10.12 node_id=vault-03

[vault_cluster:vars]
ansible_user=root
vault_version=1.18.3+ent
vault_hsm_pin={{ vault_password }}
vault_hsm_pin_secondary={{ vault_password_secondary }}
```

### 2. Variables Secrètes

```bash
# Création fichier secrets chiffré
ansible-vault create ansible/secrets.yml

# Contenu:
vault_hsm_pin: "XXXX"               # PIN HSM primaire
vault_hsm_pin_secondary: "YYYY"     # PIN HSM secondaire
pagerduty_key: "ZZZZ"               # Clé API PagerDuty
ldap_bind_password: "AAAA"          # Password bind LDAP
```

### 3. Certificats TLS

```bash
# Générer certificats (voir docs/DEPLOYMENT-GUIDE.md)
cd tls/
./generate-certificates.sh

# Résultat:
# tls/
# ├── ca.pem              # CA certificate
# ├── ca-key.pem          # CA private key (COFFRE-FORT!)
# ├── vault-01-cert.pem   # Certificat vault-01
# ├── vault-01-key.pem    # Clé privée vault-01
# ├── vault-02-cert.pem
# ├── vault-02-key.pem
# ├── vault-03-cert.pem
# └── vault-03-key.pem
```

## 🎯 Opérations Courantes

### Backup Manuel

```bash
# Snapshot chiffré + upload S3
ssh vault@vault-01
/usr/local/bin/vault-snapshot-encrypted.sh
```

### Restore Disaster Recovery

```bash
# Liste snapshots disponibles
aws s3 ls s3://vault-backups-prod/snapshots/ \
  --endpoint-url=https://s3.fr-par.scw.cloud

# Restore
ssh root@vault-01
/usr/local/bin/vault-restore-encrypted.sh \
  vault-snapshot-20250120-120000.snap.enc
```

### Vérification Health

```bash
# Status cluster
for node in vault-01 vault-02 vault-03; do
  echo "=== $node ==="
  vault status -address=https://${node}.bank.internal:8200
done

# Métriques Prometheus
curl -k https://vault-01.bank.internal:8200/v1/sys/metrics?format=prometheus
```

### Rotation Certificats TLS

```bash
# Générer nouveaux certificats (expiration < 30j)
cd tls/
./renew-certificates.sh

# Déploiement avec rolling restart
ansible-playbook -i ansible/inventory/production.ini \
  ansible/rotate-tls-certificates.yml
```

## 📊 Monitoring & Alerting

### Dashboards Grafana

- **Vault Overview**: https://grafana.bank.internal/d/vault-overview
- **Raft Performance**: https://grafana.bank.internal/d/vault-raft
- **Audit Metrics**: https://grafana.bank.internal/d/vault-audit

### Alertes PagerDuty

| Alerte | Sévérité | Action |
|--------|----------|--------|
| Vault Sealed | Critique | Vérifier HSM, unseal si nécessaire |
| Leader Election Failed | Critique | Vérifier réseau inter-nodes |
| Snapshot Failed | Élevée | Vérifier espace disque, S3 access |
| Audit Device Blocked | Élevée | Rotation logs, vérifier FluentBit |
| HSM Unreachable | Critique | Vérifier connectivité HSM |

## 🔒 Sécurité

### Tests de Validation

```bash
# Suite complète (7 tests)
cd tests/
./security-validation.sh

# Tests individuels
./tests/anti-debug-test.sh
./tests/filesystem-immutable-test.sh
./tests/hsm-failover-test.sh
./tests/audit-integrity-test.sh
```

### Hardening Checklist

- [x] mlock activé (secrets jamais swappés)
- [x] ptrace désactivé (anti-debug)
- [x] Filesystem immutable (Raft DB protégé)
- [x] mTLS obligatoire (client certs requis)
- [x] HMAC signature (audit logs)
- [x] Rate limiting applicatif
- [x] WAL shipping (RPO < 10s)
- [x] Snapshots chiffrés (HSM)
- [x] S3 MFA Delete
- [x] Offline backup (LTO-9)

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [DEPLOYMENT-GUIDE.md](docs/DEPLOYMENT-GUIDE.md) | Guide déploiement complet (60 pages) |
| [RUNBOOKS.md](docs/RUNBOOKS.md) | Procédures opérationnelles |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Architecture technique détaillée |
| [COMPLIANCE.md](docs/COMPLIANCE.md) | Conformité ACPR/RGPD/DORA |
| [THREAT-MODEL.md](docs/THREAT-MODEL.md) | Analyse menaces & mitigations |
| [DR-PROCEDURES.md](docs/DR-PROCEDURES.md) | Procédures disaster recovery |
| [BREAK-GLASS.md](docs/BREAK-GLASS.md) | Procédures d'urgence |

## 🆘 Support

### Heures Ouvrables (9h-18h)
- **Email**: vault-support@bank.internal
- **Confluence**: https://wiki.bank.internal/vault
- **Runbooks**: https://runbooks.bank.internal/vault

### Astreinte 24/7
- **Téléphone**: +33 X XX XX XX XX
- **PagerDuty**: https://bank.pagerduty.com

### Escalade
1. **L1**: Équipe Ops (15 min response time)
2. **L2**: SRE Vault (30 min response time)
3. **L3**: HashiCorp Enterprise Support (1h response time)

## 🤝 Contribution

**Ce repository est interne uniquement.**

Processus de modification:
1. Fork du repository
2. Branch feature (`git checkout -b feature/amélioration`)
3. Commit signé (`git commit -s -m "Description"`)
4. Push branch (`git push origin feature/amélioration`)
5. Merge Request + review SecOps + RSSI
6. Tests en environnement staging obligatoires
7. Merge après validation

## 📝 Changelog

Voir [CHANGELOG.md](CHANGELOG.md) pour l'historique des versions.

### Version 1.0.0 (2025-01-20)
- ✨ Déploiement initial cluster HA
- ✨ Auto-unseal HSM Thales
- ✨ Backup chiffré S3 + LTO-9
- ✨ Monitoring Prometheus/Grafana
- ✨ Documentation complète
- ✅ Conformité ACPR/RGPD/DORA validée
- ✅ Audit sécurité externe passé

## 📄 Licence

**Propriété exclusive de la Banque.**  
Distribution interdite sans autorisation écrite de la Direction Technique.

## ⚖️ Conformité

Ce projet respecte:
- **ACPR** (Autorité de Contrôle Prudentiel et de Résolution)
- **RGPD** (Règlement Général sur la Protection des Données)
- **DORA** (Digital Operational Resilience Act)
- **PCI-DSS** (Payment Card Industry Data Security Standard)
- **Recommandations ANSSI** (Agence Nationale de la Sécurité des Systèmes d'Information)

Dernier audit: 15 Janvier 2026 (validé)  
Prochain audit: 15 Juillet 2026

---

**Made with 🔒 by Équipe Infrastructure & SecOps**

*Confidentiel - Distribution Restreinte*
