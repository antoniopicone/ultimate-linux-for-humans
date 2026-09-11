#!/usr/bin/env bash
# build-live-remix.sh — respin della ISO ufficiale di Ubuntu 26.04 Desktop:
# estrae i layer del filesystem live (casper/minimal*.squashfs — NON un
# unico filesystem.squashfs, vedi sotto), li personalizza in chroot con
# chroot-customize.sh, li ricompatta e ricostruisce una ISO avviabile
# identica nel meccanismo di boot (BIOS+UEFI) all'originale.
#
# Layout del filesystem live (Ubuntu 24.04+, verificato leggendo i sorgenti
# ufficiali di casper e livecd-rootfs, non per tentativi — il primo tentativo
# assumeva ancora il vecchio schema mono-squashfs delle release precedenti
# e falliva con "non trovo casper/filesystem.squashfs"): il filesystem live
# è a più layer sovrapposti in overlayfs, minimal.squashfs (base) ->
# minimal.standard.squashfs (desktop completo) -> minimal.standard.live.
# squashfs (solo extra di sessione live, es. casper/ubiquity), più varianti
# per lingua/secure-boot non usate dal boot di default. Le nostre modifiche
# finiscono SOLO in minimal.standard.squashfs (il layer "sistema completo"),
# montando tutti e 3 in overlay durante la personalizzazione per avere una
# vista apt/dpkg coerente (stessa vista che ha il sistema da avviato).
#
# NON ANCORA TESTATO END-TO-END SU UNA ISO REALE (vedi README.md in questa
# stessa cartella): la logica di estrazione/modifica/ricostruzione ISO
# (xorriso/squashfs/overlayfs) è stata validata con un mini filesystem/ISO
# sintetici (stesso identico meccanismo, scala ridotta — il meccanismo a
# 3 layer overlay invece è stato solo ragionato sui sorgenti ufficiali, non
# ancora eseguito nemmeno in miniatura), ma il download+unsquash+resquash
# di una ISO Ubuntu reale (~6GB, filesystem live decompresso da svariati
# GB) non è mai stato eseguito qui. Prima di fidartene per la demo, testalo
# su una macchina con spazio disco abbondante (servono almeno 20-25GB
# liberi) e tempo (probabilmente 20-40 minuti).
#
# In più, se trova un autoinstall.yaml già generato (da
# disk-setup/prepare-autoinstall.sh), lo incorpora DENTRO la stessa ISO
# come datasource NoCloud locale (cartella /nocloud/ alla radice della ISO
# + parametro "autoinstall ds=nocloud;s=/cdrom/nocloud/" in grub.cfg) —
# verificato su fonti/community che documentano questo esatto pattern per
# Ubuntu Desktop/Server (nessuna seconda chiavetta seed necessaria). NON
# forza l'installazione al boot: la sessione live parte normale e
# navigabile come sempre, l'automazione parte SOLO se poi scegli
# "Install Ubuntu" dal desktop live.
#
# ATTENZIONE SICUREZZA: se incorpori l'autoinstall, la passphrase LUKS2 e
# l'hash della password utente finiscono IN CHIARO dentro
# /nocloud/user-data sulla ISO risultante — chiunque abbia il file
# ubuntu-ultimate-live-*.iso (o la chiavetta) può leggerli semplicemente
# montando la ISO, ISO9660 non ha permessi per-file significativi. Tratta
# quella ISO come un segreto esattamente come già fai con
# disk-setup/autoinstall.yaml: non condividerla, cancellala quando hai
# finito i test/la demo.
#
# Uso: sudo ./build-live-remix.sh [percorso/alla/ubuntu-26.04.1-desktop-amd64.iso] [percorso/ad/autoinstall.yaml]
#      (senza argomenti: ISO riusata/scaricata da ../test-vm/isos/ come
#      create-test-vm.sh, autoinstall.yaml riusato da ../disk-setup/ se
#      presente — se manca, costruisce comunque la ISO live "solo browsable",
#      senza autoinstall incorporato)
#
# Richiede: root (per chroot, mount --bind, mount -t overlay,
# unsquashfs/mksquashfs di un filesystem con permessi/dispositivi reali),
# xorriso, squashfs-tools, supporto overlayfs nel kernel (di serie su
# qualunque kernel Linux recente, incluso quello di badrobot).

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

if [[ "${EUID}" -ne 0 ]]; then
    log_err "Lancialo con sudo: servono chroot, mount --bind e unsquashfs/mksquashfs con permessi reali."
    exit 1
fi

