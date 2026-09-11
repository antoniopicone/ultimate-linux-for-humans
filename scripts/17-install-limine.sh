#!/usr/bin/env bash
# 17-install-limine.sh — installa Limine come bootloader SECONDARIO (voce EFI
# prioritaria) accanto a GRUB, che resta installato e funzionante come rete
# di sicurezza. Pensato per un sistema già installato con il layout di questa
# ricetta: ESP (fat32) -> /boot (ext4, non cifrato) -> LUKS2 -> BTRFS con
# subvolume @ per la root.
#
# Perché Limine come bootloader SECONDARIO, non sostituto: se qualcosa nella
# configurazione di Limine non va, dal firmware puoi comunque scegliere la
# voce "ubuntu" (shim+GRUB) e avviare normalmente — nessun rischio di sistema
# non avviabile.
#
# Nessun supporto Secure Boot: questo script presuppone Secure Boot
# DISATTIVO in firmware. Non esiste un binario Limine firmato da
# Microsoft/Canonical: con Secure Boot attivo servirebbe arruolare una chiave
# MOK personalizzata e firmare Limine con quella (passaggio interattivo al
# riavvio) — fuori dallo scopo di questo script.
#
# LUKS2: Limine non ha (e non gli serve) alcun supporto nativo a LUKS — lo
# sblocco lo fa sempre l'initramfs (hook cryptsetup di initramfs-tools),
# esattamente come con GRUB. Il bootloader si limita a caricare kernel e
# initrd da un filesystem che sa leggere (qui: la partizione /boot, non
# cifrata) e a passare la cmdline giusta perché sia poi l'initramfs a
# sbloccare il volume.
#
# Uso: ./17-install-limine.sh

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user

# --- 1. Individua il layout reale del sistema -------------------------------

ESP_MOUNT="/boot/efi"
BOOT_MOUNT="/boot"

if ! mountpoint -q "${ESP_MOUNT}"; then
    log_err "${ESP_MOUNT} non è un mountpoint: questo script si aspetta il layout ESP+/boot+LUKS2+BTRFS di questa ricetta."
    exit 1
fi
if ! mountpoint -q "${BOOT_MOUNT}"; then
    log_err "${BOOT_MOUNT} non è un mountpoint separato: questo script si aspetta /boot su una partizione dedicata non cifrata (vedi disk-setup/autoinstall.yaml.tpl)."
    exit 1
fi

ESP_DEV="$(findmnt -no SOURCE "${ESP_MOUNT}")"
BOOT_DEV="$(findmnt -no SOURCE "${BOOT_MOUNT}")"
BOOT_UUID="$(sudo blkid -s UUID -o value "${BOOT_DEV}")"

if [[ -z "${BOOT_UUID}" ]]; then
    log_err "Non riesco a leggere l'UUID del filesystem di ${BOOT_DEV} (partizione /boot)."
    exit 1
fi

# Nome del disco fisico e numero di partizione dell'ESP, per efibootmgr
# (vuole "-d /dev/nvme0n1 -p 1", non "/dev/nvme0n1p1" come un unico argomento).
ESP_DISK="$(lsblk -no PKNAME "${ESP_DEV}")"
ESP_PART_NUM="$(lsblk -no PARTN "${ESP_DEV}")"
if [[ -z "${ESP_DISK}" || -z "${ESP_PART_NUM}" ]]; then
    log_err "Non riesco a determinare disco/numero di partizione dell'ESP (${ESP_DEV}) via lsblk."
    exit 1
fi
ESP_DISK="/dev/${ESP_DISK}"

# --- 2. Individua la configurazione LUKS2 + BTRFS ---------------------------

# /etc/crypttab: prima riga non-commento, non vuota. Campo 1 = nome mapper
# (es. "cryptroot"), campo 2 = sorgente (es. "UUID=...").
CRYPTTAB_LINE="$(grep -vE '^\s*#|^\s*$' /etc/crypttab | head -n1)"
if [[ -z "${CRYPTTAB_LINE}" ]]; then
    log_err "Nessuna riga valida trovata in /etc/crypttab: questo script si aspetta una root LUKS2 (vedi disk-setup/autoinstall.yaml.tpl)."
    exit 1
fi
CRYPT_NAME="$(awk '{print $1}' <<< "${CRYPTTAB_LINE}")"
CRYPT_SOURCE="$(awk '{print $2}' <<< "${CRYPTTAB_LINE}")"
log_info "Volume LUKS2 rilevato da /etc/crypttab: mapper=${CRYPT_NAME} sorgente=${CRYPT_SOURCE}"

