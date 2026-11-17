#!/usr/bin/env python3
"""Branche Hermes Agent sur LiteLLM sans écraser le reste de sa configuration.

Variables d'environnement : LITELLM_MASTER_KEY, CLAUDE_MODEL, APPROVALS_MODE.
Affiche "changed" ou "ok".
"""
import os
import yaml

p = "/root/.hermes/config.yaml"
os.makedirs(os.path.dirname(p), exist_ok=True)
cfg = (yaml.safe_load(open(p)) if os.path.exists(p) else None) or {}
before = yaml.safe_dump(cfg, sort_keys=True)

m = cfg.setdefault("model", {})
m.update({
    "provider": "custom",
    "base_url": "http://127.0.0.1:4000/v1",
    "api_key": os.environ["LITELLM_MASTER_KEY"],
    "default": os.environ["CLAUDE_MODEL"],
    "context_length": 1000000,
})
sk = cfg.setdefault("skills", {})
auto = sk.get("auto_load") or []
for s in ("pentagi", "strix"):
    if s not in auto:
        auto.append(s)
sk["auto_load"] = auto
cfg.setdefault("approvals", {})["mode"] = os.environ.get("APPROVALS_MODE", "smart")

if yaml.safe_dump(cfg, sort_keys=True) != before:
    with open(p, "w") as f:
        yaml.safe_dump(cfg, f, sort_keys=False, allow_unicode=True)
    print("changed")
else:
    print("ok")
os.chmod(p, 0o600)
