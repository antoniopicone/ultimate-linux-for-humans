#!/usr/bin/env bash
# 15-onlyoffice.sh — rimuove LibreOffice (se presente) e installa ONLYOFFICE
# Desktop Editors al suo posto, creando 3 voci .desktop per aprire
# direttamente un documento/foglio di calcolo/presentazione vuoti. Idempotente:
# rilanciabile senza effetti collaterali (rimuove solo se LibreOffice è
# davvero installato, installa ONLYOFFICE solo se non c'è già, i .desktop
# vengono comunque riscritti identici ad ogni run).
#
# Uso: ./15-onlyoffice.sh

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user

# --- Rimuove LibreOffice, se presente ---------------------------------------
LIBREOFFICE_PKGS="$(dpkg-query -W -f='${Package}\n' 'libreoffice*' 2>/dev/null || true)"
if [[ -n "${LIBREOFFICE_PKGS}" ]]; then
    log_info "Rimuovo LibreOffice..."
    # shellcheck disable=SC2086
    sudo apt-get purge -y ${LIBREOFFICE_PKGS}
    sudo apt-get autoremove -y
    log_ok "LibreOffice rimosso."
else
    log_warn "LibreOffice non risulta installato, salto la rimozione."
fi

# --- Installa ONLYOFFICE Desktop Editors, se non già presente ---------------
# Repository apt ufficiale (non snap, per coerenza con la scelta già fatta
# per Brave/Ghostty/Tailscale in questo progetto: aggiornamenti automatici
# via apt upgrade, nessun sandboxing snap).
if is_installed onlyoffice-desktopeditors; then
    log_warn "onlyoffice-desktopeditors già installato, salto."
else
    log_info "Aggiungo il repository ufficiale di ONLYOFFICE..."
    sudo apt-get install -y gnupg dirmngr
    mkdir -p -m 700 ~/.gnupg
    gpg --no-default-keyring --keyring gnupg-ring:/tmp/onlyoffice.gpg \
        --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys CB2DE8E5
    chmod 644 /tmp/onlyoffice.gpg
    sudo chown root:root /tmp/onlyoffice.gpg
    sudo mv /tmp/onlyoffice.gpg /usr/share/keyrings/onlyoffice.gpg
    echo 'deb [signed-by=/usr/share/keyrings/onlyoffice.gpg] https://download.onlyoffice.com/repo/debian squeeze main' \
        | sudo tee /etc/apt/sources.list.d/onlyoffice.list >/dev/null

    apt_update_once
    log_info "Installo onlyoffice-desktopeditors..."
    sudo apt-get install -y onlyoffice-desktopeditors
    log_ok "ONLYOFFICE installato."
fi

# --- 3 .desktop per aprire direttamente un file nuovo -----------------------
# Usano i flag --new:word/--new:cell/--new:slide del binario
# (/usr/bin/desktopeditors), documentati da ONLYOFFICE stesso — non un
# trucco nostro. Sovrascritti ad ogni run: idempotenti per costruzione.
log_info "Creo le voci .desktop per Documento/Foglio/Presentazione ONLYOFFICE..."

sudo tee /usr/share/applications/onlyoffice-new-document.desktop >/dev/null <<'DESKTOPEOF'
[Desktop Entry]
Type=Application
Name=Nuovo documento ONLYOFFICE
GenericName=Documento di testo
Comment=Crea un nuovo documento di testo con ONLYOFFICE
Exec=/usr/bin/desktopeditors --new:word
Icon=x-office-document
Terminal=false
Categories=Office;WordProcessor;
DESKTOPEOF

sudo tee /usr/share/applications/onlyoffice-new-spreadsheet.desktop >/dev/null <<'DESKTOPEOF'
[Desktop Entry]
Type=Application
Name=Nuovo foglio di calcolo ONLYOFFICE
GenericName=Foglio di calcolo
Comment=Crea un nuovo foglio di calcolo con ONLYOFFICE
Exec=/usr/bin/desktopeditors --new:cell
Icon=x-office-spreadsheet
Terminal=false
Categories=Office;Spreadsheet;
DESKTOPEOF

sudo tee /usr/share/applications/onlyoffice-new-presentation.desktop >/dev/null <<'DESKTOPEOF'
[Desktop Entry]
Type=Application
Name=Nuova presentazione ONLYOFFICE
GenericName=Presentazione
Comment=Crea una nuova presentazione con ONLYOFFICE
Exec=/usr/bin/desktopeditors --new:slide
Icon=x-office-presentation
Terminal=false
Categories=Office;Presentation;
DESKTOPEOF

sudo chmod 644 /usr/share/applications/onlyoffice-new-*.desktop
sudo update-desktop-database /usr/share/applications >/dev/null 2>&1 || true

log_ok "Fatto: 3 voci create in /usr/share/applications/ (Nuovo documento / Nuovo foglio di calcolo / Nuova presentazione ONLYOFFICE), visibili nel menu app."
