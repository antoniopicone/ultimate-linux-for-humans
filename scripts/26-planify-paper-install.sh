#!/usr/bin/env bash
#
# 26-planify-paper-install.sh
#
# Installa dal sorgente:
#   1. Planify (github.com/alainm23/planify)   -> icona "promemoria" custom
#   2. Paper   (fork privato di Antonio se raggiungibile, altrimenti
#               l'upstream ufficiale codeberg.org/zagura/paper-notes)
#                                                -> icona "note" custom
#
# NOTA IMPORTANTE SUL CONTESTO DI QUESTA SESSIONE:
# Non ho accesso al repository reale della ricetta (disk-setup/autoinstall.yaml.tpl,
# scripts/) in questa conversazione: ho solo il file di stato di avanzamento
# (claude_ubuntu-ultimate-progress.md). Questo script è quindi consegnato come
# file STANDALONE, con lo stesso stile/pattern degli altri script numerati
# della ricetta (idempotente, verifica sintattica con `bash -n`, nessuna
# assunzione non verificata). Va integrato a mano in scripts/ e richiamato
# dai late-commands, oppure caricami lo zip del repo se vuoi che lo faccia
# direttamente io.
#
# VERIFICATO PER DAVVERO IN QUESTA SESSIONE (sandbox Ubuntu 24.04):
#   - Planify: `meson build --prefix=/usr` si configura con successo con
#     l'elenco di pacchetti apt sotto. La compilazione reale si blocca SOLO
#     sul controllo di versione `libadwaita-1 >= 1.7.0` richiesto dal
#     meson.build upstream (Ubuntu 24.04 ha libadwaita 1.5.0). Aggirando
#     temporaneamente il controllo per continuare il test, la compilazione
#     fallisce per davvero su `Adw.WrapBox` (tipo introdotto in libadwaita
#     1.7, usato da Planify in più punti: DateTimePicker, ItemLabels,
#     ItemLabelChild) - quindi il requisito >=1.7.0 del progetto è corretto,
#     non un bug. Ubuntu 26.04 "Resolute Raccoon" dovrebbe avere una
#     libadwaita abbastanza recente (stack GNOME 50), ma questo NON è stato
#     verificato in questa sessione (sandbox solo 24.04) - da confermare
#     sull'hardware reale prima del 17/09.
#   - Paper (upstream ufficiale, codeberg.org/zagura/paper-notes): build
#     COMPLETA riuscita end-to-end (meson + ninja + ninja install) con
#     l'elenco di pacchetti sotto. **Bug reale trovato e corretto**:
#     `src/meson.build` fissa `dependency('libadwaita-1', version: '1.4.2',
#     required: true)` - senza operatore di confronto, Meson lo tratta come
#     un vincolo di uguaglianza ESATTA, quindi fallisce su qualunque sistema
#     che non abbia libadwaita esattamente 1.4.2 (cioè quasi ovunque, inclusa
#     Ubuntu 26.04). Fix verificato: patch a `>= 1.4.2` prima di configurare
#     - vedi funzione patch_paper_meson_version_pin sotto.
#   - Il progetto "Paper" upstream (gitlab.com/posidon_software/paper) è
#     stato spostato su codeberg.org/zagura/paper-notes ed è marcato
#     ESPLICITAMENTE come "(discontinued)" dall'autore originale - non è un
#     dettaglio nascosto da questo script, Antonio dovrebbe saperlo prima
#     di scegliere se usare il fork privato o l'upstream discontinuato.
#   - .desktop e nome dell'app id/eseguibile installato, letti direttamente
#     dal sorgente (non assunti): Planify -> io.github.alainm23.planify,
#     Paper -> io.posidon.Paper.
#
# BUG REALE TROVATO SULL'HARDWARE DI ANTONIO (non nella sandbox):
#   `meson setup` di Planify arriva fino a `data/meson.build` e fallisce su
#   `ERROR: Program 'msgfmt' not found or not executable` - il pacchetto
#   `gettext` (che fornisce msgfmt) era nell'elenco apt di Paper ma non era
#   stato aggiunto a quello di Planify. Corretto. Su questo hardware
#   libadwaita è già abbastanza recente da superare il controllo >= 1.7.0
#   che in sandbox (Ubuntu 24.04) non era verificabile - buon segno.
#
# NON VERIFICATO:
#   - Il fork privato github.com/antoniopicone/paper-rs: ho provato ad
#     aprirlo senza autenticazione e ho ricevuto 404 (repo privato o
#     inesistente per me) - impossibile sapere se è Vala/meson come
#     l'upstream o una riscrittura Rust (il suffisso "-rs" lo suggerisce).
#     Lo script prova il clone via SSH (git@github.com:...), eseguito come
#     l'utente reale (non come root) in modo da usare la sua chiave/agente
#     SSH già autorizzato su GitHub - lo script non gestisce né chiede
#     alcuna credenziale, l'utente deve avere la chiave già attiva. Rileva
#     poi da solo Cargo.toml (Rust) vs meson.build (Vala) per scegliere come
#     compilarlo; se il clone fallisce, ripiega sull'upstream ufficiale
#     patchato.
#   - Compilazione COMPLETA di Planify con libadwaita >= 1.7.0 reale (bloccata
#     dalla versione della sandbox, vedi sopra).
#   - Che il clone di un repo privato funzioni per davvero dentro un chroot
#     offline di autoinstall: come già notato altrove nella ricetta per
#     cryptsetup-initramfs, questo intero script richiede una connessione di
#     rete raggiungibile durante i late-commands (git clone di entrambi i
#     progetti, più i subproject meson di Planify - chrono e gxml-0.20 -
#     scaricati automaticamente da meson stesso).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# NB: a differenza della maggior parte degli altri script della ricetta,
# qui NON si chiama require_normal_user: questo script deve poter girare
# anche invocato direttamente come root (late-commands dell'autoinstall,
# che girano in chroot come root), oltre che da un utente normale che poi
# si auto-eleva con sudo qui sotto.
if [ "$(id -u)" -ne 0 ]; then
  log_info "Servono i permessi di root (apt-get, ninja install su /usr). Rilancio con sudo..."
  exec sudo -E bash "$0" "$@"