for cmd in xorriso unsquashfs mksquashfs; do
    command -v "${cmd}" >/dev/null 2>&1 || {
        log_info "Installo squashfs-tools/xorriso (mancava: ${cmd})..."
        apt-get update -qq && apt-get install -y xorriso squashfs-tools
        break
    }
done

# --- 0. ISO sorgente --------------------------------------------------------
ISO_VERSION="26.04.1"
ISO_NAME="ubuntu-${ISO_VERSION}-desktop-amd64.iso"
DEFAULT_ISO_PATH="${SCRIPT_DIR}/../test-vm/isos/${ISO_NAME}"
SOURCE_ISO="${1:-${DEFAULT_ISO_PATH}}"

if [[ ! -f "${SOURCE_ISO}" ]]; then
    log_info "${SOURCE_ISO} non trovata, la scarico (stesso meccanismo di test-vm/create-test-vm.sh)..."
    mkdir -p "$(dirname -- "${SOURCE_ISO}")"
    DEFAULT_ISO_MIRRORS=(
        "https://ubuntu.mirror.garr.it/ubuntu-releases"
        "https://mirror.init7.net/ubuntu-releases"
        "https://ftp.halifax.rwth-aachen.de/ubuntu-releases"
        "https://mirrors.xtom.de/ubuntu-releases"
        "https://www.mirrorservice.org/sites/releases.ubuntu.com"
        "https://releases.ubuntu.com"
    )
    ISO_MIRROR="$(pick_fastest_mirror "26.04/${ISO_NAME}" "${DEFAULT_ISO_MIRRORS[@]}")" \
        || ISO_MIRROR="${DEFAULT_ISO_MIRRORS[0]}"
    download_with_progress "${ISO_MIRROR%/}/26.04/${ISO_NAME}" \
        "$(dirname -- "${SOURCE_ISO}")" "$(basename -- "${SOURCE_ISO}")" "${SOURCE_ISO}"
fi
log_ok "Uso come sorgente: ${SOURCE_ISO}"

# --- 0bis. autoinstall.yaml da incorporare (opzionale) ----------------------
DEFAULT_AUTOINSTALL_FILE="${SCRIPT_DIR}/../disk-setup/autoinstall.yaml"
AUTOINSTALL_FILE="${2:-${DEFAULT_AUTOINSTALL_FILE}}"
EMBED_AUTOINSTALL=0
if [[ -f "${AUTOINSTALL_FILE}" ]]; then
    # Stesso controllo di test-vm/create-test-vm.sh: rifiuta un template
    # non ancora compilato da prepare-autoinstall.sh (conterrebbe i
    # segnaposto __...__ invece di valori veri, installazione che si
    # bloccherebbe a metà).
    if grep -qE '__(HOSTNAME|USERNAME|USER_PASSWORD_HASH|LUKS_PASSPHRASE|TAILSCALE_AUTHKEY)__' "${AUTOINSTALL_FILE}"; then
        log_warn "${AUTOINSTALL_FILE} contiene ancora segnaposto non sostituiti (non generato da prepare-autoinstall.sh): NON lo incorporo. La ISO sarà solo per navigare, senza autoinstall."
    else
        EMBED_AUTOINSTALL=1
        log_ok "Incorporo l'autoinstall da ${AUTOINSTALL_FILE}: questa ISO potrà anche installare in automatico, non solo farti provare la sessione live."
    fi
else
    log_warn "Nessun autoinstall.yaml trovato (${AUTOINSTALL_FILE}): costruisco solo la ISO live navigabile, senza autoinstall incorporato."
fi

# --- 1. Aree di lavoro ------------------------------------------------------
WORK_DIR="$(mktemp -d /var/tmp/ubuntu-ultimate-live-remix.XXXXXX)"
EXTRACT_DIR="${WORK_DIR}/extracted"
# I 3 layer del filesystem live vanno decompressi ciascuno per conto suo
# (sono squashfs distinti), poi montati insieme in overlay per avere, dentro
# il chroot, la stessa identica vista che ha il sistema quando è avviato
# davvero: dpkg/apt devono vedere TUTTI i pacchetti già "installati" nei
# layer precedenti, non solo quelli del layer che poi modifichiamo.
BASE_DIR="${WORK_DIR}/layer-base"          # minimal.squashfs, sola lettura
STANDARD_DIR="${WORK_DIR}/layer-standard"  # minimal.standard.squashfs, quello che modifichiamo
LIVE_DIR="${WORK_DIR}/layer-live"          # minimal.standard.live.squashfs, sola lettura
OVERLAY_DELTA="${WORK_DIR}/overlay-delta"  # cattura SOLO ciò che cambiamo noi
OVERLAY_WORK="${WORK_DIR}/overlay-work"    # richiesto da overlayfs, area interna
CHROOT_DIR="${WORK_DIR}/chroot-merged"     # vista unita, è qui che giriamo chroot-customize.sh
OUT_ISO="${SCRIPT_DIR}/ubuntu-ultimate-live-$(date +%Y%m%d).iso"

