#!/usr/bin/env bash
# 20-wayland-scroll-factor.sh — regola la velocità dello scroll verticale a
# due dita sul touchpad, tramite wsf (Wayland Scroll Factor).
#
# PERCHÉ SERVE: GNOME su Wayland non espone NESSUNA impostazione, né in
# Impostazioni né come chiave gsettings/dconf, per regolare la velocità
# dello scroll a due dita — a differenza del vecchio stack X11, dove
# bastava xinput. È una lacuna nota di GNOME/Wayland, non qualcosa che
# questa ricetta ha tralasciato di configurare.
#
# wsf (github.com/daniel-g-carrasco/wayland-scroll-factor) è il tool di
# terze parti più maturo trovato per colmare questa lacuna: GTK4,
# per-utente, reversibile, non tocca /etc/ld.so.preload (a differenza di
# alcuni fix "manuali" più vecchi che si trovano in giro). È distribuito
# solo come pacchetto .deb su GitHub Releases, in nessun repository apt
# ufficiale.
#
# Cosa fa questo script:
#   1. scarica e installa il pacchetto .deb dell'ultima release testata;
#   2. scrive ~/.config/wayland-scroll-factor/config con
#      scroll_vertical_factor=0.20 (default del tool: 0.35 — orizzontale e
#      pinch restano al default, scritti per esteso perché il formato non
#      è documentato a sufficienza da sapere se wsf tolleri chiavi
#      mancanti);
#   3. lancia "wsf enable" — per documentazione del progetto, il preload
#      dentro gnome-shell ha effetto dopo un logout/login, non a caldo:
#      lo ricordiamo esplicitamente alla fine.
#
# Uso: ./20-wayland-scroll-factor.sh

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user

WSF_VERSION="0.3.5"
WSF_DEB="wayland-scroll-factor_${WSF_VERSION}-1_amd64.deb"
WSF_URL="https://github.com/daniel-g-carrasco/wayland-scroll-factor/releases/download/v${WSF_VERSION}/${WSF_DEB}"

log_info "Scarico wsf v${WSF_VERSION}..."
TMP_DEB="$(mktemp --suffix=.deb)"
if ! curl -fsSL -o "${TMP_DEB}" "${WSF_URL}"; then
    log_err "Download fallito da: ${WSF_URL}"
    log_err "Controlla la connessione, oppure se il nome del pacchetto è cambiato su:"
    log_err "  https://github.com/daniel-g-carrasco/wayland-scroll-factor/releases"
    rm -f "${TMP_DEB}"
    exit 1
fi
sudo apt install -y "${TMP_DEB}"
rm -f "${TMP_DEB}"

log_info "Scrivo la configurazione (scroll verticale: 0.20)..."
mkdir -p "${HOME}/.config/wayland-scroll-factor"
cat > "${HOME}/.config/wayland-scroll-factor/config" <<'WSFCONFIGEOF'
scroll_vertical_factor=0.20
scroll_horizontal_factor=0.35
pinch_zoom_factor=1.00
pinch_rotate_factor=1.00
WSFCONFIGEOF

log_info "Attivo il preload (wsf enable)..."
wsf enable

log_ok "Fatto. Effettua il logout e login (o riavvia) perché il nuovo scroll factor abbia effetto."
