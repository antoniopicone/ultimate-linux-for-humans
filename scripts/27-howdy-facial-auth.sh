#!/usr/bin/env bash
# 27-howdy-facial-auth.sh — installa Howdy (boltgolt/howdy): sblocco/
# autenticazione via riconoscimento facciale su PAM (login, lock screen,
# sudo, su), compilato da SORGENTE.
#
# Versione standalone dell'equivalente blocco in disk-setup/autoinstall.yaml.tpl
# per un sistema già installato — stessa logica, senza il contesto chroot.
#
# PERCHÉ DA SORGENTE E NON DALLA PPA UFFICIALE (ppa:boltgolt/howdy)
# -------------------------------------------------------------------------
# Al momento in cui questo script è stato scritto la PPA ufficiale non ha
# ancora una build per Ubuntu 26.04 (issue upstream boltgolt/howdy#1097,
# aperta da marzo 2026, mai risposta dal maintainer, solo "+1"/"+2" di altri
# utenti in attesa). Un utente ha riportato successo con una PPA di terzi
# non ufficiale ("panda jims"), scartata qui per non introdurre una fonte
# non verificabile nella ricetta.
#
# ATTENZIONE: la compilazione di dlib è lunga — l'upstream stesso avverte
# "can hang on 100% for over a minute, give it time". Questo script impiega
# diversi minuti.
#
# BUG NOTO, ANCORA APERTO UPSTREAM (issue boltgolt/howdy#1104, nessuna
# risposta del maintainer): su Ubuntu 26.04/GNOME 50 il modulo PAM di Howdy
# manda in stallo (poi in un dialog non più chiudibile) la richiesta di
# sblocco di Impostazioni -> Utenti, perché quella finestra passa dal
# servizio PAM "polkit-1", che erediterebbe comunque Howdy tramite
# l'inclusione di common-auth fatta da pam-auth-update. Fix applicato qui
# (tecnica standard PAM, vedi `man pam_succeed_if`, sezione ESEMPI, che
# mostra esattamente questo pattern "salta il modulo successivo per un dato
# service"): si inserisce nel frammento pam-configs una riga
# pam_succeed_if.so che, quando il service è "polkit-1", salta la riga di
# Howdy — login/lock screen/sudo restano protetti dal riconoscimento
# facciale, solo Impostazioni -> Utenti passa direttamente alla password.
# NON verificato su hardware reale in questa sessione (nessun vero
# polkit/gnome-control-center disponibile) — da confermare prima di
# fidarsene.
#
# Sicurezza: come da README upstream, "DO NOT USE HOWDY AS THE SOLE
# AUTHENTICATION METHOD FOR YOUR SYSTEM" — pam-auth-update lo inserisce con
# "[success=end default=ignore]", quindi volto non riconosciuto o webcam
# assente scendono comunque al metodo successivo (password), mai un blocco
# totale. La password resta sempre valida.
#
# L'enrollment del volto ("sudo howdy add") richiede una webcam reale e
# un'interazione visibile: va fatto da questo stesso script, in un
# terminale interattivo reale (non c'è bisogno del meccanismo autostart
# usato nella versione .tpl, perché qui NON giriamo in un chroot offline).
#
# Uso: ./27-howdy-facial-auth.sh

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user
apt_update_once

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

log_info "Installo le dipendenze di build di Howdy..."
sudo apt install -y \
    python3 python3-pip python3-setuptools python3-wheel \
    cmake make build-essential meson ninja-build git \
    libpam0g-dev libinih-dev libevdev-dev python3-opencv \
    python3-dev libopencv-dev

log_info "Clono howdy (boltgolt/howdy) in ${BUILD_DIR}..."
git clone --depth=1 https://github.com/boltgolt/howdy.git "${BUILD_DIR}/howdy"
cd "${BUILD_DIR}/howdy"

# BUG REALE trovato testando l'enrollment ("sudo howdy add" falliva con
# "No module named 'dlib'"): la build meson/ninja di Howdy compila ed
# installa SOLO il codice di Howdy stesso — verificato leggendo i
# meson.build upstream (root, howdy/, howdy/src/): nessuno di questi
# installa il modulo Python "dlib" che howdy/src/compare.py importa
# direttamente (riga "import dlib"). Non esiste nemmeno un pacchetto apt
# "python3-dlib" su Ubuntu (solo "libdlib-dev"/"libdlib19.1t64", la
# libreria C++, non i binding Python) — va installato via pip, ed è
# proprio QUESTA la build lunga di cui avverte il README upstream ("can
# hang on 100% for over a minute"), non la meson/ninja qui sotto.
log_info "Installo il modulo Python dlib via pip (build da sorgente lunga, come avvisato dal README di Howdy)..."
pip3 install --break-system-packages dlib

# -Dconfig_dir=/etc/howdy esplicito: il default di meson.build è
# "<prefix>/<sysconfdir>/howdy", e sysconfdir NON diventa /etc solo perché
# prefix=/usr (servirebbe anche --sysconfdir=/etc a parte, una nota gotcha
# di meson/GNU) — più sicuro fissarlo diretto.
# -Dpython_path=/usr/bin/python3: il default upstream è "/usr/bin/python",
# che su Ubuntu (Python 2 rimosso da anni) non esiste.
# -Dinstall_pam_config=true: di default false, è quello che installa il
# frammento /usr/share/pam-configs/howdy che pam-auth-update sa leggere.
log_info "Compilo Howdy (meson + ninja)..."
meson setup build --prefix=/usr \
    -Dconfig_dir=/etc/howdy \
    -Dpython_path=/usr/bin/python3 \
    -Dinstall_pam_config=true
meson compile -C build
log_info "Installo Howdy (richiede sudo)..."
sudo meson install -C build

log_info "Applico il workaround per il bug noto Impostazioni -> Utenti / polkit-1 (vedi header dello script)..."
if grep -q "pam_howdy\.so" /usr/share/pam-configs/howdy 2>/dev/null \
    && ! grep -q "service = polkit-1" /usr/share/pam-configs/howdy 2>/dev/null; then
    sudo sed -i \
        '/pam_howdy\.so/i\    [success=1 default=ignore]    pam_succeed_if.so quiet service = polkit-1' \
        /usr/share/pam-configs/howdy
    log_ok "Workaround applicato al frammento pam-configs."
else
    log_warn "Frammento pam-configs/howdy non trovato o già patchato: controllare manualmente se il problema persiste."
fi

log_info "Abilito il profilo PAM di Howdy (pam-auth-update)..."
sudo DEBIAN_FRONTEND=noninteractive pam-auth-update --enable howdy
log_ok "Howdy installato e abilitato per login/lock screen/sudo/su. Impostazioni -> Utenti resta escluso (vedi sopra)."

# --- Enrollment del volto --------------------------------------------------

echo
echo "Ora serve registrare il tuo volto. Guarda la webcam quando richiesto."
echo "Premi Ctrl+C in qualunque momento per saltare (potrai rieseguire 'sudo howdy add' più tardi)."
echo
if sudo howdy add; then
    log_ok "Volto registrato. Prova con 'sudo -i' in un nuovo terminale per vederlo in azione."
else
    log_warn "Registrazione saltata o fallita: rilancia 'sudo howdy add' quando vuoi."
fi

log_info "Configurazione completa: 'sudo howdy config' apre il file di configurazione, 'howdy list'/'howdy test' per verificare."
