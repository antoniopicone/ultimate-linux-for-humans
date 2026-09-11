#!/usr/bin/env bash
# 14-install-fonts.sh — installa i font "stile Windows/Office" e i font a
# larghezza fissa per il terminale (JetBrains Mono, Hack Nerd Font) su un
# sistema già installato e in esecuzione (VM di test inclusa). Versione
# standalone dello stesso blocco presente in disk-setup/autoinstall.yaml.tpl
# e live-iso/chroot-customize.sh, per installarli al volo senza rigenerare
# l'autoinstall/la ISO.
#
# Uso: ./14-install-fonts.sh [percorso/ai/font-SFPro-scaricati-a-mano]
#
# Il parametro opzionale serve solo per SF Pro (macOS): vedi la sezione
# dedicata più sotto sul perché non viene scaricato automaticamente.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user
ensure_universe_enabled
ensure_multiverse_enabled
apt_update_once

# --- Font "stile Microsoft/Windows" ----------------------------------------

# I font "core" storici di Microsoft (Arial, Times New Roman, Courier New,
# Georgia, Verdana, Comic Sans MS, Impact, Trebuchet MS, Andale Mono,
# Webdings) SONO liberamente ridistribuibili sotto l'EULA storica
# "TrueType core fonts for the Web": il pacchetto ttf-mscorefonts-installer
# (multiverse) li scarica e installa da solo, accettando l'EULA in modo non
# interattivo via debconf (equivalente a spuntare "Accetto" nella finestra
# di dialogo che altrimenti apparirebbe).
if is_installed ttf-mscorefonts-installer; then
    log_warn "ttf-mscorefonts-installer già installato, salto."
else
    log_info "Installo i font Microsoft 'core' (Arial, Times New Roman, ...) — accetto l'EULA non interattivamente..."
    echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | sudo debconf-set-selections
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ttf-mscorefonts-installer
    log_ok "Font Microsoft 'core' installati."
fi

# I font più recenti di Office (Calibri, Cambria, Candara, Consolas,
# Constantia, Corbel) NON sono coperti da quella EULA: restano proprietari
# di Microsoft, licenziati solo con Windows/Office, non ridistribuibili
# liberamente. Installiamo Carlito e Caladea: sostituti liberi (licenza
# OFL), metric-compatible con Calibri e Cambria (stessa metrica carattere
# per carattere, usati da LibreOffice/Google Docs proprio per questo) — un
# documento impaginato con Calibri/Cambria resta identico a video e in
# stampa.
if is_installed fonts-crosextra-carlito && is_installed fonts-crosextra-caladea; then
    log_warn "Carlito/Caladea (sostituti di Calibri/Cambria) già installati, salto."
else
    log_info "Installo Carlito e Caladea (sostituti liberi di Calibri e Cambria)..."
    sudo apt-get install -y fonts-crosextra-carlito fonts-crosextra-caladea
    log_ok "Carlito e Caladea installati."
fi

# --- Font a larghezza fissa (terminale) -------------------------------------

if is_installed fonts-jetbrains-mono; then
    log_warn "JetBrains Mono già installato, salto."
else
    log_info "Installo JetBrains Mono..."
    sudo apt-get install -y fonts-jetbrains-mono
    log_ok "JetBrains Mono installato."
fi

# Hack Nerd Font (Hack patchato con le icone Nerd Fonts: Powerline, Font
# Awesome, ecc. — utile per prompt come Pure/Starship/p10k e barre di stato
# come waybar/polybar): non è in nessun repository Ubuntu, va preso dalla
# release ufficiale del progetto nerd-fonts (licenza MIT).
HACK_NERD_DIR="${HOME}/.local/share/fonts/HackNerdFont"
if [[ -d "${HACK_NERD_DIR}" ]] && compgen -G "${HACK_NERD_DIR}/*.ttf" >/dev/null 2>&1; then
    log_warn "Hack Nerd Font già installato in ${HACK_NERD_DIR}, salto."
else
    log_info "Scarico e installo Hack Nerd Font..."
    command -v unzip >/dev/null 2>&1 || sudo apt-get install -y unzip
    TMP_ZIP="$(mktemp --suffix=.zip)"
    curl -fsSL -o "${TMP_ZIP}" \
        "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Hack.zip"
    mkdir -p "${HACK_NERD_DIR}"
    unzip -oq "${TMP_ZIP}" -d "${HACK_NERD_DIR}" '*.ttf'
    rm -f "${TMP_ZIP}"
    log_ok "Hack Nerd Font installato in ${HACK_NERD_DIR}."
fi

# --- SF Pro (macOS) ----------------------------------------------------

# San Francisco (SF Pro/SF Mono) è di Apple: la licenza (Apple Font License
# Agreement, developer.apple.com/fonts/) ne limita l'uso alla progettazione
# di interfacce PER piattaforme Apple e ne VIETA la ridistribuzione — per
# questo non lo scarichiamo da un mirror non ufficiale. Se lo hai già
# scaricato tu da developer.apple.com/fonts/ (serve un Apple ID,
# l'accettazione della licenza è personale) ed estratto in una cartella,
# passala come primo argomento a questo script per installarlo da lì.
SF_PRO_SRC="${1:-}"
if [[ -n "${SF_PRO_SRC}" ]]; then
    if [[ -d "${SF_PRO_SRC}" ]]; then
        log_info "Installo i font SF Pro trovati in ${SF_PRO_SRC}..."
        mkdir -p "${HOME}/.local/share/fonts/SF-Pro"
        FOUND_ANY=0
        while IFS= read -r -d '' f; do
            cp -n "${f}" "${HOME}/.local/share/fonts/SF-Pro/"
            FOUND_ANY=1
        done < <(find "${SF_PRO_SRC}" \( -iname '*.otf' -o -iname '*.ttf' \) -print0)
        if [[ "${FOUND_ANY}" -eq 1 ]]; then
            log_ok "Font SF Pro installati in ${HOME}/.local/share/fonts/SF-Pro."
        else
            log_warn "Nessun file .otf/.ttf trovato in ${SF_PRO_SRC}."
        fi
    else
        log_err "${SF_PRO_SRC} non è una cartella valida."
    fi
else
    log_warn "SF Pro non installato: scaricalo da https://developer.apple.com/fonts/" \
        "(richiede un Apple ID e l'accettazione della licenza Apple, non ridistribuibile" \
        "liberamente), poi rilancia: $0 /percorso/ai/font/estratti"
fi

fc-cache -f >/dev/null
log_ok "Cache font aggiornata (fc-cache). Font installati."
