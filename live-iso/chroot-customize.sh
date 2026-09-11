#!/usr/bin/env bash
# chroot-customize.sh — gira DENTRO il chroot del filesystem live estratto
# da build-live-remix.sh (chroot <rootfs> /bin/bash /chroot-customize.sh).
# Non lanciarlo fuori da un chroot: modifica /etc, installa pacchetti, ecc.
# assumendo che "/" sia il filesystem live da modificare.
#
# Cosa NON c'è qui (e perché): tutto ciò che dipende da un utente/disco
# specifico non ha senso in un filesystem live generico, condiviso da
# chiunque lo avvii — resta solo nell'autoinstall (disk-setup/autoinstall.
# yaml.tpl), che gira DOPO che un utente e un layout disco concreti
# esistono:
#   - layout BTRFS su LUKS2, subvolume, snapper root/home: sono per forza
#     legati al disco di UNA installazione reale, non al filesystem live.
#   - usbguard-notifier (si compila/installa nella home di un utente
#     specifico) e il mascheramento di gsd-usb-protection (stessa cosa):
#     qui non c'è ancora nessun utente reale su cui agire.
#   - il socket utente di podman (systemd --user "wants" nella home
#     dell'utente): stesso motivo.
#
# Le impostazioni GNOME (terminale, touchpad, estensioni) invece SONO
# incluse, ma scritte come default DI SISTEMA via
# /etc/dconf/db/local.d + `dconf update` invece che per un utente preciso
# via dbus-run-session: questo meccanismo si applica automaticamente a
# QUALUNQUE utente (quello della sessione live compreso, chiunque sia) e
# sopravvive anche a un'installazione reale successiva — è il modo
# standard e documentato per impostare default GNOME a livello di intero
# sistema, non un trucco specifico di questo script. Stesso discorso per
# le 8 estensioni GNOME Shell: invece di `gnome-extensions install` (che
# scrive nella home di un utente specifico), vanno in
# /usr/share/gnome-shell/extensions/ — il percorso documentato da GNOME
# per estensioni valide per ogni utente ("Enable machine-wide extensions",
# help.gnome.org).

set -eux
export DEBIAN_FRONTEND=noninteractive