# subvolume BTRFS della root: findmnt mostra "subvol=/@" (con lo slash
# iniziale, percorso dalla radice del filesystem btrfs) — Limine/il kernel
# vogliono "subvol=@" (senza lo slash iniziale, è la sintassi di
# rootflags=). Togliamo quindi lo slash iniziale se presente.
ROOT_SUBVOL="$(findmnt -no OPTIONS / | tr ',' '\n' | grep '^subvol=' | cut -d= -f2)"
ROOT_SUBVOL="${ROOT_SUBVOL#/}"
if [[ -z "${ROOT_SUBVOL}" ]]; then
    log_err "Non riesco a determinare il subvolume BTRFS montato su / (findmnt non riporta 'subvol=')."
    exit 1
fi
log_info "Subvolume BTRFS della root: ${ROOT_SUBVOL}"

# --- 3. Individua kernel e initrd correnti ----------------------------------

if [[ ! -e "${BOOT_MOUNT}/vmlinuz" || ! -e "${BOOT_MOUNT}/initrd.img" ]]; then
    log_err "${BOOT_MOUNT}/vmlinuz o ${BOOT_MOUNT}/initrd.img non trovati (Ubuntu li mantiene come symlink al kernel/initrd correnti)."
    exit 1
fi
KERNEL_FILE="$(basename "$(readlink -f "${BOOT_MOUNT}/vmlinuz")")"
INITRD_FILE="$(basename "$(readlink -f "${BOOT_MOUNT}/initrd.img")")"
log_info "Kernel corrente: ${KERNEL_FILE} / initrd: ${INITRD_FILE}"

# --- 4. Compila Limine da sorgente ------------------------------------------
# Niente pacchetto apt "limine" su Ubuntu/Debian (verificato: nessun
# risultato su packages.ubuntu.com/packages.debian.org) — si compila dal
# tarball di release ufficiale. Serve solo la UEFI x86-64 (BOOTX64.EFI):
# niente BIOS, niente supporto CD/PXE, per il nostro caso (UEFI puro,
# Secure Boot disattivo).
if command -v limine >/dev/null 2>&1 && [[ -f /usr/local/share/limine/BOOTX64.EFI ]]; then
    log_warn "Limine risulta già compilato/installato, salto la build."
else
    log_info "Installo le dipendenze di build..."
    # Limine compila il proprio binario target con clang+ld.lld di default
    # (vedi configure.ac: se non imposti esplicitamente TOOLCHAIN_FOR_TARGET,
    # CC_FOR_TARGET=clang e LD_FOR_TARGET=ld.lld, indipendentemente da quale
    # gcc hai per l'host) — build-essential da solo NON basta, serve clang+lld
    # veri e propri, altrimenti "./configure" fallisce con
    # "checking for clang... no / configure: error: clang invalid, set
    # CC_FOR_TARGET to a valid program".
    # Serve anche nasm: Limine assembla in ASM lo stub UEFI/BIOS, non è
    # coperto da build-essential ("checking for nasm... no / configure:
    # error: nasm not found, please install nasm before configuring").
    sudo apt-get install -y build-essential git clang lld llvm nasm

    BUILD_DIR="$(mktemp -d)"
    trap 'rm -rf "${BUILD_DIR}"' EXIT

    log_info "Clono Limine (branch v12.x) e compilo solo la porta UEFI x86-64..."
    git clone https://github.com/limine-bootloader/limine.git --branch=v12.x --depth=1 "${BUILD_DIR}/limine"
    (
        cd "${BUILD_DIR}/limine"
        ./bootstrap 2>/dev/null || true
        ./configure --enable-uefi-x86-64 --disable-bios --disable-bios-cd --disable-uefi-cd --disable-bios-pxe
        make
        sudo make install
    )
    log_ok "Limine compilato/installato."
fi

# --- 5. Copia il binario EFI nell'ESP (percorso dedicato, non tocca GRUB) ---

LIMINE_EFI_DIR="${ESP_MOUNT}/EFI/limine"
sudo mkdir -p "${LIMINE_EFI_DIR}"

LIMINE_EFI_SRC=""
for candidate in /usr/local/share/limine/BOOTX64.EFI /usr/share/limine/BOOTX64.EFI; do
    if [[ -f "${candidate}" ]]; then
        LIMINE_EFI_SRC="${candidate}"
        break
    fi