fi

TARGET_USER="${SUDO_USER:-${TARGET_USER:-antonio}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
BUILD_ROOT="/tmp/build-notes-reminders"
ICON_DIR="/usr/share/icons/hicolor/scalable/apps"

# Il fork privato si prova via SSH (git@...): l'utente deve avere già una
# chiave SSH attiva/autorizzata su GitHub per questo repository (nessun
# token o altra credenziale gestita da questo script).
PAPER_RS_GIT_URL="git@github.com:antoniopicone/paper-rs.git"

mkdir -p "$BUILD_ROOT" "$ICON_DIR"

#############################################
# Icone custom (SVG, stile Yaru, no container)
#############################################

install_icon_promemoria() {
  cat > "$ICON_DIR/it.antoniopicone.icons.Promemoria.svg" <<'SVGEOF'
<svg width="256" height="256" viewBox="0 0 256 256" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <filter id="remShadow" x="-40%" y="-40%" width="180%" height="180%">
      <feDropShadow dx="0" dy="5" stdDeviation="6" flood-color="#000000" flood-opacity="0.25"/>
    </filter>
  </defs>
  <g filter="url(#remShadow)" transform="translate(-69.08,-43.54) scale(1.4177)">
    <rect x="64" y="60" width="118" height="140" rx="14" fill="#FFFFFF"/>
    <circle cx="86" cy="92" r="11" fill="#2F86D6"/>
    <path d="M81 92 l4 4 l8 -9" stroke="#FFFFFF" stroke-width="3" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
    <rect x="106" y="87" width="60" height="10" rx="5" fill="#2F86D6" opacity="0.65"/>
    <circle cx="86" cy="128" r="11" fill="none" stroke="#2F86D6" stroke-width="4" opacity="0.55"/>
    <rect x="106" y="123" width="60" height="10" rx="5" fill="#2F86D6" opacity="0.30"/>
    <circle cx="86" cy="164" r="11" fill="none" stroke="#2F86D6" stroke-width="4" opacity="0.55"/>
    <rect x="106" y="159" width="44" height="10" rx="5" fill="#2F86D6" opacity="0.30"/>
    <circle cx="184" cy="72" r="30" fill="#F2994A"/>
    <path d="M184 55 a13 13 0 0 1 13 13 v6 c0 6 3 9 6 11 h-38 c3 -2 6 -5 6 -11 v-6 a13 13 0 0 1 13 -13 Z" fill="#FFFFFF"/>
    <rect x="180" y="52" width="8" height="6" rx="3" fill="#FFFFFF"/>
    <path d="M178 87 a6 6 0 0 0 12 0 Z" fill="#FFFFFF"/>
  </g>
</svg>
SVGEOF
}