# Le immagini live di Ubuntu includono spesso una riga "deb cdrom:..." tra
# le fonti apt, che punta all'ISO stessa come repository (utile a bordo,
# inutile qui): dentro questo chroot non c'è nessuna ISO montata su
# /cdrom, quindi quella riga da sola farebbe fallire TUTTO "apt-get
# update" (apt considera un repository non raggiungibile un errore fatale,
# non un semplice avviso). La disabilitiamo prima di aggiornare gli
# indici: ci servono solo i mirror di rete, già presenti nelle stesse
# fonti insieme a quella riga.
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "${f}" ] && sed -i '/cdrom:/ s/^/# /' "${f}"
done
for f in /etc/apt/sources.list.d/*.sources; do
    [ -f "${f}" ] || continue
    grep -qi 'cdrom' "${f}" && mv "${f}" "${f}.disabled-cdrom"
done

apt-get update

# --- Ghostty + integrazione Nautilus -----------------------------------
apt-get install -y ghostty
update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator /usr/bin/ghostty 50
update-alternatives --set x-terminal-emulator /usr/bin/ghostty
apt-get install -y python3-nautilus

# --- Brave ---------------------------------------------------------------
apt-get install -y curl
curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources https://brave-browser-apt-release.s3.brave.com/brave-browser.sources
apt-get update
apt-get install -y brave-browser

# --- Gestore estensioni GNOME Shell ---------------------------------------
apt-get install -y gnome-shell-extension-manager

# --- Le 8 estensioni GNOME Shell della ricetta principale -----------------
# Stessa identica lista/logica di disk-setup/autoinstall.yaml.tpl (download
# da extensions.gnome.org, build compatibile con la versione di GNOME Shell
# effettiva, salta senza fallire quelle senza build disponibile), ma
# installate a livello di SISTEMA invece che nella home di un utente
# specifico: `gnome-extensions install` (usato nella ricetta principale)
# scrive in ~/.local/share/gnome-shell/extensions/, che qui non ha senso
# (nessun utente concreto). /usr/share/gnome-shell/extensions/ è il
# percorso documentato da GNOME stesso per estensioni valide per
# QUALUNQUE utente ("Enable machine-wide extensions", help.gnome.org) —
# stessa filosofia già usata per terminale/touchpad via dconf di sistema.
apt-get install -y python3 unzip

GNOME_SHELL_VERSION="$(gnome-shell --version | grep -oP '[0-9]+\.[0-9]+' | head -1)"

EXTENSION_UUIDS=(
    "display-color-correct@antoniopicone.it"
    "Rounded_Corners@lennart-k"
    "kiwi@kemma"
    "kiwimenu@kemma"
    "caffeine@patapon.info"
    "Vitals@CoreCoding.com"
    "auto-theme-switcher@amritashan.github.io"
    "tailscale-gnome@diskmth.fr"
)

INSTALLED_UUIDS=()
for uuid in "${EXTENSION_UUIDS[@]}"; do
    info_json="$(curl -fsSL "https://extensions.gnome.org/extension-info/?uuid=${uuid}&shell_version=${GNOME_SHELL_VERSION}" || true)"
    download_path="$(printf '%s' "${info_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("download_url",""))' 2>/dev/null || true)"
    if [[ -z "${download_path}" ]]; then
        echo "ATTENZIONE: nessuna build di ${uuid} compatibile con GNOME Shell ${GNOME_SHELL_VERSION}, salto." >&2
        continue
    fi
    zip_path="/tmp/${uuid}.zip"
    ext_dir="/usr/share/gnome-shell/extensions/${uuid}"
    if curl -fsSL "https://extensions.gnome.org${download_path}" -o "${zip_path}"; then
        rm -rf "${ext_dir}"
        mkdir -p "${ext_dir}"
        if unzip -q -o "${zip_path}" -d "${ext_dir}"; then
            # Se porta schemi gsettings propri vanno compilati perché GNOME
            # Shell li trovi: idempotente, rifarlo non fa danni anche se lo
            # zip li avesse già compilati da solo.
            [[ -d "${ext_dir}/schemas" ]] && glib-compile-schemas "${ext_dir}/schemas" 2>/dev/null
            chown -R root:root "${ext_dir}"
            INSTALLED_UUIDS+=("${uuid}")
        else
            echo "ATTENZIONE: estrazione fallita per ${uuid}, salto." >&2
            rm -rf "${ext_dir}"
        fi
    else
        echo "ATTENZIONE: download fallito per ${uuid}, salto." >&2
    fi
    rm -f "${zip_path}"
done

# --- zram ------------------------------------------------------------------
apt-get install -y systemd-zram-generator
mkdir -p /etc/systemd
cat > /etc/systemd/zram-generator.conf <<'ZRAMEOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAMEOF

# --- Utility da riga di comando --------------------------------------------
apt-get install -y vim wget htop avahi-daemon git lm-sensors gnome-sushi

# --- Font: "stile Windows/Office" + a larghezza fissa per il terminale -----
# Stessa identica logica di disk-setup/autoinstall.yaml.tpl (vedi i commenti
# lì per il perché di ogni scelta): font "core" Microsoft via
# ttf-mscorefonts-installer (EULA storica, accettata non interattivamente),
# Carlito/Caladea come sostituti liberi metric-compatible di Calibri/Cambria
# (non coperte da quella EULA), JetBrains Mono da apt, Hack Nerd Font dalla
# release ufficiale del progetto. SF Pro (macOS) resta fuori per lo stesso
# motivo di licenza Apple, vedi scripts/14-install-fonts.sh.
echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y ttf-mscorefonts-installer
apt-get install -y fonts-crosextra-carlito fonts-crosextra-caladea fonts-jetbrains-mono unzip
curl -fsSL -o /tmp/HackNerdFont.zip "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Hack.zip"
mkdir -p /usr/local/share/fonts/HackNerdFont
unzip -oq /tmp/HackNerdFont.zip -d /usr/local/share/fonts/HackNerdFont '*.ttf'
rm -f /tmp/HackNerdFont.zip
fc-cache -f >/dev/null

# --- OnlyOffice al posto di LibreOffice --------------------------------
# Stessa identica logica di disk-setup/autoinstall.yaml.tpl (vedi i
# commenti lì per il dettaglio): rimuove LibreOffice solo se davvero
# presente, installa ONLYOFFICE dal repository apt ufficiale solo se non
# c'è già, crea 3 .desktop per aprire direttamente un documento/foglio/
# presentazione vuoti.
LIBREOFFICE_PKGS="$(dpkg-query -W -f='${Package}\n' 'libreoffice*' 2>/dev/null || true)"
if [[ -n "${LIBREOFFICE_PKGS}" ]]; then
    apt-get purge -y ${LIBREOFFICE_PKGS}
    apt-get autoremove -y
else
    echo "LibreOffice non risulta installato, salto la rimozione." >&2
fi

if dpkg -s onlyoffice-desktopeditors >/dev/null 2>&1; then
    echo "onlyoffice-desktopeditors già installato, salto." >&2
else
    apt-get install -y gnupg dirmngr
    mkdir -p -m 700 /root/.gnupg
    gpg --no-default-keyring --keyring gnupg-ring:/tmp/onlyoffice.gpg \
        --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys CB2DE8E5
    # "gpg --recv-keys" avvia dirmngr come demone in background (per le
    # richieste di rete al keyserver) che altrimenti resta in esecuzione
    # per tutta la vita del chroot, con file descriptor aperti dentro
    # /dev (es. /dev/pts, /dev/urandom) — questo impedisce il successivo
    # "umount" di /dev con "target is busy" (errore reale riscontrato).
    # Lo terminiamo esplicitamente appena non serve più.
    gpgconf --kill dirmngr 2>/dev/null || true
    chmod 644 /tmp/onlyoffice.gpg
    mv /tmp/onlyoffice.gpg /usr/share/keyrings/onlyoffice.gpg
    echo 'deb [signed-by=/usr/share/keyrings/onlyoffice.gpg] https://download.onlyoffice.com/repo/debian squeeze main' \
        > /etc/apt/sources.list.d/onlyoffice.list
    apt-get update
    apt-get install -y onlyoffice-desktopeditors
fi

cat > /usr/share/applications/onlyoffice-new-document.desktop <<'DESKTOPEOF'
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

cat > /usr/share/applications/onlyoffice-new-spreadsheet.desktop <<'DESKTOPEOF'
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

cat > /usr/share/applications/onlyoffice-new-presentation.desktop <<'DESKTOPEOF'
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

chmod 644 /usr/share/applications/onlyoffice-new-*.desktop
update-desktop-database /usr/share/applications >/dev/null 2>&1 || true

# --- Supporto APFS (SOLA LETTURA) via apfs-fuse -----------------------------
# Stessa identica logica di disk-setup/autoinstall.yaml.tpl (vedi i commenti
# lì per il dettaglio: nessun pacchetto apt, compilato da sorgente, sola
# lettura per scelta upstream, niente supporto in scrittura per via del
# problema Secure Boot/MOK di linux-apfs-rw).
apt-get install -y fuse3 libfuse3-dev bzip2 libbz2-dev cmake g++ libattr1-dev zlib1g-dev git

git clone https://github.com/sgan81/apfs-fuse.git /tmp/apfs-fuse
(cd /tmp/apfs-fuse && git submodule init && git submodule update)
# ApfsLib/PList.h usa uint8_t/uint32_t senza includere <cstdint>: con GCC
# 15 (Ubuntu 26.04) non arriva più per inclusione transitiva da <memory>,
# la compilazione fallisce con "'uint8_t' does not name a type" (errore
# reale riscontrato in VM).
sed -i '1i #include <cstdint>' /tmp/apfs-fuse/ApfsLib/PList.h
mkdir -p /tmp/apfs-fuse/build
(cd /tmp/apfs-fuse/build && cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && make -j"$(nproc)" && make install)
rm -rf /tmp/apfs-fuse

# Integrazione con Nautilus/udisks2: senza questo, Nautilus riconosce la
# partizione APFS (via blkid) ma prova ad automontarla con "mount -t
# apfs", che fallisce (nessun driver APFS nel kernel — errore reale
# riscontrato in VM). Stesso meccanismo con cui ntfs-3g/exfat-fuse si
# integrano con mount(8): un helper esterno "/sbin/mount.apfs" (sintassi
# imposta da mount(8), man mount sezione "EXTERNAL HELPERS") che mount
# esegue al posto del driver kernel inesistente.
cat > /sbin/mount.apfs <<'MOUNTAPFSEOF'
#!/bin/bash
set -euo pipefail
SPEC="$1"
DIR="$2"
shift 2
OPTS=""
while getopts ":sfnvN:o:t:" opt; do
    case "$opt" in
        o) OPTS="$OPTARG" ;;
        *) ;;
    esac
done

# udisks2 passa a questo helper TUTTE le opzioni di mount, incluse quelle
# specifiche sue (es. "uhelper=udisks2") o generiche del VFS
# (nodev/nosuid/noexec/relatime/...) senza sapere che la destinazione è
# un filesystem FUSE: libfuse (usata da apfs-fuse) rifiuta con "fuse:
# unknown option(s)" qualsiasi opzione che non riconosce — errore reale
# riscontrato in VM ("fuse: unknown option(s): `-o uhelper=udisks2'").
# Filtriamo quindi le opzioni, passando a apfs-fuse solo quelle che
# libfuse/apfs-fuse capiscono e scartando silenziosamente il resto.
#
# "allow_other" è FORZATA sempre, indipendentemente da cosa passa
# udisks2: udisks2 monta sempre come root (demone privilegiato), e un
# filesystem FUSE montato da root è visibile di default solo a root —
# senza "allow_other" l'utente normale ottiene "permessi non
# sufficienti" aprendo il disco da Nautilus (errore reale riscontrato).
# apfs non è tra i filesystem "noti" a udisks2 (a differenza di
# NTFS/exFAT), quindi udisks2 non aggiunge da solo le opzioni giuste —
# le forziamo qui. Nessuna modifica a /etc/fuse.conf necessaria:
# "allow_other" è sempre permesso quando chi monta è root (la
# restrizione "user_allow_other" riguarda solo mount fatti da utenti
# non privilegiati).
FILTERED="allow_other"
IFS=',' read -ra OPT_ARR <<< "${OPTS}"
for o in "${OPT_ARR[@]}"; do
    case "$o" in
        ro|rw|uid=*|gid=*|nonempty)
            FILTERED="${FILTERED},${o}"
            ;;
        *) ;;
    esac
done

exec /usr/local/bin/apfs-fuse -o "${FILTERED}" "${SPEC}" "${DIR}"
MOUNTAPFSEOF
chmod 755 /sbin/mount.apfs

# --- Tailscale (solo il pacchetto, niente attivazione) ---------------------
# Script di installazione ufficiale, non interattivo di suo. Qui installiamo
# SOLO il pacchetto: "tailscale up" richiede una auth key legata a UNA
# macchina precisa (vedi disk-setup/autoinstall.yaml.tpl), che non ha senso
# incorporare in un'immagine live generica/condivisa — chi installa da
# questa ISO la attiva tramite l'autoinstall completo (se l'ha fornita a
# prepare-autoinstall.sh) o a mano con "sudo tailscale up".
curl -fsSL https://tailscale.com/install.sh | sh

# --- USBGuard (solo il pacchetto + policy generica) -----------------------
# Niente notificatore/regole specifiche per un utente qui (vedi commento in
# testa al file): solo il demone con la policy di default del pacchetto,
# che chi installa da questa ISO può poi affinare a mano o tramite
# l'autoinstall completo.
apt-get install -y usbguard

# --- Podman (rootless) + wrapper Docker + "docker compose" reale ----------
# Stessa identica logica (e stessa trappola apt da evitare) della ricetta
# autoinstall: vedi disk-setup/autoinstall.yaml.tpl per i dettagli completi.
apt-get install -y podman podman-docker
apt-get install -y --no-install-recommends docker-compose-v2

mkdir -p /etc/containers
touch /etc/containers/nodocker

mkdir -p /etc/containers/registries.conf.d
cat > /etc/containers/registries.conf.d/10-unqualified-search.conf <<'REGISTRIESEOF'
unqualified-search-registries = ["docker.io"]
REGISTRIESEOF

# --- zsh + Oh My Zsh -------------------------------------------------------
# Qui installiamo solo il pacchetto e prepariamo /etc/skel, così qualunque
# utente creato in futuro su un sistema partito da questa ISO (live o
# installato) lo trova già pronto. NON impostiamo una shell di default per
# un utente specifico (non ce n'è uno concreto in questo contesto): lo fa
# l'autoinstall per l'utente vero creato da Subiquity.
apt-get install -y zsh
ZSH_BIN="$(command -v zsh)"
grep -qxF "${ZSH_BIN}" /etc/shells || echo "${ZSH_BIN}" >> /etc/shells

# Installiamo Oh My Zsh dentro /etc/skel, non in una home che non esiste
# ancora: HOME=/etc/skel fa sì che l'installer ci scriva .oh-my-zsh e
# .zshrc direttamente lì, così ogni nuova home creata in futuro (copiando
# da /etc/skel, comportamento standard di useradd/adduser) li eredita già
# pronti. NON TESTATO end-to-end (vedi README): verificare che un utente
# creato dopo il boot trovi davvero Oh My Zsh funzionante.
HOME=/etc/skel RUNZSH=no CHSH=no OVERWRITE_CONFIRMATION=no \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
    || echo "ATTENZIONE: installazione di Oh My Zsh in /etc/skel fallita, controllare a mano." >&2

# Tema Pure per zsh, sempre in /etc/skel e sempre DOPO l'installer di Oh My
# Zsh sopra (stesso motivo dell'autoinstall: quest'ultimo sovrascrive
# .zshrc da zero).
mkdir -p /etc/skel/.zsh
git clone --depth=1 https://github.com/sindresorhus/pure.git /etc/skel/.zsh/pure \
    || echo "ATTENZIONE: clone del tema Pure in /etc/skel fallito, controllare a mano." >&2
cat >> /etc/skel/.zshrc <<'PUREEOF'

# Tema Pure (https://github.com/sindresorhus/pure)
fpath+=($HOME/.zsh/pure)
autoload -U promptinit; promptinit
prompt pure
PUREEOF

chown -R root:root /etc/skel

# --- Rimozione Firefox (snap) ----------------------------------------------
# Stesso motivo dell'autoinstall: "snap remove" parla con snapd, che qui
# dentro il chroot non gira (nessun init reale) — rimandiamo a un servizio
# systemd oneshot che si esegue al primo avvio VERO di qualunque sistema
# basato su questa ISO (sessione live inclusa: anche lei "fa un boot").
# Si autodisabilita dopo essere girato una volta.
cat > /etc/systemd/system/ubuntu-ultimate-firstboot.service <<'UNITEOF'
[Unit]
Description=Ubuntu Ultimate (live) - rimozione Firefox al primo avvio
After=snapd.service network-online.target
Wants=snapd.service network-online.target
ConditionPathExists=!/var/lib/ubuntu-ultimate/firstboot-done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ubuntu-ultimate-firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNITEOF

cat > /usr/local/sbin/ubuntu-ultimate-firstboot.sh <<'SCRIPTEOF'
#!/bin/bash
set -eux

snap wait system seed.loaded || true

if snap list firefox >/dev/null 2>&1; then
    snap remove --purge firefox
fi
if dpkg -s firefox >/dev/null 2>&1; then
    apt-get purge -y firefox
fi
apt-mark hold firefox || true

mkdir -p /var/lib/ubuntu-ultimate
touch /var/lib/ubuntu-ultimate/firstboot-done
systemctl disable ubuntu-ultimate-firstboot.service
SCRIPTEOF
chmod +x /usr/local/sbin/ubuntu-ultimate-firstboot.sh

mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/ubuntu-ultimate-firstboot.service \
    /etc/systemd/system/multi-user.target.wants/ubuntu-ultimate-firstboot.service

# --- Impostazioni GNOME di sistema (dconf) --------------------------------
# /etc/dconf/db/local.d è il meccanismo STANDARD per default GNOME validi
# per ogni utente del sistema (vedi `man dconf`), senza bisogno di una
# sessione D-Bus o di un utente concreto: perfetto per un filesystem live.
#
# ATTENZIONE (verificato, non ovvio): senza /etc/dconf/profile/user, dconf
# usa un profilo interno "hard-wired" che legge SOLO user-db:user — NESSUN
# database di sistema, "local" incluso. Ubuntu non spedisce questo file di
# default. Senza crearlo esplicitamente, tutto quello che scriviamo sotto
# in local.d verrebbe compilato dentro il db ma non letto MAI da nessuna
# sessione utente: il file profilo è indispensabile, non solo la keyfile.
mkdir -p /etc/dconf/profile
cat > /etc/dconf/profile/user <<'DCONFPROFILEEOF'
user-db:user
system-db:local
DCONFPROFILEEOF

mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-ubuntu-ultimate <<'DCONFEOF'
[org/gnome/desktop/default-applications/terminal]
exec='ghostty'
exec-arg='-e'

[org/gnome/desktop/applications/terminal]
exec='ghostty'
exec-arg='-e'

[org/gnome/desktop/peripherals/touchpad]
click-method='fingers'
tap-to-click=true
DCONFEOF

# Impedisce agli utenti di sovrascrivere questi default per errore da
# gsettings (non li BLOCCA per sempre: è comunque una scelta reversibile
# rimuovendo la entry da questo file di lock, non un vincolo del sistema).
mkdir -p /etc/dconf/db/local.d/locks
cat > /etc/dconf/db/local.d/locks/00-ubuntu-ultimate <<'LOCKSEOF'
LOCKSEOF
# (lock file vuoto apposta: preferiamo dei default sensati ma modificabili
# liberamente dall'utente, non delle policy imposte — coerente con lo
# spirito del resto della ricetta)

# Estensioni abilitate di default + le loro impostazioni: stesso dump di
# badrobot già usato in disk-setup/autoinstall.yaml.tpl (per coerenza
# visiva con l'installazione completa), file separato per non appesantire
# quello di terminale/touchpad. Alcuni valori sono legati all'hardware di
# badrobot (connettore monitor 'eDP-1', sensore ventola
# 'sensor:_fan_asus_cpu_fan_'): su hardware diverso semplicemente non
# trovano riscontro o vengono sovrascritti dall'estensione stessa, senza
# causare errori — stessa nota già presente nel README principale.
if [[ ${#INSTALLED_UUIDS[@]} -gt 0 ]]; then
    ENABLED_GVARIANT="["
    for u in "${INSTALLED_UUIDS[@]}"; do
        ENABLED_GVARIANT+="'${u}', "
    done
    ENABLED_GVARIANT="${ENABLED_GVARIANT%, }]"

    # Riga con variabile: heredoc NON tra apici, va scritta da sola.
    cat > /etc/dconf/db/local.d/01-gnome-extensions <<DCONFEXTHDR
[org/gnome/shell]
enabled-extensions=${ENABLED_GVARIANT}
DCONFEXTHDR

    # Resto tutto letterale: heredoc tra apici, zero rischio di
    # interpolazione accidentale (i valori contengono $, ', ", { }).
    cat >> /etc/dconf/db/local.d/01-gnome-extensions <<'DCONFEXTEOF'
[org/gnome/shell/extensions/auto-theme-switcher]
dark-theme='adw-gtk3-dark'
data-version=1
light-theme='Adwaita'
location-name='Napoli, Campania, Italia'
manual-latitude='40.8522'
manual-longitude='14.2681'
manual-mode-active=true
manual-mode-is-dark=false
migration-notification-pending=''
monitors='[{"id":"builtin","name":"Built-in Display","type":"brightnessctl","enabled":false,"initialized":true,"lightBrightness":48,"darkBrightness":48,"increaseDuration":7200,"decreaseDuration":7200,"lastSeen":1787815961872}]'
monitors-last-detection=int64 1787815961873
night-light-mode='sync-with-theme'
show-notifications=false

[org/gnome/shell/extensions/caffeine]
cli-toggle=false
indicator-position-max=2
user-enabled=true

[org/gnome/shell/extensions/dash-to-dock]
apply-custom-theme=false
background-color='rgb(24,12,12)'
background-opacity=0.46000000000000002
custom-background-color=true
custom-theme-shrink=true
dash-max-icon-size=48
disable-overview-on-startup=true
dock-fixed=false
dock-position='BOTTOM'
extend-height=false
height-fraction=0.90000000000000002
multi-monitor=true
preferred-monitor=-2
preferred-monitor-by-connector='eDP-1'
running-indicator-style='DOT'
show-apps-always-in-the-edge=true
show-show-apps-button=false
transparency-mode='FIXED'

[org/gnome/shell/extensions/display-color-correct]
blue-saturation=0.93000000000000005
green-saturation=0.90000000000000002
monitor-overrides='{"eDP-1":{"rSat":0.73,"gSat":0.9,"bSat":0.93},"DP-1":{"b":1,"rSat":1,"gSat":1,"bSat":1}}'
per-monitor-enabled=true
red-saturation=0.72999999999999998

[org/gnome/shell/extensions/kiwi]
add-username-to-quick-menu=false
dock-blur=false
enable-app-window-buttons=false
enable-launchpad-app=false
hide-activities-button=true
keyboard-indicator=false
lock-icon=false
move-window-to-new-workspace=false
overview-wallpaper-background=false
panel-blur=false
panel-color-inherit=true
panel-hover-fullscreen=true
panel-transparency=true
panel-transparency-level=75
show-window-controls=false
show-window-title=false
transparent-move=false

[org/gnome/shell/extensions/ding]
check-x11wayland=true
show-home=false

[org/gnome/shell/extensions/kiwimenu]
activity-menu-visibility=false
custom-menu-enabled=false
icon=8

[org/gnome/shell/extensions/lennart-k/rounded_corners]
corner-radius=6

[org/gnome/shell/extensions/vitals]
alphabetize=false
battery-colors=@as []
fan-colors=['2500 0.8784313797950745 0.10588235408067703 0.1411764770746231 sensor:_fan_asus_cpu_fan_']
fixed-widths=false
gpu-colors=@as []
hot-sensors=['__temperature_avg__']
icon-style=1
memory-colors=@as []
network-public-ip-show-flag=false
network-speed-unit=2
processor-colors=@as []
show-memory=true
use-higher-precision=true
DCONFEXTEOF
else
    echo "ATTENZIONE: nessuna estensione GNOME Shell installata con successo, salto le impostazioni dedicate." >&2
fi

dconf update

echo "chroot-customize.sh completato."