# Alcuni comandi lanciati dentro il chroot (es. "gpg --recv-keys" per la
# chiave apt di ONLYOFFICE) avviano demoni in background (dirmngr,
# gpg-agent) che restano in esecuzione anche a chroot-customize.sh già
# terminato, con file descriptor aperti dentro /dev (es. /dev/pts,
# /dev/urandom) o cwd dentro il chroot — questo fa fallire "umount" con
# "target is busy" (errore reale riscontrato in VM). Prima di smontare,
# terminiamo qualsiasi processo il cui root risulti essere il chroot:
# più robusto che elencare a mano ogni demone che un pacchetto potrebbe
# avviare durante l'installazione.
kill_chroot_processes() {
    local chroot_real
    chroot_real="$(readlink -f "${CHROOT_DIR}" 2>/dev/null || true)"
    [[ -z "${chroot_real}" ]] && return 0
    local pid root_real
    for p in /proc/[0-9]*; do
        pid="$(basename "$p")"
        root_real="$(readlink -f "${p}/root" 2>/dev/null || true)"
        if [[ -n "${root_real}" && "${root_real}" == "${chroot_real}" ]]; then
            kill -9 "${pid}" 2>/dev/null || true
        fi
    done
}

cleanup() {
    log_info "Pulizia (smonto eventuali mount rimasti, cancello ${WORK_DIR})..."
    kill_chroot_processes
    for m in dev/pts dev proc sys run; do
        mountpoint -q "${CHROOT_DIR}/${m}" 2>/dev/null && umount -R "${CHROOT_DIR}/${m}" || true
    done
    mountpoint -q "${CHROOT_DIR}" 2>/dev/null && umount "${CHROOT_DIR}" || true
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

log_info "Estraggo il contenuto della ISO sorgente (xorriso -osirrox)..."
mkdir -p "${EXTRACT_DIR}"
xorriso -osirrox on -indev "${SOURCE_ISO}" -extract / "${EXTRACT_DIR}" >/dev/null

# Ubuntu 24.04+ non usa più un unico casper/filesystem.squashfs: il
# filesystem live è "a layer" (verificato leggendo i sorgenti ufficiali di
# casper e livecd-rootfs, non per tentativi). Al boot, casper legge un
# LAYERFS_PATH cablato dentro /casper/initrd al momento della build della
# ISO (livecd-rootfs, hook 020-ubuntu-live.chroot_early:
# LAYERFS_PATH=${PASS}.squashfs) e ne deriva la catena di layer togliendo
# un pezzo di nome alla volta: "minimal.standard.live" -> "minimal.standard"
# -> "minimal". Dato che tra i file della ISO c'è minimal.standard.live.squashfs,
# la catena di boot di default (lingua inglese, secure boot normale) è:
#   minimal.squashfs            (base)
#   minimal.standard.squashfs   (desktop completo: QUI vanno le nostre modifiche)
#   minimal.standard.live.squashfs (solo extra di sessione live: casper/ubiquity)
# Le altre varianti (minimal.<lingua>.squashfs, *.enhanced-secureboot*) sono
# layer alternativi per altre combinazioni lingua/secure-boot: non fanno
# parte della catena di default e non li tocchiamo.
BASE_SQUASHFS="${EXTRACT_DIR}/casper/minimal.squashfs"
STANDARD_SQUASHFS="${EXTRACT_DIR}/casper/minimal.standard.squashfs"
LIVE_SQUASHFS="${EXTRACT_DIR}/casper/minimal.standard.live.squashfs"

[[ -f "${BASE_SQUASHFS}" && -f "${STANDARD_SQUASHFS}" ]] || {
    log_err "Non trovo minimal.squashfs / minimal.standard.squashfs nella ISO estratta: layout inatteso rispetto a quanto verificato, controlla a mano."
    exit 1
}
HAVE_LIVE_LAYER=1
[[ -f "${LIVE_SQUASHFS}" ]] || HAVE_LIVE_LAYER=0

# --- 2. Cattura i flag di boot ORIGINALI, per riprodurli identici ----------
# Non li ricostruiamo a mano (BIOS+UEFI hybrid, GPT, shim/secure boot...):
# li chiediamo a xorriso stesso, che li legge dalla ISO sorgente. Così lo
# script resta valido anche se Canonical cambia layout di boot in futuro.
#
# ATTENZIONE (trovato testando su ISO reale): "-report_el_torito as_mkisofs"
# non riporta SOLO i flag di boot, ma l'intera riga per ricreare la ISO,
# comprese cose come "-V 'Ubuntu 26.04.1 LTS amd64'" (etichetta volume) —
# con le virgolette scritte così apposta per essere lette da una VERA
# shell, non da un lettore riga-per-riga. Leggerle con `mapfile` (una riga
# = un argomento) spezza quei token e manda in crash xorriso. Serve
# davvero far ripassare bash sulla sintassi (eval), e poi togliere le
# opzioni di metadata (volume/publisher/preparer/appid) che vogliamo
# impostare noi, non copiare dall'originale.
log_info "Catturo i parametri di boot originali (El Torito / hybrid)..."
BOOT_FLAGS_RAW="$(xorriso -indev "${SOURCE_ISO}" -report_el_torito as_mkisofs 2>/dev/null | grep -E '^-')"

if [[ -z "${BOOT_FLAGS_RAW}" ]]; then
    log_err "Non sono riuscito a leggere i parametri di boot dalla ISO sorgente."
    log_err "Interrotto: senza questi flag la ISO ricostruita rischia di non avviarsi."
    exit 1
fi

# eval fa fare a bash lo stesso lavoro che farebbe una shell vera:
# rispettare le virgolette del report invece di spezzare per newline.
# Fonte fidata (è l'output di xorriso sulla ISO ufficiale, non input
# esterno/utente), uso documentato di "-report_el_torito as_mkisofs".
eval "ALL_ISO_FLAGS=(${BOOT_FLAGS_RAW})"

BOOT_FLAGS=()
skip_next=0
for tok in "${ALL_ISO_FLAGS[@]}"; do
    if [[ "${skip_next}" -eq 1 ]]; then
        skip_next=0
        continue
    fi
    case "${tok}" in
        -V|-p|-A|-sysid|-publisher|-preparer|-appid|-volid)
            # Metadata (etichetta volume, publisher, ecc.): la impostiamo
            # noi esplicitamente più sotto, non vogliamo un duplicato in
            # conflitto con quello originale.
            skip_next=1
            continue
            ;;
    esac
    BOOT_FLAGS+=("${tok}")
