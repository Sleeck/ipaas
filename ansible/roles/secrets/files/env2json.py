#!/usr/bin/env python3
"""Lit un fichier KEY=valeur et l'affiche en JSON (lignes vides et commentaires ignorés)."""
import json, sys

out = {}
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip()
print(json.dumps(out))
