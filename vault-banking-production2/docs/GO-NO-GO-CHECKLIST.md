# ✅ CHECKLIST VALIDATION FINALE - GO PRODUCTION

**Projet:** Vault Banking-Grade France  
**Version:** 1.0.0  
**Date validation cible:** 27 Janvier 2025  
**Responsable:** Direction Technique + RSSI

---

## 🎯 CRITÈRES GO/NO-GO

**RÈGLE:** Tous les items marqués [BLOQUANT] doivent être ✅ pour autoriser GO production.  
Items [RECOMMANDÉ] sont fortement conseillés mais non bloquants.

---

## 1️⃣ BUDGET & RESSOURCES

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] Signature budget CAPEX 565k€ | ⬜ | Direction Financière | ____/____/____ |
| [BLOQUANT] Validation OPEX 161k€/an | ⬜ | Direction Financière | ____/____/____ |
| [BLOQUANT] Affectation Chef de projet (0.5 FTE) | ⬜ | RH | ____/____/____ |
| [BLOQUANT] Affectation Architecte infra (1.0 FTE) | ⬜ | RH | ____/____/____ |
| [BLOQUANT] Affectation SecOps (0.5 FTE) | ⬜ | RSSI | ____/____/____ |
| [BLOQUANT] Affectation DevOps (1.0 FTE) | ⬜ | RH | ____/____/____ |
| [RECOMMANDÉ] Contractualisation HashiCorp ProServ 80k€ | ⬜ | Achats | ____/____/____ |

**Notes:**
- Budget total année 1: 565k€ (CAPEX) + 161k€ (OPEX) = **726k€**
- ROI breakeven: 14 mois
- Gains annuels estimés: 480k€/an

---

## 2️⃣ INFRASTRUCTURE PHYSIQUE

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] 3 serveurs Dell R650 commandés | ⬜ | Infrastructure | ____/____/____ |
| [BLOQUANT] 3 HSM Thales nShield commandés | ⬜ | Sécurité | ____/____/____ |
| [BLOQUANT] Baie Paris DC1 disponible | ⬜ | Datacenter | ____/____/____ |
| [BLOQUANT] Baie Paris DC2 disponible | ⬜ | Datacenter | ____/____/____ |
| [BLOQUANT] Baie Lyon DC disponible | ⬜ | Datacenter | ____/____/____ |
| [BLOQUANT] Firewall Fortinet 600E (2x HA) | ⬜ | Réseau | ____/____/____ |
| [BLOQUANT] Switches Cisco 9300 (par DC) | ⬜ | Réseau | ____/____/____ |
| [RECOMMANDÉ] LTO-9 drive installé (backup offline) | ⬜ | Infrastructure | ____/____/____ |

**Délai critique:** Commande HSM sous 7 jours (délai livraison 8 semaines)

---

## 3️⃣ RÉSEAU & SÉCURITÉ

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] VLAN 10 (Vault) configuré | ⬜ | Réseau | ____/____/____ |
| [BLOQUANT] VLAN 20 (Monitoring) configuré | ⬜ | Réseau | ____/____/____ |
| [BLOQUANT] VLAN 30 (Audit) configuré | ⬜ | Réseau | ____/____/____ |
| [BLOQUANT] VLAN 100 (Apps) configuré | ⬜ | Réseau | ____/____/____ |
| [BLOQUANT] Firewall rules validées (annexe A) | ⬜ | Sécurité | ____/____/____ |
| [BLOQUANT] Certificats TLS générés (CA + 3 nodes) | ⬜ | PKI | ____/____/____ |
| [BLOQUANT] CA privée stockée coffre-fort | ⬜ | RSSI | ____/____/____ |
| [RECOMMANDÉ] Tests firewall (iptables audit) | ⬜ | Sécurité | ____/____/____ |

**Vérification:**
```bash
# Test connectivité inter-nodes
nc -zv vault-01.bank.internal 8200
nc -zv vault-02.bank.internal 8200
nc -zv vault-03.bank.internal 8200
```

---

