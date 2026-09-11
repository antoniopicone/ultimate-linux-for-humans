#!/usr/bin/env bash
# 11-install-brave.sh — installa Brave Browser dal repository apt ufficiale
# e lo imposta come browser predefinito.
#
# Uso: ./11-install-brave.sh

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user

if is_installed brave-browser; then
    log_warn "Brave è già installato, salto l'installazione."
else
    log_info "Aggiungo il repository ufficiale di Brave..."
    sudo apt install -y curl

    sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
        https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg

    sudo curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources \
        https://brave-browser-apt-release.s3.brave.com/brave-browser.sources

    apt_update_once
    log_info "Installo brave-browser..."
    sudo apt install -y brave-browser
    log_ok "Brave installato."
fi

# Imposta Brave come browser predefinito per l'utente corrente.
if command -v xdg-settings >/dev/null 2>&1; then
    xdg-settings set default-web-browser brave-browser.desktop || \
        log_warn "Impossibile impostare Brave come browser predefinito automaticamente (impostalo da Impostazioni)."
    log_ok "Brave impostato come browser predefinito."
fi
