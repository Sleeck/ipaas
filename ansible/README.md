# PentAGI + Strix + Hermes Agent + LiteLLM (Claude) - version Ansible

Même installation que `install-pentagi-strix.sh`, avec les mêmes fichiers dans
`/root/credentials`. On peut passer d'une version à l'autre, et relancer le
playbook autant de fois que voulu : un deuxième passage ne change rien.

```
Hermes Agent ──┬─ pentagi-cli ──> PentAGI ──┐
               ├─ strix-scan ───> Strix ────┤
               │                            ▼
               └──────────────────> LiteLLM (127.0.0.1:4000) ──> API Anthropic (Claude)
```

## Prérequis

- Ubuntu 24.04, en root, 4 Go de RAM, 20 Go de disque.
- `ansible-core` 2.16 ou plus récent (le paquet Ubuntu suffit, aucune collection
  supplémentaire n'est nécessaire).

## Lancement sur le serveur lui-même (par défaut)

`inventory.ini` cible déjà la machine locale. Sur le serveur, en root :

```bash
apt install -y ansible-core git
git clone https://github.com/Sleeck/ipaas.git /root/ipaas
cd /root/ipaas/ansible
ansible-playbook site.yml -e anthropic_api_key=sk-ant-...
```

Pour mettre à jour plus tard : `cd /root/ipaas && git pull`, puis relance `ansible-playbook`.

## Lancement à distance (optionnel)

Depuis une machine Linux, macOS ou WSL : remplace la ligne `localhost` de
`inventory.ini` par `IP ansible_user=root`, puis lance la même commande
`ansible-playbook`.

Sans `-e anthropic_api_key=...`, tout s'installe quand même, et la clé déjà
présente sur le serveur (dans `/root/credentials/llm.env`) est conservée.

Pour ne pas laisser la clé dans l'historique du shell, chiffre-la avec ansible-vault :

```bash
ansible-vault encrypt_string 'sk-ant-...' --name anthropic_api_key > group_vars/vault.yml
ansible-playbook site.yml -e @group_vars/vault.yml --ask-vault-pass
```

## Options utiles

| Option | Effet |
| --- | --- |
| `-e claude_model=claude-sonnet-5-5` | Modèle utilisé partout (opus / sonnet / haiku 5.5) |
| `-e hermes_approvals_mode=off` | Hermes exécute les commandes sans validation (à tes risques) |
| `-e docker_pull_always=true` | Met à jour les images Docker |
| `--tags hermes` | Ne rejoue que Hermes (aussi : `pentagi`, `litellm`, `strix`) |
| `--check --diff` | Montre ce qui changerait, sans rien modifier |

Les autres réglages sont dans `group_vars/all.yml`.

## Après l'installation

```bash
ssh root@IP cat /root/credentials/pentagi.txt
```

Ce fichier contient l'URL et les identifiants de PentAGI, ainsi que l'usage de
Strix et de Hermes (`hermes`, `pentagi-cli`, `strix-scan`).
