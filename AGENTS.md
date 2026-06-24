# Mémoire de session — opencode-autoconf

Ce fichier est automatiquement lu par opencode au début de chaque session.
L'agent doit le mettre à jour à la fin de chaque session avec les nouvelles informations.

## Conventions du projet
- Configuration Ollama distante
- Script shell pour auto-découverte des modèles
- Token GitHub stocké via `credential.helper store`

## Décisions importantes
- **Scoring modèle principal** : tools(+20) + taille(≤+10) + code(+5) + hermes(+5)
- **Petit modèle** : plus petit paramétrage parmi ceux avec tools (ou génératifs)
- **Capacités via `/api/tags`** : utilise le champ `capabilities[]` (Ollama ≥0.6) pour détecter `completion` et `tools` sans appeler `/api/show`
- **Fallback** : si `capabilities` absent, utilise `/api/show` (template parsing)

## État d'avancement
- [x] Initialisation du dépôt Git
- [x] Ajout remote GitHub
- [x] Configuration credential store
- [x] Création README
- [x] Mise en place AGENTS.md
- [x] Configurer les instructions dans opencode.json
- [x] Détection des capacités via `/api/tags` (plus rapide, plus fiable)
- [x] Scoring pondéré pour sélection du modèle principal
- [x] Taille extraite de `details.parameter_size` (API) plutôt que du nom

## Problèmes connus
- (aucun pour l'instant)

## Architecture
- `opencode.json` : config statique du provider Ollama (inclut tous les modèles génératifs)
- `ollama-opencode.sh` : scanne un hôte et génère la config dynamiquement
  - Détection des capacités via `capabilities[]` dans `/api/tags` (completion → génératif, tools → tool calling)
  - Fallback sur `/api/show` si `capabilities` absent
  - Taille extraite de `details.parameter_size` (API), fallback sur le nom du modèle
  - Scoring pour sélection : tools >> taille ~ hermes ~ code
  - Interactive override avec modèles triés par score
  - Génère tous les modèles génératifs dans `opencode.json`
- `AGENTS.md` : mémoire persistante entre sessions
- `README.md` : documentation utilisateur

## Structure des dossiers
- Racine du projet : fichiers de configuration opencode
