#!/usr/bin/env bash
# 10-remove-firefox.sh — rimuove Firefox (snap, preinstallato di default su
# Ubuntu 26.04) e blocca la sua reinstallazione automatica.
#
# Uso: ./10-remove-firefox.sh

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user

log_info "Rimozione di Firefox..."

# Firefox su Ubuntu è distribuito come snap: va rimosso il snap, non un
# pacchetto apt.
if snap list firefox >/dev/null 2>&1; then
    sudo snap remove --purge firefox
    log_ok "Snap 'firefox' rimosso."
else
    log_warn "Snap 'firefox' non trovato (forse già rimosso)."
fi

# Alcune installazioni hanno anche il pacchetto apt "firefox" (transizionale,
# che si limita a installare lo snap): lo rimuoviamo se presente e lo
# blocchiamo per evitare che un futuro 'apt upgrade' lo reinstalli.
if is_installed firefox; then
    sudo apt purge -y firefox
    log_ok "Pacchetto apt 'firefox' rimosso."
fi
sudo apt-mark hold firefox >/dev/null 2>&1 || true

log_ok "Firefox rimosso."
