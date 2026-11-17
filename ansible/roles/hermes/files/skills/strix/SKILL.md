---
name: strix
description: Lancer et suivre des scans de sécurité Strix (agents IA de test d'intrusion) sur une URL, un domaine, une IP ou un dépôt de code, avec la commande strix-scan.
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [security, pentest, strix]
    category: security
    requires_toolsets: [terminal]
---

# Strix

Strix est installé sur ce serveur et utilise Claude via LiteLLM
(variables dans /root/credentials/strix.env, chargées par strix-scan).

## Règle absolue
Ne scanne qu'une cible pour laquelle l'utilisateur a confirmé avoir l'autorisation
de tester. En cas de doute, demande avant de lancer.

## Commandes
- `strix-scan start <cible> [-m quick|standard|deep] [-i "consigne"] [-b budget_usd]`
  lance un scan en arrière-plan et affiche son identifiant.
  Par défaut : mode `standard`. Propose `-b` pour plafonner le coût.
- `strix-scan list` : scans lancés (en cours / terminé)
- `strix-scan logs <id> [N]` : dernières lignes du journal
- `strix-scan stop <id>` : arrêter un scan
- `strix-scan results` : dossiers de résultats dans /root/strix-work/strix_runs/

## Méthode
1. Confirme la cible et le mode avec l'utilisateur.
2. `strix-scan start ...`, puis suis avec `strix-scan logs <id>` à intervalles raisonnables.
3. À la fin, lis le rapport dans /root/strix-work/strix_runs/<run>/ et résume les
   vulnérabilités trouvées (gravité, preuve, correction).
