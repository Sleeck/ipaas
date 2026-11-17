---
name: pentagi
description: Lancer, suivre et piloter des tests d'intrusion automatisés dans PentAGI (installé sur ce serveur) avec la commande pentagi-cli.
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [security, pentest, pentagi]
    category: security
    requires_toolsets: [terminal]
---

# PentAGI

PentAGI tourne sur ce serveur (Docker, https://127.0.0.1:8443). Ses agents utilisent
Claude via LiteLLM. On le pilote avec `pentagi-cli` (jeton déjà configuré).

## Règle absolue
Ne lance un flow que sur une cible pour laquelle l'utilisateur a confirmé avoir
l'autorisation de tester. En cas de doute, demande avant de lancer.

## Commandes
- `pentagi-cli list` : liste des flows (id, statut, titre)
- `pentagi-cli create "<cible + objectif + contraintes>"` : crée un flow et démarre les agents
- `pentagi-cli show <id>` : statut (created, running, waiting, finished, failed)
- `pentagi-cli tasks <id>` : tâches et leurs résultats (c'est là que sont les conclusions)
- `pentagi-cli messages <id> -n 30` : derniers messages des agents
- `pentagi-cli terminal <id> -n 30` : dernières commandes exécutées dans le conteneur Kali
- `pentagi-cli input <id> "<consigne>"` : répondre à un flow en statut `waiting`
- `pentagi-cli wait <id> --timeout 3600` : attendre la fin (bloquant)
- `pentagi-cli stop <id>` / `finish <id>` / `delete <id>`
- `pentagi-cli usage <id>` : consommation de tokens
- Ajouter `--json` avant la sous-commande pour une sortie brute.

## Méthode
1. Rédige une consigne précise : cible exacte, périmètre, ce qui est interdit.
2. `create`, puis surveille avec `show` / `messages` sans boucler trop vite
   (un flow dure de quelques minutes à plusieurs heures).
3. Quand le statut est `waiting`, lis les derniers messages et réponds avec `input`.
4. À la fin, résume les résultats de `tasks` pour l'utilisateur.
