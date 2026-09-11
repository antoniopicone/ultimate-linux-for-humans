#!/usr/bin/env bash
# 22-flatpak-git-eza-ghostty.sh — quattro cose scollegate tra loro ma comode
# da fare in un colpo solo su un sistema già installato:
#   1. supporto Flatpak/Flathub (anche dentro "Software");
#   2. git configurato globalmente (nome + email);
#   3. eza (sostituto moderno di "ls", con icone), con alias in .zshrc;
#   4. un file di configurazione per Ghostty (font, tema, ecc.).
#
# Versione standalone dell'equivalente blocco in disk-setup/autoinstall.yaml.tpl
# (che usa nome/email raccolti da disk-setup/prepare-autoinstall.sh invece di
# chiederli qui interattivamente).
#
# Uso: ./22-flatpak-git-eza-ghostty.sh

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user
apt_update_once

# --- 1. Flatpak -----------------------------------------------------------

log_info "Installo il supporto Flatpak/Flathub..."
sudo apt install -y flatpak gnome-software-plugin-flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
log_ok "Flatpak pronto (Flathub aggiunto come remote)."

# --- 2. Git -----------------------------------------------------------------

# Se git risulta già configurato, propone i valori esistenti come default
# invece di chiedere da zero (comodo se lo script viene rieseguito).
CURRENT_GIT_NAME="$(git config --global user.name 2>/dev/null || true)"
CURRENT_GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"

read -rp "Nome e Cognome per git${CURRENT_GIT_NAME:+ [${CURRENT_GIT_NAME}]}: " GIT_NAME
GIT_NAME="${GIT_NAME:-${CURRENT_GIT_NAME}}"
while [[ -z "${GIT_NAME}" ]]; do
    read -rp "Nome e Cognome (obbligatorio): " GIT_NAME
done

read -rp "Email per git${CURRENT_GIT_EMAIL:+ [${CURRENT_GIT_EMAIL}]}: " GIT_EMAIL
GIT_EMAIL="${GIT_EMAIL:-${CURRENT_GIT_EMAIL}}"
while [[ -z "${GIT_EMAIL}" ]]; do
    read -rp "Email (obbligatoria): " GIT_EMAIL
done

git config --global user.name "${GIT_NAME}"
git config --global user.email "${GIT_EMAIL}"
log_ok "git configurato: ${GIT_NAME} <${GIT_EMAIL}>"

# --- 3. eza -------------------------------------------------------------

# Nessun pacchetto ufficiale Ubuntu: repository apt di terze parti di
# eza-community, comandi presi da INSTALL.md del progetto upstream
# (verificati prima di usarli).
if is_installed eza; then
    log_warn "eza già installato, salto l'aggiunta del repository."
else
    log_info "Aggiungo il repository apt di eza (deb.gierens.de)..."
    sudo mkdir -p /etc/apt/keyrings
    wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
        | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
    echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
        | sudo tee /etc/apt/sources.list.d/gierens.list >/dev/null
    sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
    sudo apt update
    sudo apt install -y eza
    log_ok "eza installato."
fi

ZSHRC="${HOME}/.zshrc"
if [[ -f "${ZSHRC}" ]] && grep -qF 'alias ls="eza --icons=always"' "${ZSHRC}"; then
    log_warn "Alias 'ls' -> eza già presente in ${ZSHRC}, salto."
else
    log_info "Aggiungo l'alias 'ls' -> eza a ${ZSHRC}..."
    {
        echo
        echo 'alias ls="eza --icons=always"'
    } >> "${ZSHRC}"
    log_ok "Alias aggiunto (effettivo alla prossima apertura di una shell zsh)."
fi

# --- 4. Ghostty --------------------------------------------------------------

# Font Hack Nerd Font Mono: installato da scripts/14-install-fonts.sh (o
# dall'autoinstall) insieme agli altri font di questa ricetta — se manca,
# Ghostty resta comunque utilizzabile ma con un font diverso da quello
# richiesto qui, quindi solo un avviso, non un errore bloccante.
if ! fc-list 2>/dev/null | grep -qi "Hack Nerd Font"; then
    log_warn "Non trovo 'Hack Nerd Font' installato: esegui prima ./14-install-fonts.sh"
    log_warn "(o l'autoinstall completo), altrimenti Ghostty userà un font diverso."
fi

# NOTA IMPORTANTE: la chiave "language" di Ghostty NON è il layout di
# tastiera — è la lingua dei testi dell'interfaccia grafica di Ghostty
# stesso (richiede GTK e Ghostty 1.3+, verificato sulla documentazione
# ufficiale). Il layout di tastiera vero e proprio resta quello impostato a
# livello di sistema (in questa ricetta: italiano, vedi
# disk-setup/autoinstall.yaml.tpl "keyboard: layout: it") — Ghostty lo
# eredita automaticamente, non richiede nessuna configurazione propria.
# Impostato "language = it" solo per coerenza con locale/tastiera del resto
# della ricetta.
log_info "Scrivo la configurazione di Ghostty..."
mkdir -p "${HOME}/.config/ghostty"
cat > "${HOME}/.config/ghostty/config" <<'GHOSTTYCONFIGEOF'
font-family = Hack Nerd Font Mono
font-size = 11
language = it
window-padding-x = 10
theme = Catppuccin Mocha
shell-integration-features = no-cursor
cursor-style = underline
bell-features = no-audio
term = xterm-256color
GHOSTTYCONFIGEOF

log_ok "Fatto: Flatpak/Flathub, git, eza (con alias 'ls') e la configurazione di"
log_ok "Ghostty sono pronti. Riavvia Ghostty (e apri una nuova shell zsh) perché"
log_ok "tutto abbia effetto."
