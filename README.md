# opencode-autoconf

Configuration automatique d'opencode avec un serveur Ollama distant.

## Fichiers

- **`opencode.json`** — Configuration statique pointant vers un serveur Ollama (rpi2:11434).
- **`ollama-opencode.sh`** — Script de découverte automatique : scanne un hôte Ollama, liste les modèles disponibles et génère `opencode.json` dynamiquement.

## Utilisation

### Via le script (recommandé)

```bash
# Scan interactif
./ollama-opencode.sh

# Scan d'un hôte spécifique
./ollama-opencode.sh 192.168.1.50

# Scan + lance opencode directement
./ollama-opencode.sh 192.168.1.50 --launch
```

Le script interroge l'API `/api/tags`, sélectionne un modèle principal (code > général) et un petit modèle, puis écrit `opencode.json`.

### Via la configuration statique

```bash
OPENCODE_CONFIG=./opencode.json opencode
```

## Prérequis

- Ollama en cours d'exécution sur le serveur cible (port 11434)
- `curl`, `python3` (ou `jq`) installés
- `opencode` installé

> Configuré pour utiliser le credential store Git.