done

log_info "Flag di boot catturati (metadata originali come -V esclusi apposta):"
printf '    %s\n' "${BOOT_FLAGS[@]}"

# --- 3. unsquash i 3 layer, overlay, chroot-customize, resquash solo "standard" ---
log_info "Decomprimo il layer base (minimal.squashfs)..."
unsquashfs -d "${BASE_DIR}" "${BASE_SQUASHFS}" >/dev/null

log_info "Decomprimo il layer desktop (minimal.standard.squashfs, quello che modifichiamo)..."
unsquashfs -d "${STANDARD_DIR}" "${STANDARD_SQUASHFS}" >/dev/null

LOWERDIR="${STANDARD_DIR}:${BASE_DIR}"
if [[ "${HAVE_LIVE_LAYER}" -eq 1 ]]; then
    log_info "Decomprimo il layer live-only (minimal.standard.live.squashfs)..."
    unsquashfs -d "${LIVE_DIR}" "${LIVE_SQUASHFS}" >/dev/null
    # overlayfs: il primo elemento di lowerdir vince sugli altri, stesso
    # ordine di priorità con cui casper li monta al boot (live sopra
    # standard sopra base).
    LOWERDIR="${LIVE_DIR}:${STANDARD_DIR}:${BASE_DIR}"
fi

mkdir -p "${OVERLAY_DELTA}" "${OVERLAY_WORK}" "${CHROOT_DIR}"
log_info "Monto i 3 layer in overlay (stessa vista che ha il sistema da avviato)..."
mount -t overlay overlay \
    -o "lowerdir=${LOWERDIR},upperdir=${OVERLAY_DELTA},workdir=${OVERLAY_WORK}" \
    "${CHROOT_DIR}"