done
if [[ -z "${LIMINE_EFI_SRC}" ]]; then
    log_err "Non trovo BOOTX64.EFI dopo la build/installazione di Limine."
    exit 1
fi
sudo cp "${LIMINE_EFI_SRC}" "${LIMINE_EFI_DIR}/BOOTX64.EFI"
log_ok "Limine copiato in ${LIMINE_EFI_DIR}/BOOTX64.EFI"

# --- 6. Copia kernel+initrd sull'ESP e genera limine.conf -------------------
# IMPORTANTE — scoperto testando su hardware reale (PANIC "linux: Failed to
# open kernel with path"): Limine supporta SOLO FAT12/16/32 e ISO9660 (vedi
# il suo README ufficiale, sezione "Supported filesystems") — NESSUN driver
# ext2/ext3/ext4 esiste nel suo sorgente (common/fs/file.s2.c prova solo
# fat32_open()/iso9660_open()). Il nostro /boot è ext4: qualsiasi
# "uuid(...)"/"guid(...)" punti lì, l'apertura del file fallisce sempre.
#
# Avevamo valutato di riformattare /boot in FAT32 per aggirare il problema,
# ma FAT32 non supporta i symlink POSIX, e il pacchetto del kernel Ubuntu
# crea "/boot/vmlinuz" -> "/boot/vmlinuz-X.Y.Z-N-generic" come symlink a ogni
# aggiornamento (comportamento di default dal 20.04, "link_in_boot"): su
# /boot FAT32 quella "ln -sf" fallisce con "Operation not permitted" e
# romperebbe ogni futuro "apt upgrade" che installa un nuovo kernel (bug
# Ubuntu #1318951 "kernel update fails with /boot on FAT32", stesso sintomo
# riscontrato con flash-kernel su Debian/Proxmox).
#
# Soluzione adottata: /boot resta ext4 come oggi (nessun rischio per gli
# aggiornamenti kernel); copiamo invece kernel+initrd CORRENTI sull'ESP
# (FAT32, che Limine sa leggere) in una directory dedicata, e puntiamo
# limine.conf lì con "boot():/..." (la partizione che contiene limine.conf
# stesso, cioè l'ESP — sintassi da CONFIG.md, sezione "Paths"). Il
# mantenimento nel tempo (nuovo kernel installato/rimosso) è affidato allo
# script /usr/local/bin/limine-kernel-sync installato più sotto, agganciato
# a /etc/kernel/postinst.d e postrm.d.

KERNELS_DIR="${ESP_MOUNT}/limine-kernels"
sudo mkdir -p "${KERNELS_DIR}"
sudo cp -f "${BOOT_MOUNT}/${KERNEL_FILE}" "${KERNELS_DIR}/${KERNEL_FILE}"
sudo cp -f "${BOOT_MOUNT}/${INITRD_FILE}" "${KERNELS_DIR}/${INITRD_FILE}"
log_ok "Kernel/initrd correnti copiati sull'ESP in ${KERNELS_DIR}/"

# "cryptdevice=" è la sintassi che initramfs-tools/cryptsetup-initramfs si
# aspetta; "rd.luks.uuid=" è quella che dracut si aspetta (vedi
# 19-tpm2-autounlock.sh, che sostituisce initramfs-tools con dracut per lo
# sblocco automatico via TPM2) — includerla sempre è innocuo anche quando si
# usa ancora initramfs-tools (parametro ignorato, nessun conflitto), ed evita
# di dover rigenerare la cmdline in un secondo momento se in futuro si passa
# a dracut.
CRYPT_UUID="${CRYPT_SOURCE#UUID=}"
CMDLINE="root=/dev/mapper/${CRYPT_NAME} rootflags=subvol=${ROOT_SUBVOL} rootfstype=btrfs cryptdevice=${CRYPT_SOURCE}:${CRYPT_NAME} rd.luks.uuid=${CRYPT_UUID} rw quiet splash"

sudo tee "${LIMINE_EFI_DIR}/limine.conf" >/dev/null <<LIMINECONFEOF
timeout: 5
interface_branding: Ubuntu Ultimate
interface_branding_colour: E95420
term_palette: 262626;E95420;3A9D5D;C7A317;4A90D9;9B6BC7;3A9D9D;C4C4C4
term_palette_bright: 5C5C5C;FF6E3A;5BC787;E8C547;6BA9EA;B98CE0;5BC7C7;FFFFFF
term_background: 00171717
term_foreground: C4C4C4

