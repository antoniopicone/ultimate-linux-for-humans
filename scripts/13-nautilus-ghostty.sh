#!/usr/bin/env bash
# 13-nautilus-ghostty.sh — verifica/attiva la voce "Apri in Ghostty" nel
# menu contestuale di Nautilus.
#
# Non serve installare nessuna estensione terza: il pacchetto apt "ghostty"
# di Ubuntu 26.04 porta già di suo un'estensione Nautilus nativa in
# /usr/share/nautilus-python/extensions/ghostty.py (adattata da quella di
# WezTerm), che aggiunge la voce "Apri in Ghostty" e la lancia già con
# --working-directory e --gtk-single-instance=false. Ci basta assicurarci
# che python3-nautilus sia installato (perché Nautilus carichi le estensioni
# Python) e riavviare Nautilus.
#
# NOTA STORICA: una versione precedente di questo script installava
# l'estensione nautilus-open-any-terminal via pip. Con l'estensione nativa
# di Ghostty ora presente in Ubuntu 26.04 questo produce due voci duplicate
# nel menu ("Apri in Ghostty" x2) — non farlo. Se il tuo sistema ha ancora
# quella vecchia installazione, rimuovila con:
#   pip uninstall --break-system-packages nautilus-open-any-terminal
#   rm -f ~/.local/share/nautilus-python/extensions/nautilus_open_any_terminal.py
#
# Uso: ./13-nautilus-ghostty.sh

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user

if ! is_installed ghostty; then
    log_err "Ghostty non risulta installato: esegui prima 12-install-ghostty.sh."
    exit 1
fi

apt_update_once
log_info "Installo python3-nautilus (necessario per caricare estensioni Python in Nautilus)..."
sudo apt install -y python3-nautilus

if [[ -f "${HOME}/.local/share/nautilus-python/extensions/nautilus_open_any_terminal.py" ]]; then
    log_warn "Trovata una vecchia installazione di nautilus-open-any-terminal (pip)."
    log_warn "Causerebbe una voce duplicata insieme a quella nativa di Ghostty: la rimuovo."
    pip uninstall -y --break-system-packages nautilus-open-any-terminal 2>/dev/null || true
    rm -f "${HOME}/.local/share/nautilus-python/extensions/nautilus_open_any_terminal.py"
    rm -rf "${HOME}/.local/share/nautilus-python/extensions/__pycache__"
fi

log_info "Riavvio Nautilus perché carichi l'estensione..."
nautilus -q || true

log_ok "Fatto: tasto destro su una cartella → 'Apri in Ghostty' aprirà Ghostty."