log_info "Preparo il chroot (bind mount /dev /proc /sys /run, DNS)..."
mount --bind /dev "${CHROOT_DIR}/dev"
mount --bind /dev/pts "${CHROOT_DIR}/dev/pts"
mount -t proc proc "${CHROOT_DIR}/proc"
mount -t sysfs sys "${CHROOT_DIR}/sys"
mount --bind /run "${CHROOT_DIR}/run"
# /etc/resolv.conf dell'host è spesso un symlink verso
# /run/systemd/resolve/stub-resolv.conf (systemd-resolved): avendo appena
# montato /run in bind, quel percorso dentro il chroot punta già allo
# stesso identico file, quindi "cp" fallirebbe con "sono lo stesso file" —
# non è un errore, il DNS nel chroot funziona comunque grazie al bind
# mount di /run. Copiamo solo se sorgente e destinazione sono davvero
# file diversi.
if ! cmp -s /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null; then
    cp -L /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null || true
fi

cp "${SCRIPT_DIR}/chroot-customize.sh" "${CHROOT_DIR}/chroot-customize.sh"
chmod +x "${CHROOT_DIR}/chroot-customize.sh"

log_info "Eseguo chroot-customize.sh dentro il chroot (vista unita dei 3 layer)..."
chroot "${CHROOT_DIR}" /bin/bash /chroot-customize.sh
rm -f "${CHROOT_DIR}/chroot-customize.sh"

