# ipaas : PentAGI + Strix + Hermes Agent sur Claude

Installation d'un serveur de tests d'intrusion assistés par IA :

- [PentAGI](https://pentagi.com/) : agents autonomes de test d'intrusion, avec une interface web ;
- [Strix](https://github.com/usestrix/strix) : agents IA de recherche de vulnérabilités ;
- [Hermes Agent](https://github.com/NousResearch/hermes-agent) : agent conversationnel qui pilote PentAGI et Strix ;
- [LiteLLM](https://github.com/BerriAI/litellm) : proxy unique vers Claude (API Anthropic).

```
Hermes Agent ──┬─ pentagi-cli ──> PentAGI ──┐
               ├─ strix-scan ───> Strix ────┤
               │                            ▼
               └──────────────────> LiteLLM (127.0.0.1:4000) ──> API Anthropic (Claude)
```

Seul LiteLLM reçoit la clé Anthropic. PentAGI, Strix et Hermes s'authentifient
auprès de LiteLLM avec une clé interne générée à l'installation.

## Prérequis

- Ubuntu 24.04 (Python 3.12), en root, 4 Go de RAM, 20 Go de disque libre.
- Une clé API Anthropic ([console.anthropic.com](https://console.anthropic.com), *API Keys*).
  Un abonnement Claude (Pro, Team…) ne fonctionne pas : il faut une clé API.

## Trois façons d'installer

Les trois produisent exactement le même résultat, avec les mêmes fichiers dans
`/root/credentials`. On peut passer de l'une à l'autre sur un même serveur, et
chacune peut être relancée sans rien casser (les mots de passe déjà générés sont conservés).

| Version | Pour | Lancement |
| --- | --- | --- |
| [`install-pentagi-strix.sh`](install-pentagi-strix.sh) | Tout installer d'un coup, sans interaction | `ANTHROPIC_API_KEY=sk-ant-... bash install-pentagi-strix.sh` |
| [`install-pentagi-strix-manuel.sh`](install-pentagi-strix-manuel.sh) | Comprendre et contrôler chaque étape | Coller les blocs `ÉTAPE` un par un dans un terminal root |
| [`ansible/`](ansible/) | Configuration déclarative et rejouable | `cd ansible && ansible-playbook site.yml -e anthropic_api_key=sk-ant-...` (voir [ansible/README.md](ansible/README.md)) |

Démarrage rapide sur un serveur neuf :

```bash
apt install -y git
git clone https://github.com/Sleeck/ipaas.git /root/ipaas
cd /root/ipaas
ANTHROPIC_API_KEY=sk-ant-... bash install-pentagi-strix.sh
```

Sans clé, tout s'installe quand même. Il suffit ensuite de la renseigner dans
`/root/credentials/llm.env`, puis de relancer l'installation.

## Après l'installation

| Élément | Où |
| --- | --- |
| Identifiants et usage | `cat /root/credentials/pentagi.txt` |
| Interface PentAGI | `https://IP_DU_SERVEUR:8443` (certificat auto-signé) |
| Hermes Agent | `hermes`, ou `hermes -z "liste les flows PentAGI"` |
| PentAGI en ligne de commande | `pentagi-cli list`, `pentagi-cli create "..."` |
| Strix en arrière-plan | `strix-scan start https://cible -m quick` |
| Modèle Claude | `CLAUDE_MODEL` dans `/root/credentials/llm.env` (opus / sonnet / haiku 5.5) |

L'IP publique est mise à jour automatiquement au démarrage du serveur (service
`pentagi-update-ip`).

## Sécurité

- **N'utilise ces outils que sur des cibles que tu as l'autorisation écrite de tester.**
  Les skills Hermes demandent cette confirmation avant tout lancement.
- Les sandboxes de PentAGI ouvrent des ports entre 28000 et 29999 sur l'IP publique,
  pour les connexions de retour (reverse shells). Filtre-les avec un pare-feu si le
  serveur reste exposé longtemps.
- Hermes tourne en root. Son mode d'approbation `smart` fait relire les commandes
  risquées par le modèle avant exécution. Le mode `off` supprime ce garde-fou.
- `/root/credentials` contient tous les secrets (droits 600). Ne versionne jamais ce dossier.

## Notes techniques

- LiteLLM retire les paramètres refusés par les modèles Claude 5.5 (`temperature`,
  `top_p`, `top_k`, `reasoning_effort`), ainsi que `response_format`, qu'il traduirait
  en `output_format`, un paramètre obsolète côté Anthropic.
- Strix et Hermes sont installés depuis PyPI avec pipx, dans `/opt/pipx`.
- Les versions ne sont pas figées : PentAGI (branche `master`), LiteLLM
  (`main-stable`), Strix et Hermes (dernière version). Une mise à jour en amont peut
  nécessiter une adaptation.