install_icon_note() {
  cat > "$ICON_DIR/it.antoniopicone.icons.Note.svg" <<'SVGEOF'
<svg width="256" height="256" viewBox="0 0 256 256" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <filter id="noteShadow" x="-40%" y="-40%" width="180%" height="180%">
      <feDropShadow dx="0" dy="5" stdDeviation="6" flood-color="#000000" flood-opacity="0.25"/>
    </filter>
  </defs>
  <g filter="url(#noteShadow)" transform="translate(-40,-55) scale(1.366)">
    <path d="M76 52 H166 L182 68 V204 a12 12 0 0 1 -12 12 H76 a12 12 0 0 1 -12 -12 V64 a12 12 0 0 1 12 -12 Z" fill="#FFFFFF"/>
    <path d="M166 52 L182 68 H172 a6 6 0 0 1 -6 -6 Z" fill="#D97F2E"/>
    <rect x="85" y="96"  width="76" height="10" rx="5" fill="#F2994A" opacity="0.65"/>
    <rect x="85" y="122" width="76" height="10" rx="5" fill="#F2994A" opacity="0.65"/>
    <rect x="85" y="148" width="52" height="10" rx="5" fill="#F2994A" opacity="0.65"/>
    <g transform="translate(157,138) rotate(45)">
      <rect x="0" y="22" width="18" height="50" fill="#F2994A"/>
      <rect x="12" y="22" width="6" height="50" fill="#D97F2E"/>
      <rect x="0" y="14" width="18" height="8" fill="#C7CDD1"/>
      <rect x="12" y="14" width="6" height="8" fill="#9AA3A8"/>
      <rect x="0" y="16.5" width="18" height="1.3" fill="#9AA3A8"/>
      <rect x="0" y="19" width="18" height="1.3" fill="#9AA3A8"/>
      <path d="M0 6 a6 6 0 0 1 6 -6 h6 a6 6 0 0 1 6 6 v8 h-18 Z" fill="#F3B4C0"/>
      <rect x="12" y="0" width="6" height="14" fill="#E497A6"/>
      <path d="M0 72 H18 L11 87 H7 Z" fill="#E8C79A"/>
      <path d="M11 72 H18 L11 87 Z" fill="#D9B27F"/>
      <path d="M7 87 H11 L9 94 Z" fill="#3A3A3A"/>
    </g>
  </g>
</svg>
SVGEOF
}

#############################################
# 1. Planify -> icona Promemoria
#############################################

install_planify() {
  log_info "Installo le dipendenze di build di Planify (elenco verificato con meson in questa sessione)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    valac meson ninja-build git gettext \
    libgtk-4-dev libadwaita-1-dev libgee-0.8-dev libjson-glib-dev \
    libecal2.0-dev libsoup-3.0-dev libportal-dev libportal-gtk4-dev \
    libspelling-1-dev libgtksourceview-5-dev libicu-dev \
    libsecret-1-dev libgoa-1.0-dev libical-dev

  # Requisito reale confermato leggendo meson.build e verificando che il
  # tipo Adw.WrapBox (usato da Planify) non esista prima di libadwaita 1.7:
  local adw_ver
  adw_ver="$(pkg-config --modversion libadwaita-1 2>/dev/null || echo 0)"
  if ! dpkg --compare-versions "$adw_ver" ge "1.7.0"; then
    log_warn "ATTENZIONE: libadwaita installata ($adw_ver) è più vecchia della 1.7.0 richiesta da Planify (usa Adw.WrapBox)."
    log_info "Su Ubuntu 26.04 dovrebbe già essere soddisfatto dal repository di sistema: verificare comunque prima della demo."
  fi

  rm -rf "$BUILD_ROOT/planify"
  git clone --depth 1 https://github.com/alainm23/planify.git "$BUILD_ROOT/planify"
  cd "$BUILD_ROOT/planify"
  # meson scarica da solo i subproject 'chrono' e 'gxml-0.20' (rete richiesta)
  meson setup build --prefix=/usr
  ninja -C build
  ninja -C build install

  install_icon_promemoria
  local desktop="/usr/share/applications/io.github.alainm23.planify.desktop"
  if [ -f "$desktop" ]; then
    sed -i 's|^Icon=.*|Icon=it.antoniopicone.icons.Promemoria|' "$desktop"
    log_info "Icona di Planify sostituita in $desktop"
  else
    log_warn "ATTENZIONE: $desktop non trovato dopo ninja install, controllare manualmente."
  fi
}

#############################################
# 2. Paper -> icona Note
#############################################