## 4️⃣ LOGICIELS & LICENCES

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] Licence Vault Enterprise 1.18.3+ | ⬜ | Achats | ____/____/____ |
| [BLOQUANT] Licences RHEL 9 (3x servers) | ⬜ | Achats | ____/____/____ |
| [BLOQUANT] Compte S3 Scaleway (région fr-par) | ⬜ | Cloud | ____/____/____ |
| [BLOQUANT] Compte PagerDuty Team (5 users) | ⬜ | Ops | ____/____/____ |
| [RECOMMANDÉ] Licence Grafana Enterprise | ⬜ | Monitoring | ____/____/____ |
| [RECOMMANDÉ] Licence Splunk (SIEM) | ⬜ | Sécurité | ____/____/____ |

**Vérification licences:**
```bash
# Vault Enterprise
vault version
# Output attendu: Vault v1.18.3+ent

# RHEL subscription
subscription-manager status
# Output: Status: Current
```

---

## 5️⃣ HSM & CRYPTOGRAPHIE

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] HSM installés physiquement (3x) | ⬜ | Thales + Infra | ____/____/____ |
| [BLOQUANT] Security World créée (Thales) | ⬜ | Thales + Sécurité | ____/____/____ |
| [BLOQUANT] Clés master générées (HSM, jamais exportées) | ⬜ | Thales + Sécurité | ____/____/____ |
| [BLOQUANT] Backup Security World (coffre-fort) | ⬜ | RSSI | ____/____/____ |
| [BLOQUANT] Tests connectivité Vault ↔ HSM | ⬜ | Infrastructure | ____/____/____ |
| [BLOQUANT] Dual custody HSM validée | ⬜ | RSSI | ____/____/____ |
| [RECOMMANDÉ] HSM secondaires testés (failover) | ⬜ | Infrastructure | ____/____/____ |

**Vérification HSM:**
```bash
# Sur chaque serveur Vault
/opt/nfast/bin/enquiry | grep "operational"
# Output attendu: mode operational
```

---

## 6️⃣ DÉPLOIEMENT VAULT

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] Playbook Ansible testé (staging) | ⬜ | DevOps | ____/____/____ |
| [BLOQUANT] Vault cluster 3 nodes opérationnels | ⬜ | Infrastructure | ____/____/____ |
| [BLOQUANT] Auto-unseal HSM fonctionnel | ⬜ | Sécurité | ____/____/____ |
| [BLOQUANT] Raft consensus établi (quorum 2/3) | ⬜ | Infrastructure | ____/____/____ |
| [BLOQUANT] Audit devices activés (file + syslog) | ⬜ | Sécurité | ____/____/____ |
| [BLOQUANT] Recovery keys sauvegardées (coffre-fort) | ⬜ | RSSI | ____/____/____ |
| [RECOMMANDÉ] Root token révoqué (après config) | ⬜ | Sécurité | ____/____/____ |

**Vérification cluster:**
```bash
# Status cluster
vault status
# Output attendu:
# Sealed: false
# HA Mode: active
# Cluster Name: vault-banking-prod-france
```

---

## 7️⃣ BACKUP & DISASTER RECOVERY

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] Snapshots automatiques (cron 6h) | ⬜ | DevOps | ____/____/____ |
| [BLOQUANT] Snapshots chiffrés (Transit HSM) | ⬜ | Sécurité | ____/____/____ |
| [BLOQUANT] S3 WORM activé (Object Lock) | ⬜ | Cloud | ____/____/____ |
| [BLOQUANT] S3 MFA Delete activé | ⬜ | Cloud | ____/____/____ |
| [BLOQUANT] Test restore complet passé | ⬜ | Infrastructure | ____/____/____ |
| [BLOQUANT] Backup offline LTO-9 testé | ⬜ | Infrastructure | ____/____/____ |
| [BLOQUANT] WAL shipping S3 configuré | ⬜ | DevOps | ____/____/____ |
| [RECOMMANDÉ] Procédure DR documentée | ⬜ | Ops | ____/____/____ |

**Test restore obligatoire:**
```bash
# Créer snapshot
./scripts/vault-snapshot-encrypted.sh

# Restore immédiat
./scripts/vault-restore-encrypted.sh <snapshot-file>

# Vérifier: Toutes données présentes
vault kv list -recursive secret/
```

---