log_info "Ripulisco la cache apt e i file temporanei prima di ricomprimere..."
chroot "${CHROOT_DIR}" apt-get clean || true
rm -f "${CHROOT_DIR}/etc/resolv.conf"
rm -rf "${CHROOT_DIR}/tmp"/* "${CHROOT_DIR}/var/tmp"/* 2>/dev/null || true

log_info "Smonto i bind mount e l'overlay..."
kill_chroot_processes
umount -R "${CHROOT_DIR}/dev" "${CHROOT_DIR}/proc" "${CHROOT_DIR}/sys" "${CHROOT_DIR}/run"
umount "${CHROOT_DIR}"

# OVERLAY_DELTA ora contiene ESATTAMENTE il delta prodotto da
# chroot-customize.sh: pacchetti nuovi, file di config nuovi/modificati, e
# per ogni file/directory RIMOSSO (es. "apt-get purge" di LibreOffice) un
# "whiteout" — un file speciale device-carattere (major:minor 0:0) con cui
# overlayfs marca "questo, anche se esiste in un layer sotto, va
# considerato cancellato". Errore reale riscontrato in VM: rimuovendo
# LibreOffice questi whiteout compaiono davvero (non è più il caso raro
# ipotizzato inizialmente), e `cp -a` fallisce con "cannot overwrite
# directory ... with non-directory" perché prova a sovrascrivere una
# directory vera (in layer-standard, dove viveva LibreOffice) con un
# device-carattere. Li applichiamo quindi come cancellazioni vere e
# proprie su layer-standard PRIMA di copiare il resto del delta.
log_info "Applico eventuali whiteout overlayfs (cancellazioni fatte durante chroot-customize.sh, es. rimozione di LibreOffice) al layer 'standard'..."
WHITEOUTS="$(mktemp)"
find "${OVERLAY_DELTA}" -type c -exec sh -c '
    for f; do
        maj_min="$(stat -c "%t:%T" "$f" 2>/dev/null)"
        [ "$maj_min" = "0:0" ] && printf "%s\n" "$f"
    done
' _ {} + > "${WHITEOUTS}"

while IFS= read -r wh; do
    rel="${wh#${OVERLAY_DELTA}}"
    log_info "  cancellato: ${rel}"
    rm -rf -- "${STANDARD_DIR}${rel}"
    rm -f -- "${wh}"    # tolto anche dal delta: la cancellazione è già applicata, non serve ricopiarlo
done < "${WHITEOUTS}"
rm -f "${WHITEOUTS}"

log_info "Riporto le modifiche (il delta) dentro il layer 'standard'..."
cp -a "${OVERLAY_DELTA}/." "${STANDARD_DIR}/"

log_info "Ricomprimo SOLO il layer 'standard' modificato (mksquashfs, xz, può volerci un po')..."
rm -f "${STANDARD_SQUASHFS}"
mksquashfs "${STANDARD_DIR}" "${STANDARD_SQUASHFS}" -comp xz -noappend
# minimal.squashfs e minimal.standard.live.squashfs (se presente) restano
# byte per byte quelli originali: non li abbiamo mai modificati, solo letti
# in sola lettura dentro l'overlay.

# filesystem.size non viene letto da nessuno script di casper (verificato
# sui sorgenti): serve solo all'installer (subiquity) per una stima
# indicativa dello spazio; la aggiorniamo per approssimazione ma non è
# critica per l'avvio della sessione live.
printf '%s' "$(du -scx --block-size=1 "${BASE_DIR}" "${STANDARD_DIR}" ${HAVE_LIVE_LAYER:+"${LIVE_DIR}"} 2>/dev/null | tail -1 | cut -f1)" \
    > "${EXTRACT_DIR}/casper/filesystem.size"

# --- 3bis. Incorpora l'autoinstall (se richiesto) come datasource NoCloud --
# Cartella /nocloud/ alla radice della ISO + "autoinstall ds=nocloud;s=
# /cdrom/nocloud/" nel kernel command line di grub.cfg: pattern verificato
# via community/documentazione per esattamente questo scopo (autoinstall
# "custom ISO", nessuna seconda chiavetta seed). "/cdrom/" è il punto dove
# casper monta il supporto di boot stesso durante la sessione live/
# installer, quindi punta correttamente a QUESTA ISO una volta avviata.
if [[ "${EMBED_AUTOINSTALL}" -eq 1 ]]; then
    log_info "Incorporo l'autoinstall (cartella /nocloud/ + parametro kernel in grub.cfg)..."
    mkdir -p "${EXTRACT_DIR}/nocloud"
    cp "${AUTOINSTALL_FILE}" "${EXTRACT_DIR}/nocloud/user-data"
    cp "${SCRIPT_DIR}/../disk-setup/meta-data" "${EXTRACT_DIR}/nocloud/meta-data"

    GRUB_CFG_PATCHED=0
    for GRUB_CFG in "${EXTRACT_DIR}/boot/grub/grub.cfg" "${EXTRACT_DIR}/EFI/boot/grub.cfg"; do
        [[ -f "${GRUB_CFG}" ]] || continue
        # Tocca SOLO la prima occorrenza (la entry di default "Try or
        # Install Ubuntu"): non serve toccare "Ubuntu (safe graphics)".
        # Non forza l'installazione: il parametro dice a cloud-init/
        # subiquity DOVE TROVARE i dati, l'installer parte comunque solo
        # se scegli "Install Ubuntu" dal desktop live.
        if grep -q '/casper/vmlinuz' "${GRUB_CFG}"; then
            sed -i '0,/\(linux[[:space:]]\+\/casper\/vmlinuz[[:space:]]\+\)---/{
                s##\1autoinstall "ds=nocloud;s=/cdrom/nocloud/" ---#
            }' "${GRUB_CFG}"
            GRUB_CFG_PATCHED=1
        fi
    done

    if [[ "${GRUB_CFG_PATCHED}" -eq 0 ]]; then
        log_err "Non ho trovato/patchato nessun grub.cfg con /casper/vmlinuz: l'autoinstall NON è stato incorporato correttamente."
        log_err "Interrotto: meglio fermarsi qui che consegnarti una ISO che sembra pronta ma non lo è."
        exit 1
    fi
    log_ok "grub.cfg aggiornato: l'installer, se lanciato dal desktop live, troverà da solo i dati di autoinstall."
fi

log_info "Rigenero md5sum.txt (esclude se stesso e i file di boot già firmati)..."
( cd "${EXTRACT_DIR}" \
  && find . -type f ! -name md5sum.txt ! -path "./boot/*" ! -path "./EFI/*" ! -path "./isolinux/*" \
       -exec md5sum {} \; > md5sum.txt )

# --- 4. Ricostruisci la ISO --------------------------------------------------
log_info "Ricostruisco la ISO con gli stessi flag di boot dell'originale..."
# BOOT_FLAGS è già pronto (array bash corretto, popolato allo step 2).
xorriso -as mkisofs \
    -r -V "Ubuntu Ultimate Live" \
    "${BOOT_FLAGS[@]}" \
    -o "${OUT_ISO}" "${EXTRACT_DIR}"

log_ok "Fatto: ${OUT_ISO}"
echo
echo "Verifica PRIMA di fidartene per la demo:"
echo "  - boot in una VM (create-test-vm.sh usa un percorso ISO diverso, puoi"
echo "    puntarlo qui a mano, o semplicemente avviare questa ISO in virt-manager)"
echo "  - la sessione live parte, Brave/Ghostty/estensioni ci sono già"
echo "  - 'docker compose version', 'zsh --version', 'sensors' funzionano"
echo "  - crea un utente reale (o installa da questa ISO) e verifica che"
echo "    trovi Oh My Zsh in ~/.oh-my-zsh (NON testato: vedi README.md)"
echo "  - prova anche il boot UEFI, non solo BIOS/legacy"
echo "  - avvia con la lingua di default (inglese): è la combinazione di"
echo "    layer che abbiamo verificato/modificato. Selezionare un'altra"
echo "    lingua dal boot menu NON è stato testato: potrebbe usare layer"
echo "    aggiuntivi (minimal.<lingua>.squashfs) che non contengono le"
echo "    nostre modifiche"
if [[ "${EMBED_AUTOINSTALL}" -eq 1 ]]; then
    echo
    echo "ATTENZIONE SICUREZZA: questa ISO contiene /nocloud/user-data con la"
    echo "passphrase LUKS2 e l'hash della password IN CHIARO (ISO9660 non ha"
    echo "permessi per-file utili) — trattala come un segreto: non condividerla,"
    echo "cancellala quando hai finito i test/la demo."
    echo
    echo "Verifica anche l'autoinstall incorporato:"
    echo "  - dal desktop live, scegli 'Install Ubuntu': deve partire senza"
    echo "    chiederti hostname/utente/password/dischi (li ha già dal seed"
    echo "    incorporato), fino alla stessa schermata di conferma già nota"
    echo "  - NON TESTATO end-to-end: verificare che cloud-init trovi davvero"
    echo "    /cdrom/nocloud/ una volta che casper ha montato il supporto"
fi

# --- 5. Flash su USB (opzionale) ---------------------------------------------
# Chiesto da Antonio: a ISO pronta, offre subito di scriverla su una
# chiavetta USB collegata, con selezione interattiva del dispositivo.
#
# NON TESTATO su hardware reale in questa sessione (nessuna chiavetta USB
# reale disponibile nel sandbox in cui è stato scritto): la logica di
# individuazione/esclusione dispositivi è stata verificata leggendo la
# documentazione di lsblk/dd, non con una USB vera collegata.
#
# Sicurezza (il punto più delicato: "dd sul disco sbagliato" è un classico
# modo di cancellare per sbaglio il disco di sistema):
#   - la lista dei dispositivi selezionabili è filtrata da lsblk stesso su
#     TRAN=usb (bus USB) e TYPE=disk (l'intero disco, non una sua
#     partizione) — non un pattern sul nome tipo "/dev/sd*", perché
#     /dev/sdX può benissimo essere anche un disco SATA interno su alcuni
#     controller;
#   - in più viene sempre escluso, per sicurezza aggiuntiva, il disco che
#     contiene la radice (/) di QUESTA macchina — risalendo la catena
#     completa (utile anche nel caso limite di un / su LUKS/LVM sopra al
#     disco fisico), anche se il sistema host stesso girasse da USB;
#   - prima di scrivere viene chiesta una conferma che ripete ESATTAMENTE
#     il nome del device (non un semplice s/N), per evitare un "dd" sul
#     disco sbagliato per distrazione.
echo
read -r -p "Vuoi scrivere subito questa ISO su una chiavetta USB? [s/N] " FLASH_CONFIRM
if [[ "${FLASH_CONFIRM}" =~ ^[sS]$ ]]; then
    # Disco che contiene la radice del sistema host: risaliamo l'intera
    # catena di dispositivi (utile su LUKS/LVM: "lsblk -s" segue i parent
    # fino al disco fisico, non solo un livello come farebbe PKNAME da solo).
    ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
    ROOT_DISK=""
    if [[ -n "${ROOT_SRC}" ]]; then
        ROOT_DISK="$(lsblk -no NAME,TYPE -sp "${ROOT_SRC}" 2>/dev/null | awk '$2=="disk"{print $1}' | tail -n1)"
        ROOT_DISK="${ROOT_DISK##*/}"
    fi

    # lsblk -J (JSON) invece di un parsing a colonne con awk: MODEL/VENDOR
    # possono contenere spazi (es. "SanDisk Ultra USB 3.0"), che romperebbe
    # un parsing posizionale $1/$2/... — JSON via python3 evita quel rischio.
    USB_LIST_TSV="$(
        lsblk -J -o NAME,SIZE,MODEL,VENDOR,TRAN,TYPE 2>/dev/null \
        | python3 -c '