/Ubuntu Ultimate
    protocol: linux
    kernel_path: boot():/limine-kernels/${KERNEL_FILE}
    module_path: boot():/limine-kernels/${INITRD_FILE}
    kernel_cmdline: ${CMDLINE}

#### LIMINE-SNAPSHOT-SYNC:BEGIN (generato automaticamente da limine-snapshot-sync, non modificare a mano)
#### LIMINE-SNAPSHOT-SYNC:END
LIMINECONFEOF

log_ok "Configurazione scritta in ${LIMINE_EFI_DIR}/limine.conf"
log_info "cmdline generata: ${CMDLINE}"

# --- 6b. Hook di sincronizzazione: kernel/initrd sull'ESP sempre aggiornati -
# Rigenera automaticamente la copia su ESP (e le righe kernel_path/module_path
# di TUTTE le entry di limine.conf, incluse quelle snapshot aggiunte da
# 18-limine-snapshot-sync.sh: usano lo stesso kernel/initrd corrente, cambia
# solo rootflags=subvol=) a ogni installazione o rimozione di un pacchetto
# linux-image-*, così non serve mai rieseguire questo script a mano dopo un
# "apt upgrade".
sudo tee /usr/local/bin/limine-kernel-sync >/dev/null <<'KSYNCEOF'
#!/usr/bin/env bash
# Rigenera la copia su ESP di kernel/initrd correnti (letti dai symlink
# /boot/vmlinuz e /boot/initrd.img) e le righe kernel_path/module_path di
# limine.conf. Installato da 17-install-limine.sh e agganciato a
# /etc/kernel/postinst.d e postrm.d — non modificarlo a mano, verrebbe
# sovrascritto alla prossima esecuzione di quello script.
set -euo pipefail

ESP_MOUNT="/boot/efi"
BOOT_MOUNT="/boot"
LIMINE_CONF="${ESP_MOUNT}/EFI/limine/limine.conf"
KERNELS_DIR="${ESP_MOUNT}/limine-kernels"

[[ -f "${LIMINE_CONF}" ]] || exit 0
[[ -e "${BOOT_MOUNT}/vmlinuz" && -e "${BOOT_MOUNT}/initrd.img" ]] || exit 0

mkdir -p "${KERNELS_DIR}"

KERNEL_FILE="$(basename "$(readlink -f "${BOOT_MOUNT}/vmlinuz")")"
INITRD_FILE="$(basename "$(readlink -f "${BOOT_MOUNT}/initrd.img")")"

cp -f "${BOOT_MOUNT}/${KERNEL_FILE}" "${KERNELS_DIR}/${KERNEL_FILE}"
cp -f "${BOOT_MOUNT}/${INITRD_FILE}" "${KERNELS_DIR}/${INITRD_FILE}"

# Ripulisce sull'ESP le versioni non più presenti in /boot (es. dopo la
# rimozione di un kernel vecchio), per non riempirlo lentamente nel tempo.
for f in "${KERNELS_DIR}"/vmlinuz-* "${KERNELS_DIR}"/initrd.img-*; do
    [[ -e "${f}" ]] || continue
    base="$(basename "${f}")"
    [[ -e "${BOOT_MOUNT}/${base}" ]] || rm -f "${f}"
done

sed -i \
    -e "s#^\(\s*kernel_path:\s*\)boot():/limine-kernels/.*#\1boot():/limine-kernels/${KERNEL_FILE}#" \
    -e "s#^\(\s*module_path:\s*\)boot():/limine-kernels/.*#\1boot():/limine-kernels/${INITRD_FILE}#" \
    "${LIMINE_CONF}"
KSYNCEOF
sudo chmod 755 /usr/local/bin/limine-kernel-sync

sudo tee /etc/kernel/postinst.d/zz-limine-kernel-sync >/dev/null <<'HOOKEOF'
#!/bin/sh
# Installato da 17-install-limine.sh: tiene sincronizzata la copia su ESP di
# kernel/initrd usata da Limine (non legge ext4, vedi commenti in quello
# script) a ogni installazione di un nuovo pacchetto linux-image-*. "zz-"
# nel nome per girare dopo l'hook di initramfs-tools (deve esistere già
# initrd.img-<versione> quando lo eseguiamo).
/usr/local/bin/limine-kernel-sync || true
HOOKEOF
sudo chmod 755 /etc/kernel/postinst.d/zz-limine-kernel-sync