## 8️⃣ MONITORING & ALERTING

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] Prometheus scraping Vault metrics | ⬜ | Monitoring | ____/____/____ |
| [BLOQUANT] Dashboards Grafana configurés | ⬜ | Monitoring | ____/____/____ |
| [BLOQUANT] PagerDuty integration active | ⬜ | Ops | ____/____/____ |
| [BLOQUANT] Alertes critiques testées | ⬜ | Ops | ____/____/____ |
| [RECOMMANDÉ] Loki logs centralisés | ⬜ | Monitoring | ____/____/____ |
| [RECOMMANDÉ] FluentBit audit logs → S3 | ⬜ | Audit | ____/____/____ |

**Alertes critiques à tester:**
- Vault Sealed
- Leader Election Failed
- HSM Unreachable
- Snapshot Failed
- Audit Device Blocked

---

## 9️⃣ SÉCURITÉ & HARDENING

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] mTLS obligatoire (client certs) | ⬜ | Sécurité | ____/____/____ |
| [BLOQUANT] mlock activé (pas de swap secrets) | ⬜ | Infrastructure | ____/____/____ |
| [BLOQUANT] ptrace désactivé (anti-debug) | ⬜ | Infrastructure | ____/____/____ |
| [BLOQUANT] Filesystem immutable (Raft DB) | ⬜ | Infrastructure | ____/____/____ |
| [BLOQUANT] Audit logs signés (HMAC) | ⬜ | Sécurité | ____/____/____ |
| [BLOQUANT] Suite tests sécurité (7/7 passés) | ⬜ | Sécurité | ____/____/____ |
| [RECOMMANDÉ] AIDE integrity checker | ⬜ | Sécurité | ____/____/____ |
| [RECOMMANDÉ] Auditd kernel audit | ⬜ | Sécurité | ____/____/____ |

**Tests sécurité:**
```bash
cd tests/
./security-validation.sh

# Attendu: ✅ PASS: 7/7 tests
```

---

## 🔟 CONFORMITÉ RÉGLEMENTAIRE

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] Audit trail 10 ans (ACPR) | ⬜ | Compliance | ____/____/____ |
| [BLOQUANT] Crypto-shredding RGPD | ⬜ | DPO | ____/____/____ |
| [BLOQUANT] Tests DR semestriels planifiés (DORA) | ⬜ | RSSI | ____/____/____ |
| [BLOQUANT] HSM FIPS 140-2 L3 (PCI-DSS) | ⬜ | Sécurité | ____/____/____ |
| [BLOQUANT] Documentation compliance | ⬜ | Compliance | ____/____/____ |
| [BLOQUANT] Validation DPO (RGPD) | ⬜ | DPO | ____/____/____ |
| [BLOQUANT] Validation RSSI | ⬜ | RSSI | ____/____/____ |
| [RECOMMANDÉ] Pré-notification ACPR | ⬜ | Compliance | ____/____/____ |

**Documents compliance:**
- [x] COMPLIANCE.md
- [x] THREAT-MODEL.md
- [x] BREAK-GLASS.md
- [x] DR-PROCEDURES.md

---

## 1️⃣1️⃣ TESTS FONCTIONNELS

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] Tests CRUD secrets (kv-v2) | ⬜ | Ops | ____/____/____ |
| [BLOQUANT] Tests auth LDAP | ⬜ | Sécurité | ____/____/____ |
| [BLOQUANT] Tests auth AppRole | ⬜ | DevOps | ____/____/____ |
| [BLOQUANT] Tests Transit encryption | ⬜ | Sécurité | ____/____/____ |
| [BLOQUANT] Tests failover HA (< 30s) | ⬜ | Infrastructure | ____/____/____ |
| [BLOQUANT] Tests failover HSM | ⬜ | Sécurité | ____/____/____ |
| [RECOMMANDÉ] Tests charge (10k req/s) | ⬜ | Performance | ____/____/____ |

---