import json, sys
root_disk = sys.argv[1] if len(sys.argv) > 1 else ""
data = json.load(sys.stdin)
for dev in data.get("blockdevices", []):
    if dev.get("type") != "disk":
        continue
    if dev.get("tran") != "usb":
        continue
    if dev.get("name") == root_disk:
        continue
    size = dev.get("size") or "?"
    model = (dev.get("model") or "").strip()
    vendor = (dev.get("vendor") or "").strip()
    label = " ".join(p for p in (vendor, model) if p) or "(sconosciuto)"
    print(f"{dev[\"name\"]}\t{size}\t{label}")
' "${ROOT_DISK}"
    )"

    mapfile -t USB_DEVICES <<< "${USB_LIST_TSV}"
    # mapfile su stringa vuota produce comunque un elemento vuoto: ripuliamo.
    [[ "${#USB_DEVICES[@]}" -eq 1 && -z "${USB_DEVICES[0]}" ]] && USB_DEVICES=()

    if [[ "${#USB_DEVICES[@]}" -eq 0 ]]; then
        log_warn "Nessun dispositivo USB di tipo disco trovato (collegato? riconosciuto come disco intero, non come lettore di schede/partizione?). Salto la scrittura."
    else
        echo
        echo "Dispositivi USB trovati:"
        for i in "${!USB_DEVICES[@]}"; do
            IFS=$'\t' read -r d_name d_size d_label <<< "${USB_DEVICES[$i]}"
            printf '  [%d] /dev/%s  —  %s  (%s)\n' "$((i+1))" "${d_name}" "${d_size}" "${d_label}"
        done
        echo "  [0] Annulla"
        echo
        read -r -p "Quale dispositivo? [0-${#USB_DEVICES[@]}] " USB_CHOICE

        if [[ "${USB_CHOICE}" =~ ^[0-9]+$ ]] && (( USB_CHOICE >= 1 && USB_CHOICE <= ${#USB_DEVICES[@]} )); then
            IFS=$'\t' read -r USB_NAME _ _ <<< "${USB_DEVICES[$((USB_CHOICE-1))]}"
            USB_DEV="/dev/${USB_NAME}"

            if [[ ! -b "${USB_DEV}" ]]; then
                log_err "${USB_DEV} non è (più) un block device valido: annullato."
            else
                echo
                log_warn "ATTENZIONE: TUTTI i dati su ${USB_DEV} verranno cancellati e sostituiti con questa ISO."
                lsblk "${USB_DEV}" -o NAME,SIZE,MODEL,MOUNTPOINT 2>/dev/null || true
                echo
                read -r -p "Per confermare, scrivi esattamente \"${USB_NAME}\": " USB_TYPED
                if [[ "${USB_TYPED}" != "${USB_NAME}" ]]; then
                    log_info "Conferma non corrispondente: annullato, nessuna scrittura effettuata."
                else
                    log_info "Smonto eventuali partizioni già montate di ${USB_DEV}..."
                    # Enumerato via lsblk (non un glob tipo "${USB_DEV}?*"):
                    # funziona anche per naming diversi da /dev/sdX1
                    # (es. /dev/nvme0n1p1, /dev/mmcblk0p1) su adattatori USB
                    # non-SCSI.
                    mapfile -t USB_CHILDREN < <(lsblk -ln -o NAME "${USB_DEV}" 2>/dev/null | tail -n +2)
                    for child in "${USB_CHILDREN[@]}"; do
                        child_dev="/dev/${child}"
                        [[ -b "${child_dev}" ]] || continue
                        child_mp="$(lsblk -no MOUNTPOINT "${child_dev}" 2>/dev/null || true)"
                        if [[ -n "${child_mp}" ]]; then
                            log_info "Smonto ${child_dev} (montato su ${child_mp})..."
                            umount "${child_dev}" 2>/dev/null || umount -l "${child_dev}" 2>/dev/null || true
                        fi
                    done
                    usb_dev_mp="$(lsblk -no MOUNTPOINT "${USB_DEV}" 2>/dev/null || true)"
                    if [[ -n "${usb_dev_mp}" ]]; then
                        umount "${USB_DEV}" 2>/dev/null || umount -l "${USB_DEV}" 2>/dev/null || true
                    fi

                    log_info "Scrivo ${OUT_ISO} su ${USB_DEV} (dd, può richiedere diversi minuti)..."
                    if dd if="${OUT_ISO}" of="${USB_DEV}" bs=4M conv=fsync status=progress; then
                        sync
                        blockdev --rereadpt "${USB_DEV}" 2>/dev/null || true
                        log_ok "Chiavetta USB pronta: ${USB_DEV} è ora avviabile con questa ISO."
                    else
                        log_err "Scrittura su ${USB_DEV} fallita: controlla il messaggio di dd sopra. Il device potrebbe essere in uno stato inconsistente: verifica prima di riusarlo."
                    fi
                fi
            fi
        else
            log_info "Annullato, nessuna scrittura effettuata."
        fi
    fi
fi
