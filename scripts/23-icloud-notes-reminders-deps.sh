#!/usr/bin/env bash
# 23-icloud-notes-reminders-deps.sh — dipendenze di sviluppo per la futura
# integrazione dei contenuti iCloud (Note, Promemoria, ecc.) in questa
# ricetta.
#
# STATO: solo preparazione. Questo script installa le librerie di base per
# compilare un'app GTK4/libadwaita con syntax highlighting (gtksourceview) —
# non esiste ancora nessuna app del genere in questa ricetta, arriverà in un
# prossimo passo (vedi README.md, "Backlog").
#
# Uso: ./23-icloud-notes-reminders-deps.sh

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user
apt_update_once

log_info "Installo le dipendenze di sviluppo GTK4/libadwaita/gtksourceview..."
sudo apt install -y \
    libgtk-4-dev \
    python3-dev \
    libadwaita-1-dev \
    libgtksourceview-5-dev

log_ok "Fatto. Nota: python3-dev serve anche altrove in questa ricetta"
log_ok "(build di fuse-python per icloud-linux, vedi README.md)."