## 1️⃣2️⃣ DOCUMENTATION & FORMATION

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] Formation équipe Ops (HashiCorp Vault) | ⬜ | RH | ____/____/____ |
| [BLOQUANT] Formation HSM (Thales) | ⬜ | Thales | ____/____/____ |
| [BLOQUANT] Runbooks opérationnels rédigés | ⬜ | Ops | ____/____/____ |
| [BLOQUANT] Procédures break-glass validées | ⬜ | RSSI | ____/____/____ |
| [RECOMMANDÉ] Guide développeurs (apps) | ⬜ | DevOps | ____/____/____ |
| [RECOMMANDÉ] FAQ support interne | ⬜ | Support | ____/____/____ |

**Documentation livrée:**
- [x] README.md
- [x] DEPLOYMENT-GUIDE.md
- [x] EXECUTIVE-SUMMARY.md
- [x] RUNBOOKS.md
- [x] ARCHITECTURE.md

---

## 1️⃣3️⃣ AUDIT EXTERNE

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] Audit sécurité externe validé | ⬜ | RSSI | ____/____/____ |
| [BLOQUANT] Pentest passé (0 critique) | ⬜ | Sécurité | ____/____/____ |
| [BLOQUANT] Rapport audit livré | ⬜ | Auditeur | ____/____/____ |
| [RECOMMANDÉ] Certification PCI-DSS | ⬜ | Compliance | ____/____/____ |
| [RECOMMANDÉ] Qualification SecNumCloud (Q2 2026) | ⬜ | Compliance | ____/____/____ |

---

## 1️⃣4️⃣ MIGRATION PREMIÈRE APPLICATION

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] App pilote sélectionnée (Core Banking) | ⬜ | Product | ____/____/____ |
| [BLOQUANT] Policies Vault créées | ⬜ | Sécurité | ____/____/____ |
| [BLOQUANT] AppRole configuré | ⬜ | DevOps | ____/____/____ |
| [BLOQUANT] Secrets migrés | ⬜ | DevOps | ____/____/____ |
| [BLOQUANT] Tests intégration app passés | ⬜ | Dev | ____/____/____ |
| [RECOMMANDÉ] Blue/green deployment | ⬜ | DevOps | ____/____/____ |
| [RECOMMANDÉ] Monitoring app intensif 48h | ⬜ | Ops | ____/____/____ |

---

## 1️⃣5️⃣ COMMUNICATION & SUPPORT

| Item | Statut | Responsable | Date Validation |
|------|--------|-------------|----------------|
| [BLOQUANT] Astreinte 24/7 activée | ⬜ | Ops | ____/____/____ |
| [BLOQUANT] PagerDuty escalation configurée | ⬜ | Ops | ____/____/____ |
| [BLOQUANT] Communication go-live (email équipes) | ⬜ | Product | ____/____/____ |
| [RECOMMANDÉ] Confluence wiki à jour | ⬜ | Documentation | ____/____/____ |
| [RECOMMANDÉ] FAQ support publiée | ⬜ | Support | ____/____/____ |

---

## 📋 VALIDATION FINALE

### Signatures Requises (GO Production)

| Rôle | Nom | Signature | Date |
|------|-----|-----------|------|
| **Direction Technique** | ________________ | ________________ | ____/____/____ |
| **RSSI** | ________________ | ________________ | ____/____/____ |
| **DPO (RGPD)** | ________________ | ________________ | ____/____/____ |
| **Compliance Officer** | ________________ | ________________ | ____/____/____ |
| **Chef de Projet** | ________________ | ________________ | ____/____/____ |

### Décision Finale

**STATUT GO/NO-GO:**

⬜ **GO PRODUCTION** - Tous les critères bloquants validés  
⬜ **NO-GO** - Raison: ________________________________________________

**Date GO-LIVE autorisée:** ____/____/____

**Fenêtre de maintenance:** De __h__ à __h__ (hors heures ouvrables)

---

## 📞 CONTACTS URGENCE

**Pendant migration:**
- Chef de projet: +33 X XX XX XX XX
- SRE Vault: +33 X XX XX XX XX
- RSSI: +33 X XX XX XX XX
- HashiCorp Support: +1-XXX-XXX-XXXX (Enterprise)

**Post go-live:**
- Astreinte 24/7: +33 X XX XX XX XX
- PagerDuty: https://bank.pagerduty.com
- Email: vault-support@bank.internal

---

**Ce document doit être complété et signé AVANT autorisation go-live production.**

*Version: 1.0 - 20 Janvier 2025*