sudo tee /etc/kernel/postrm.d/zz-limine-kernel-sync >/dev/null <<'HOOKEOF'
#!/bin/sh
# Come /etc/kernel/postinst.d/zz-limine-kernel-sync, ma alla rimozione di un
# kernel: lo script è idempotente e si allinea sempre allo stato corrente di
# /boot, quindi lo stesso identico comando va bene in entrambi i casi.
/usr/local/bin/limine-kernel-sync || true
HOOKEOF
sudo chmod 755 /etc/kernel/postrm.d/zz-limine-kernel-sync

log_ok "Hook di sincronizzazione kernel installato (/usr/local/bin/limine-kernel-sync + postinst.d/postrm.d)."

# Questo script riscrive "limine.conf" per intero a ogni esecuzione (utile
# per applicare modifiche come branding/tema); l'heredoc sopra include già i
# marcatori LIMINE-SNAPSHOT-SYNC (vuoti) così il blocco esiste sempre, anche
# su un'installazione dove 18-limine-snapshot-sync.sh non è mai stato
# eseguito — BUG REALE trovato su hardware: prima che i marcatori fossero
# nell'heredoc, ogni rigenerazione di limine.conf li cancellava del tutto
# (non solo li svuotava), e limine-snapshot-sync trovandoli assenti usciva
# subito senza scrivere nulla (vedi il suo "grep ... || exit 0"), facendo
# sparire silenziosamente tutte le voci snapshot dal menu fino al prossimo
# evento su /.snapshots. Ora che i marcatori sono sempre presenti, se
# 18-limine-snapshot-sync.sh è già stato eseguito in precedenza rigeneriamo
# subito qui le voci, invece di aspettare il prossimo evento su /.snapshots.
if command -v limine-snapshot-sync >/dev/null 2>&1; then
    log_info "limine-snapshot-sync già installato: rigenero subito le voci snapshot..."
    sudo limine-snapshot-sync || log_warn "limine-snapshot-sync ha restituito un errore, controlla manualmente."
fi

# --- 7. Voce EFI: Limine PRIMA di GRUB, senza cancellare quella esistente ---

if ! command -v efibootmgr >/dev/null 2>&1; then
    sudo apt-get install -y efibootmgr
fi

EXISTING_LIMINE_BOOTNUM="$(sudo efibootmgr -v | awk -F'[ *]+' '/Limine/ {sub(/^Boot/,"",$1); print $1; exit}')"
if [[ -n "${EXISTING_LIMINE_BOOTNUM}" ]]; then
    log_warn "Trovata già una voce EFI 'Limine' (Boot${EXISTING_LIMINE_BOOTNUM}), la rimuovo prima di ricrearla (evita doppioni a ogni riesecuzione)."
    sudo efibootmgr --bootnum "${EXISTING_LIMINE_BOOTNUM}" --delete-bootnum >/dev/null
fi

sudo efibootmgr --create \
    --disk "${ESP_DISK}" \
    --part "${ESP_PART_NUM}" \
    --loader '\EFI\limine\BOOTX64.EFI' \
    --label "Limine" >/dev/null

NEW_LIMINE_BOOTNUM="$(sudo efibootmgr -v | awk -F'[ *]+' '/Limine/ {sub(/^Boot/,"",$1); print $1; exit}')"
CURRENT_ORDER="$(sudo efibootmgr | awk -F': ' '/^BootOrder/ {print $2}')"
# Rimetti Limine in testa, mantenendo intatto l'ordine delle voci esistenti
# (incluso "ubuntu"/GRUB) subito dopo.
REST_ORDER="$(tr ',' '\n' <<< "${CURRENT_ORDER}" | grep -v "^${NEW_LIMINE_BOOTNUM}$" | paste -sd, -)"
if [[ -n "${REST_ORDER}" ]]; then
    sudo efibootmgr --bootorder "${NEW_LIMINE_BOOTNUM},${REST_ORDER}" >/dev/null
else
    sudo efibootmgr --bootorder "${NEW_LIMINE_BOOTNUM}" >/dev/null
fi

log_ok "Voce EFI 'Limine' (Boot${NEW_LIMINE_BOOTNUM}) creata e messa per prima nell'ordine di avvio."
log_warn "GRUB resta installato e raggiungibile dal menu del firmware come rete di sicurezza."
log_info "Riavvia per provare Limine. Se qualcosa non va, scegli dal firmware (F2/F10/F12 all'accensione, dipende dalla scheda madre) la voce 'ubuntu' per tornare a GRUB."
