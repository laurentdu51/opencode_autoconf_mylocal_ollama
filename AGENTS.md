# Mémoire de session — opencode-autoconf

Ce fichier est automatiquement lu par opencode au début de chaque session.
L'agent doit le mettre à jour à la fin de chaque session avec les nouvelles informations.

## Conventions du projet
- Configuration Ollama distante (rpi2:11434)
- Script shell pour auto-découverte des modèles
- Token GitHub stocké via `credential.helper store`

## Décisions importantes
- (à documenter au fil des sessions)

## État d'avancement
- [x] Initialisation du dépôt Git
- [x] Ajout remote GitHub
- [x] Configuration credential store
- [x] Création README
- [x] Mise en place AGENTS.md
- [x] Configurer les instructions dans opencode.json

## Problèmes connus
- (aucun pour l'instant)

## Architecture
- `opencode.json` : config statique du provider Ollama (inclut tous les modèles génératifs)
- `ollama-opencode.sh` : scanne un hôte et génère la config dynamiquement
  - Détection de type via `/api/show` (vérifie la présence d'un template de chat)
  - Auto-sélection du modèle primaire : code (coder/ccode) > plus gros paramétrage
  - Auto-sélection du petit modèle : plus petit paramétrage (modèles sans taille ignorés)
  - Génère tous les modèles génératifs dans `opencode.json`
- `AGENTS.md` : mémoire persistante entre sessions
- `README.md` : documentation utilisateur

## Structure des dossiers
- Racine du projet : fichiers de configuration opencode