# Bug reale verificato in questa sessione: src/meson.build di Paper fissa
# 'libadwaita-1' a version: '1.4.2' SENZA operatore di confronto, che Meson
# interpreta come uguaglianza esatta -> fallisce su qualunque libadwaita
# diversa da 1.4.2. Patch verificata: portarlo a '>= 1.4.2'.
patch_paper_meson_version_pin() {
  local mfile="$1/src/meson.build"
  if [ -f "$mfile" ] && grep -q "dependency('libadwaita-1', version: '1.4.2'" "$mfile"; then
    sed -i "s/dependency('libadwaita-1', version: '1.4.2', required: true)/dependency('libadwaita-1', version: '>= 1.4.2', required: true)/" "$mfile"
    log_info "Patchato il pin di versione esatto di libadwaita-1 in $mfile (bug upstream verificato)."
  fi
}

install_paper_deps() {
  log_info "Installo le dipendenze di build di Paper (elenco verificato con build reale in questa sessione)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    valac meson ninja-build git gettext desktop-file-utils appstream-util \
    blueprint-compiler \
    libgtk-4-dev libadwaita-1-dev libgee-0.8-dev libgtksourceview-5-dev
}

install_paper() {
  install_paper_deps
  rm -rf "$BUILD_ROOT/paper"
  mkdir -p "$BUILD_ROOT"
  chown "$TARGET_USER":"$TARGET_USER" "$BUILD_ROOT"

  local src_dir="$BUILD_ROOT/paper"
  local cloned_private=0

  # Clone via SSH, eseguito come TARGET_USER (non come root) in modo da usare
  # la sua chiave/agente SSH già attivo verso GitHub - questo script non
  # gestisce né chiede alcuna credenziale. Se la chiave non è caricata/
  # autorizzata sul repo, il clone fallisce e si ripiega sull'upstream.
  log_info "Provo il fork privato di Antonio (paper-rs) via SSH come utente $TARGET_USER..."
  if sudo -u "$TARGET_USER" -H env GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes" \
       git clone --depth 1 "$PAPER_RS_GIT_URL" "$src_dir" 2>/tmp/paper-rs-clone.log; then
    cloned_private=1
  else
    log_info "Clone via SSH del fork privato fallito (chiave SSH non attiva/autorizzata? vedi /tmp/paper-rs-clone.log). Ripiego sull'upstream ufficiale."
  fi

  if [ "$cloned_private" = "1" ]; then
    log_info "Fork privato clonato con successo, provo a capire come si compila (non verificato in questa sessione)."
    if [ -f "$src_dir/Cargo.toml" ]; then
      log_info "Rilevato Cargo.toml: build come progetto Rust."
      if ! command -v cargo >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y cargo
      fi
      (cd "$src_dir" && cargo build --release)
      log_warn "ATTENZIONE: percorso dell'eseguibile, nome del binario e struttura del .desktop di paper-rs sono IGNOTI (repo mai visto prima d'ora) - va completato a mano dopo aver ispezionato l'output di 'cargo build'."
      return
    elif [ -f "$src_dir/meson.build" ]; then
      log_info "Rilevato meson.build: build come il progetto Paper originale (Vala)."
      patch_paper_meson_version_pin "$src_dir"
      (cd "$src_dir" && meson setup build --prefix=/usr && ninja -C build && ninja -C build install)
    else
      log_info "Struttura del fork privato non riconosciuta (né Cargo.toml né meson.build): completare la build a mano."
      return
    fi
  else
    log_info "Uso l'upstream ufficiale (codeberg.org/zagura/paper-notes, contrassegnato 'discontinued' dall'autore)."
    rm -rf "$src_dir"
    git clone --depth 50 https://codeberg.org/zagura/paper-notes.git "$src_dir"
    patch_paper_meson_version_pin "$src_dir"
    (cd "$src_dir" && meson setup build --prefix=/usr && ninja -C build && ninja -C build install)
  fi

  install_icon_note
  local desktop="/usr/share/applications/io.posidon.Paper.desktop"
  if [ -f "$desktop" ]; then
    sed -i 's|^Icon=.*|Icon=it.antoniopicone.icons.Note|' "$desktop"
    log_info "Icona di Paper sostituita in $desktop"
  else
    log_warn "ATTENZIONE: $desktop non trovato dopo ninja install (probabile percorso diverso se è stato usato il fork privato) - controllare manualmente."
  fi
}

#############################################
# main
#############################################

apt-get update
install_planify
install_paper

gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
update-desktop-database -q /usr/share/applications || true

rm -rf "$BUILD_ROOT"
log_info "Sorgenti/build rimossi da $BUILD_ROOT (restano solo i binari installati sotto /usr)."

log_info "Fatto. Ricorda: build completa non verificata end-to-end su libadwaita >= 1.7 (Planify) né sul fork privato paper-rs - da confermare prima del 17/09."
