#!/usr/bin/env bash
#
# 24-icloud-notes.sh
#
# UNIFICA i due script precedenti (24-icloud-notes-md-setup.sh +
# 25-icloud-notes-list.py) in uno solo, e aggiunge quello che mancava:
# le note non vengono più solo elencate da una cartella di lavoro
# temporanea, ma scaricate DAVVERO in ~/Notes (override con
# ICLOUD_NOTES_DIR=...), pronte per essere aperte con qualunque editor
# di testo/Markdown — non serve nessun passaggio in più, perché
# icloud-md scrive già un file .md per nota, uno a uno.
#
# Cosa fa, in ordine, tutto idempotente/rieseguibile:
#   1. Node.js 20+ via repository NodeSource (icloud-md richiede Node 20+;
#      i pacchetti Ubuntu sono troppo vecchi) — salta se già presente.
#   2. `icloud-md` globale via npm — salta se il comando esiste già.
#   3. Chromium per Playwright (necessario per il login con vero browser:
#      password/2FA/eventuali sfide anti-bot le gestisce Apple stessa,
#      non un flusso reverse-engineered) — salta se già scaricato.
#      NOTA: da icloud-md v0.1.1 il primo `clone` scarica Chromium da solo
#      alla bisogna (verificato leggendo le release notes upstream), quindi
#      questo passaggio è ormai solo un pre-warm per evitare l'attesa (o un
#      prompt interattivo bloccante su install globali) al primo login vero.
#   4. Prima esecuzione -> `icloud-md clone ~/Notes` (si apre un browser
#      per il login, interattivo). Esecuzioni successive -> `icloud-md pull
#      ~/Notes` (aggiorna quello che è cambiato, non riclona tutto).
#      Il marcatore usato per distinguere le due situazioni è la presenza
#      di `~/Notes/.icloud-md/` (verificato dal README upstream: è lì che
#      icloud-md registra a quale account è collegata la cartella).
#   5. Elenco delle note scaricate (nome file = titolo nota, perché è così
#      che icloud-md le scrive), con supporto `--json` per output
#      machine-readable.
#
# NON TESTATO su hardware reale in questa sessione (nessun account iCloud
# reale né ambiente Node/Playwright disponibili in questo sandbox): la
# sintassi è stata verificata (bash -n), ma il login 2FA vero e il download
# reale delle note vanno confermati sull'hardware di Antonio.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user

NOTES_DIR="${ICLOUD_NOTES_DIR:-$HOME/Notes}"
JSON_OUTPUT=0
if [ "${1:-}" = "--json" ]; then
    JSON_OUTPUT=1
fi

# Wrapper su log_info (lib/common.sh) invece di un log() locale duplicato:
# in modalità --json non possiamo però stampare nulla su stdout se non il
# JSON finale, quindi i log di avanzamento restano forzati su stderr.
log() {
    log_info "$@" >&2
}

# ---------------------------------------------------------------------
# 1. Node.js 20+
# ---------------------------------------------------------------------
node_is_new_enough() {
    command -v node >/dev/null 2>&1 || return 1
    major="$(node -e 'console.log(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
    [ "${major:-0}" -ge 20 ]
}

if node_is_new_enough; then
    log "Node.js >= 20 già presente; salto l'installazione."
else
    log "Installo Node.js 20+ via repository NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null
    sudo apt-get install -y nodejs
fi

# ---------------------------------------------------------------------
# 2. icloud-md
# ---------------------------------------------------------------------
if command -v icloud-md >/dev/null 2>&1; then
    log "icloud-md già installato; salto."
else
    log "Installo icloud-md globalmente via npm..."
    sudo npm install -g icloud-md
fi

# ---------------------------------------------------------------------
# 3. Chromium per Playwright (pre-warm; icloud-md lo scaricherebbe comunque
#    da solo al primo clone, ma farlo qui evita l'attesa/il prompt durante
#    il login vero e proprio)
# ---------------------------------------------------------------------
PLAYWRIGHT_CACHE="$HOME/.cache/ms-playwright"
if [ -d "$PLAYWRIGHT_CACHE" ] && find "$PLAYWRIGHT_CACHE" -maxdepth 1 -iname 'chromium-*' -print -quit | grep -q .; then
    log "Chromium per Playwright già presente; salto."
else
    log "Pre-scarico Chromium per il login interattivo (Playwright)..."
    npx --yes playwright install --with-deps chromium
fi

# ---------------------------------------------------------------------
# 4. Clone (prima volta) o Pull (cartella già collegata)
# ---------------------------------------------------------------------
mkdir -p "$(dirname "$NOTES_DIR")"

if [ -d "$NOTES_DIR/.icloud-md" ]; then
    log "Cartella $NOTES_DIR già collegata a un account: eseguo 'icloud-md pull'..."
    icloud-md pull "$NOTES_DIR"
elif [ -d "$NOTES_DIR" ] && [ -n "$(ls -A "$NOTES_DIR" 2>/dev/null)" ]; then
    log_err "$NOTES_DIR esiste già, non è vuota, ma non risulta collegata" \
        "(manca $NOTES_DIR/.icloud-md). icloud-md rifiuta di clonare dentro una" \
        "cartella non vuota già esistente — sposta/rinomina il contenuto attuale" \
        "oppure imposta ICLOUD_NOTES_DIR su un altro percorso."
    exit 1
else
    log "Prima esecuzione: eseguo 'icloud-md clone $NOTES_DIR'" \
        "(si aprirà un browser per il login: password, eventuale 2FA)..."
    icloud-md clone "$NOTES_DIR"
fi

# ---------------------------------------------------------------------
# 5. Elenco delle note scaricate
# ---------------------------------------------------------------------
mapfile -t NOTE_FILES < <(find "$NOTES_DIR" -type f -name '*.md' | sort)

if [ "$JSON_OUTPUT" = "1" ]; then
    python3 - "$NOTES_DIR" "${NOTE_FILES[@]}" << 'PYEOF'
import json
import os
import sys

notes_dir = sys.argv[1]
files = sys.argv[2:]
notes = []
for f in files:
    notes.append({
        "title": os.path.splitext(os.path.basename(f))[0],
        "path": f,
        "relative_path": os.path.relpath(f, notes_dir),
    })
print(json.dumps(notes, ensure_ascii=False, indent=2))
PYEOF
else
    log "Fatto. Note disponibili in $NOTES_DIR:"
    for f in "${NOTE_FILES[@]}"; do
        rel="${f#"$NOTES_DIR"/}"
        echo "  - $rel"
    done
    echo ""
    echo "Trovate ${#NOTE_FILES[@]} note in $NOTES_DIR — apribili direttamente con" \
         "qualunque editor di testo/Markdown."
fi
