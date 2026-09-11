#!/usr/bin/env bash
# 12-install-ghostty.sh — installa Ghostty (in repository universe su Ubuntu
# 26.04) e lo imposta come terminale predefinito al posto di gnome-terminal.
#
# Uso: ./12-install-ghostty.sh

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user

ensure_universe_enabled
apt_update_once

if is_installed ghostty; then
    log_warn "Ghostty è già installato, salto l'installazione."
else
    log_info "Installo ghostty..."
    sudo apt install -y ghostty
    log_ok "Ghostty installato."
fi

# --- Imposta Ghostty come terminale predefinito -------------------------

# 1. Alternative di sistema: x-terminal-emulator, usato da molti tool a riga
#    di comando e da alcune scorciatoie.
if command -v update-alternatives >/dev/null 2>&1; then
    sudo update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator /usr/bin/ghostty 50
    sudo update-alternatives --set x-terminal-emulator /usr/bin/ghostty
    log_ok "x-terminal-emulator impostato su Ghostty."
fi

# 2. Preferenza GNOME: usata da Nautilus ("Apri terminale qui") e da altre
#    app GNOME che rispettano org.gnome.desktop.default-applications.terminal.
if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.desktop.default-applications.terminal exec 'ghostty' || true
    gsettings set org.gnome.desktop.default-applications.terminal exec-arg '-e' || true
    log_ok "Ghostty impostato come terminale predefinito in GNOME."
fi

# 3. Scorciatoia da tastiera GNOME (Super+T), sovrascrivendo eventuali
#    binding personalizzati preesistenti in modo additivo.
if command -v gsettings >/dev/null 2>&1; then
    KEY_PATH="org.gnome.settings-daemon.plugins.media-keys custom-keybindings"
    LIST="$(gsettings get ${KEY_PATH} 2>/dev/null || echo "@as []")"
    SLOT="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ubuntu-ultimate-ghostty/"
    if [[ "${LIST}" != *"${SLOT}"* ]]; then
        if [[ "${LIST}" == "@as []" || "${LIST}" == "[]" ]]; then
            NEW_LIST="['${SLOT}']"
        else
            NEW_LIST="${LIST%]}, '${SLOT}']"
        fi
        gsettings set ${KEY_PATH} "${NEW_LIST}" || true
    fi
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"${SLOT}" name 'Apri Ghostty' || true
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"${SLOT}" command 'ghostty' || true
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"${SLOT}" binding '<Super>t' || true
    log_ok "Scorciatoia Super+T impostata per aprire Ghostty."
fi
