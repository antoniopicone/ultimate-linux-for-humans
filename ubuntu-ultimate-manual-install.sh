#!/usr/bin/env bash
#
# ubuntu-ultimate-manual-install.sh
# ==================================
# Installer interattivo derivato dalla ricetta "ubuntu-ultimate", pensato per
# essere lanciato da una live Ubuntu 26.04 LTS Server (arm64) su hardware reale
# (es. una scheda/server ARM con UEFI reale) quando non si vuole/può passare
# dall'autoinstall di Subiquity.
#
# Fa TUTTO in modo interattivo (a differenza dell'autoinstall):
#   1. mostra le partizioni disponibili e fa scegliere quella per l'ESP
#      (FAT32, EFI System Partition) e quella per il volume LUKS2/BTRFS
#   2. chiede nome utente, nome completo, email, password
#   3. cifra la partizione scelta con LUKS2, ci crea sopra BTRFS con layout
#      "flat" stile openSUSE (@ @home @var @snapshots @home_snapshots)
#   4. installa un sistema Ubuntu 26.04 arm64 di base con debootstrap
#   5. configura crypttab/fstab, crea l'utente, installa Snapper (root+home,
#      stessa retention della ricetta autoinstall) e Limine come bootloader
#      UEFI (binario precompilato, ramo `latest-binary` upstream), con
#      generazione delle voci di menu per gli snapshot BTRFS
#
# COSA NON FA (volutamente fuori scope rispetto a questa richiesta, e già
# coperto da script standalone separati nel repo "ubuntu-ultimate" — vanno
# eseguiti DOPO, a sistema installato e riavviato):
#   - sblocco automatico TPM2 (scripts/19-tpm2-autounlock.sh)
#   - Howdy, USBGuard, Podman, desktop GNOME/tema/estensioni, icloud-*, ecc.
#
# ATTENZIONE — QUESTO SCRIPT È DISTRUTTIVO: formatta partizioni e può
# cancellare dati. Va eseguito SOLO dentro l'ambiente live, mai su un sistema
# già in uso, e va sempre validato prima in una VM.
#
# Verificato con `bash -n`. NON ANCORA TESTATO end-to-end su hardware reale:
# stesso principio "non ancora verificato" già usato nel resto della ricetta —
# vedi il messaggio finale/i commenti "DA VERIFICARE" sparsi nello script.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configurazione di default (sovrascrivibile con variabili d'ambiente prima
# di lanciare lo script, es. RELEASE_CODENAME=noble ./ubuntu-ultimate-manual-install.sh)
# ---------------------------------------------------------------------------
RELEASE_CODENAME="${RELEASE_CODENAME:-$(lsb_release -cs 2>/dev/null || echo resolute)}"
UBUNTU_PORTS_MIRROR="${UBUNTU_PORTS_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
TARGET_MNT="${TARGET_MNT:-/mnt}"
LUKS_MAPPER_NAME="${LUKS_MAPPER_NAME:-cryptroot}"
LIMINE_BINARY_BRANCH="${LIMINE_BINARY_BRANCH:-latest-binary}"
WORKDIR="$(mktemp -d /tmp/ubuntu-ultimate-manual-install.XXXXXX)"

# Retention Snapper, stessa della ricetta autoinstall (root 6h/7d/4w/3m,
# home 12h/14d/8w/6m).
SNAP_ROOT_HOURLY=6;  SNAP_ROOT_DAILY=7;  SNAP_ROOT_WEEKLY=4; SNAP_ROOT_MONTHLY=3
SNAP_HOME_HOURLY=12; SNAP_HOME_DAILY=14; SNAP_HOME_WEEKLY=8; SNAP_HOME_MONTHLY=6

# ---------------------------------------------------------------------------
# Logging (stesso schema log_info/log_warn/log_err del resto della ricetta)
# ---------------------------------------------------------------------------
log_info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
log_warn() { printf '\033[1;33m[ATTENZIONE]\033[0m %s\n' "$*" >&2; }
log_err()  { printf '\033[1;31m[ERRORE]\033[0m %s\n' "$*" >&2; }
die()      { log_err "$*"; exit 1; }

MOUNTED_STACK=()   # tiene traccia dei mount fatti, per lo smontaggio in ordine inverso
push_mount() { MOUNTED_STACK+=("$1"); }

cleanup_on_error() {
  local rc=$?
  [ $rc -eq 0 ] && return
  log_err "Uscita con errore (rc=$rc). Provo un cleanup best-effort (smontaggi/chiusura LUKS)..."
  for ((i = ${#MOUNTED_STACK[@]} - 1; i >= 0; i--)); do
    umount -R "${MOUNTED_STACK[$i]}" 2>/dev/null || true
  done
  if [ -n "${LUKS_PART:-}" ] && [ -e "/dev/mapper/${LUKS_MAPPER_NAME}" ]; then
    cryptsetup close "${LUKS_MAPPER_NAME}" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR" 2>/dev/null || true
  exit $rc
}
trap cleanup_on_error EXIT

# ---------------------------------------------------------------------------
# 0. Pre-condizioni
# ---------------------------------------------------------------------------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log_warn "Serve root, mi rilancio con sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

check_environment() {
  local arch
  arch="$(uname -m)"
  if [ "$arch" != "aarch64" ]; then
    log_warn "Architettura rilevata: $arch (atteso aarch64/arm64)."
    read -rp "Continuare comunque? [s/N] " ans
    [[ "$ans" =~ ^[sS]$ ]] || die "Interrotto dall'utente."
  fi
  [ -d /sys/firmware/efi ] || die "Nessun /sys/firmware/efi: questa macchina non ha avviato in modalità UEFI. Limine su arm64 richiede UEFI (niente BIOS/CSM su ARM)."
  command -v debootstrap >/dev/null 2>&1 || APT_NEEDED+=(debootstrap)
  log_info "Ambiente OK: arch=$arch, UEFI presente, release target=$RELEASE_CODENAME."
}

APT_NEEDED=()
install_host_dependencies() {
  local pkgs=(cryptsetup btrfs-progs dosfstools gdisk parted git curl ca-certificates
              efibootmgr snapper debootstrap arch-install-scripts)
  local missing=()
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log_info "Installo dipendenze host mancanti: ${missing[*]}"
    apt-get update -y
    apt-get install -y "${missing[@]}"
  fi
}

# ---------------------------------------------------------------------------
# 1. Selezione partizioni
# ---------------------------------------------------------------------------
list_partitions() {
  echo
  lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,PARTTYPENAME,MOUNTPOINTS,MODEL
  echo
}

# Restituisce su stdout la lista di path di partizioni (TYPE=part), una per riga
partition_paths() {
  lsblk -rno PATH,TYPE | awk '$2=="part"{print $1}'
}

choose_partition() {
  local prompt="$1"
  local exclude="${2:-}"
  local -a candidates=()
  while IFS= read -r p; do
    [ -n "$exclude" ] && [ "$p" = "$exclude" ] && continue
    candidates+=("$p")
  done < <(partition_paths)

  [ "${#candidates[@]}" -gt 0 ] || die "Nessuna partizione trovata su questo sistema."

  echo "$prompt" >&2
  local i=1
  for c in "${candidates[@]}"; do
    local size fstype label mnt
    size=$(lsblk -rno SIZE "$c")
    fstype=$(lsblk -rno FSTYPE "$c")
    label=$(lsblk -rno PARTTYPENAME "$c")
    mnt=$(lsblk -rno MOUNTPOINTS "$c" | tr '\n' ',' )
    printf '  %2d) %-16s %-8s %-10s %-24s %s\n' "$i" "$c" "$size" "${fstype:-?}" "${label:-?}" "${mnt:-non montata}" >&2
    i=$((i + 1))
  done

  local choice
  while true; do
    read -rp "Numero: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#candidates[@]}" ]; then
      echo "${candidates[$((choice - 1))]}"
      return 0
    fi
    log_err "Scelta non valida." >&2
  done
}

# ---------------------------------------------------------------------------
# 2. Dati utente
# ---------------------------------------------------------------------------
prompt_user_details() {
  while true; do
    read -rp "Nome utente (solo minuscole/numeri/trattini, es. antonio): " USERNAME
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
    log_err "Nome utente non valido."
  done
  read -rp "Nome e cognome completo (GECOS, mostrato da GDM/login): " FULLNAME
  while true; do
    read -rp "Email (per 'git config user.email'): " USER_EMAIL
    [[ "$USER_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] && break
    log_err "Email non valida."
  done
  while true; do
    read -rsp "Password per $USERNAME: " USER_PASSWORD; echo
    read -rsp "Ripeti password: " USER_PASSWORD_CONFIRM; echo
    [ "$USER_PASSWORD" = "$USER_PASSWORD_CONFIRM" ] && [ -n "$USER_PASSWORD" ] && break
    log_err "Le due password non coincidono (o sono vuote)."
  done
  while true; do
    read -rsp "Passphrase LUKS2 per il disco (può essere diversa dalla password utente): " LUKS_PASSPHRASE; echo
    read -rsp "Ripeti passphrase LUKS2: " LUKS_PASSPHRASE_CONFIRM; echo
    [ "$LUKS_PASSPHRASE" = "$LUKS_PASSPHRASE_CONFIRM" ] && [ -n "$LUKS_PASSPHRASE" ] && break
    log_err "Le due passphrase non coincidono (o sono vuote)."
  done
  read -rp "Hostname [${USERNAME}-ubuntu]: " HOSTNAME_INPUT
  HOSTNAME_VAL="${HOSTNAME_INPUT:-${USERNAME}-ubuntu}"
}

# ---------------------------------------------------------------------------
# 3. Riepilogo e conferma distruttiva
# ---------------------------------------------------------------------------
confirm_summary() {
  echo
  log_warn "RIEPILOGO — le operazioni seguenti sono DISTRUTTIVE:"
  cat <<EOF
  Partizione ESP (EFI):        $EFI_PART $( [ "$FORMAT_ESP" = "1" ] && echo "-> verrà FORMATTATA come FAT32" || echo "-> mantenuta com'è, solo montata" )
  Partizione per LUKS2/BTRFS:  $LUKS_PART -> verrà CIFRATA e FORMATTATA (TUTTI I DATI PERSI)
  Rilascio Ubuntu:             $RELEASE_CODENAME (arm64, via $UBUNTU_PORTS_MIRROR)
  Hostname:                    $HOSTNAME_VAL
  Utente:                      $USERNAME ($FULLNAME <$USER_EMAIL>)
EOF
  echo
  read -rp "Digita ESATTAMENTE il device LUKS ($LUKS_PART) per confermare e procedere: " confirm_dev
  [ "$confirm_dev" = "$LUKS_PART" ] || die "Conferma non corrispondente, interrotto per sicurezza."
}

# ---------------------------------------------------------------------------
# 4. ESP
# ---------------------------------------------------------------------------
setup_esp() {
  local fstype
  fstype=$(lsblk -rno FSTYPE "$EFI_PART")
  if [ "$fstype" = "vfat" ]; then
    read -rp "La partizione $EFI_PART è già FAT32/vfat. Riformattarla comunque? [s/N] " ans
    [[ "$ans" =~ ^[sS]$ ]] && FORMAT_ESP=1 || FORMAT_ESP=0
  else
    log_warn "$EFI_PART non è FAT32/vfat (fstype=${fstype:-vuoto}): verrà formattata obbligatoriamente."
    FORMAT_ESP=1
  fi
  if [ "$FORMAT_ESP" = "1" ]; then
    mkfs.vfat -F32 -n EFISYS "$EFI_PART"
  fi
}

# ---------------------------------------------------------------------------
# 5. LUKS2 + BTRFS
# ---------------------------------------------------------------------------
setup_luks_btrfs() {
  log_info "Formattazione LUKS2 su $LUKS_PART..."
  printf '%s' "$LUKS_PASSPHRASE" | cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
    --pbkdf argon2id --label ultimate_crypt "$LUKS_PART" --key-file=-

  log_info "Apertura del volume LUKS2 come /dev/mapper/${LUKS_MAPPER_NAME}..."
  printf '%s' "$LUKS_PASSPHRASE" | cryptsetup open "$LUKS_PART" "$LUKS_MAPPER_NAME" --key-file=-

  local mapper="/dev/mapper/${LUKS_MAPPER_NAME}"
  log_info "Creazione filesystem BTRFS su $mapper..."
  mkfs.btrfs -f -L ultimate_root "$mapper"

  log_info "Creazione subvolumi (layout flat stile openSUSE: @ @home @var @snapshots @home_snapshots)..."
  mkdir -p "$WORKDIR/btrfs-top"
  mount "$mapper" "$WORKDIR/btrfs-top"
  push_mount "$WORKDIR/btrfs-top"
  for sv in @ @home @var @snapshots; do
    btrfs subvolume create "$WORKDIR/btrfs-top/$sv" >/dev/null
  done
  umount "$WORKDIR/btrfs-top"
  MOUNTED_STACK=("${MOUNTED_STACK[@]:0:$((${#MOUNTED_STACK[@]}-1))}")

  local mo="compress=zstd:1,noatime,ssd,space_cache=v2"
  mkdir -p "$TARGET_MNT"
  mount -o "${mo},subvol=@" "$mapper" "$TARGET_MNT"
  push_mount "$TARGET_MNT"

  mkdir -p "$TARGET_MNT"/{home,var,.snapshots,boot/efi}
  mount -o "${mo},subvol=@home" "$mapper" "$TARGET_MNT/home"
  push_mount "$TARGET_MNT/home"
  mount -o "${mo},subvol=@var" "$mapper" "$TARGET_MNT/var"
  push_mount "$TARGET_MNT/var"
  mount -o "${mo},subvol=@snapshots" "$mapper" "$TARGET_MNT/.snapshots"
  push_mount "$TARGET_MNT/.snapshots"

  # @home_snapshots va creato DOPO che @home è montato, perché deve essere
  # un subvolume figlio del top-level ma la sua cartella di aggancio vive
  # sotto @home (stesso schema "sibling top-level" già validato nella ricetta
  # autoinstall per /home/.snapshots).
  mkdir -p "$WORKDIR/btrfs-top2"
  mount "$mapper" "$WORKDIR/btrfs-top2"
  push_mount "$WORKDIR/btrfs-top2"
  btrfs subvolume create "$WORKDIR/btrfs-top2/@home_snapshots" >/dev/null
  umount "$WORKDIR/btrfs-top2"
  MOUNTED_STACK=("${MOUNTED_STACK[@]:0:$((${#MOUNTED_STACK[@]}-1))}")

  mkdir -p "$TARGET_MNT/home/.snapshots"
  mount -o "${mo},subvol=@home_snapshots" "$mapper" "$TARGET_MNT/home/.snapshots"
  push_mount "$TARGET_MNT/home/.snapshots"

  mount "$EFI_PART" "$TARGET_MNT/boot/efi"
  push_mount "$TARGET_MNT/boot/efi"

  log_info "zram: attivo via systemd-zram-generator dopo il debootstrap (vedi chroot)."
}

# ---------------------------------------------------------------------------
# 6. debootstrap
# ---------------------------------------------------------------------------
run_debootstrap() {
  log_info "debootstrap arm64/$RELEASE_CODENAME in $TARGET_MNT (richiede rete)..."
  if ! curl -fsSL --max-time 5 "$UBUNTU_PORTS_MIRROR/dists/$RELEASE_CODENAME/Release" >/dev/null 2>&1; then
    log_warn "Impossibile raggiungere $UBUNTU_PORTS_MIRROR per il codename '$RELEASE_CODENAME' — verifica rete/codename prima di continuare (RELEASE_CODENAME=... per sovrascrivere)."
  fi
  debootstrap --arch=arm64 --variant=minbase "$RELEASE_CODENAME" "$TARGET_MNT" "$UBUNTU_PORTS_MIRROR"
}

# ---------------------------------------------------------------------------
# 7. fstab / crypttab (calcolati da host, con gli UUID reali)
# ---------------------------------------------------------------------------
write_fstab_crypttab() {
  local luks_uuid esp_uuid
  luks_uuid=$(blkid -s UUID -o value "$LUKS_PART")
  esp_uuid=$(blkid -s UUID -o value "$EFI_PART")
  [ -n "$luks_uuid" ] && [ -n "$esp_uuid" ] || die "Impossibile leggere gli UUID delle partizioni."

  cat > "$TARGET_MNT/etc/crypttab" <<EOF
# <target name> <source device> <key file> <options>
${LUKS_MAPPER_NAME} UUID=${luks_uuid} none luks,discard
EOF

  local mo="compress=zstd:1,noatime,ssd,space_cache=v2"
  cat > "$TARGET_MNT/etc/fstab" <<EOF
# <file system>                              <mount point>   <type>  <options>                          <dump> <pass>
/dev/mapper/${LUKS_MAPPER_NAME}               /               btrfs   ${mo},subvol=@                     0 0
/dev/mapper/${LUKS_MAPPER_NAME}               /home           btrfs   ${mo},subvol=@home                 0 0
/dev/mapper/${LUKS_MAPPER_NAME}               /var            btrfs   ${mo},subvol=@var                  0 0
/dev/mapper/${LUKS_MAPPER_NAME}               /.snapshots     btrfs   ${mo},subvol=@snapshots             0 0
/dev/mapper/${LUKS_MAPPER_NAME}               /home/.snapshots btrfs  ${mo},subvol=@home_snapshots        0 0
UUID=${esp_uuid}                              /boot/efi       vfat    fmask=0077,dmask=0077               0 1
EOF
  # NOTA: /boot NON è su FAT32 (romperebbe gli aggiornamenti kernel, symlink
  # POSIX non supportati — bug Ubuntu #1318951, già documentato nella ricetta).
  # Kernel+initrd restano su BTRFS (/boot/vmlinuz-*, /boot/initrd.img-*) e
  # vengono COPIATI sull'ESP da un hook dedicato, perché Limine legge solo
  # FAT12/16/32/ISO9660.
}

# ---------------------------------------------------------------------------
# 8. bind mount + chroot
# ---------------------------------------------------------------------------
prepare_chroot_binds() {
  for d in dev dev/pts proc sys; do
    mount --bind "/$d" "$TARGET_MNT/$d"
    push_mount "$TARGET_MNT/$d"
  done
  if ! mountpoint -q "$TARGET_MNT/sys/firmware/efi/efivars"; then
    mount -t efivarfs efivarfs "$TARGET_MNT/sys/firmware/efi/efivars"
    push_mount "$TARGET_MNT/sys/firmware/efi/efivars"
  fi
  cp -L /etc/resolv.conf "$TARGET_MNT/etc/resolv.conf" 2>/dev/null || true
}

write_chroot_script() {
  cat > "$TARGET_MNT/root/ultimate-chroot-setup.sh" <<CHROOTEOF
#!/usr/bin/env bash
set -Eeuxo pipefail

export DEBIAN_FRONTEND=noninteractive
RELEASE_CODENAME="${RELEASE_CODENAME}"
HOSTNAME_VAL="${HOSTNAME_VAL}"
USERNAME="${USERNAME}"
FULLNAME="${FULLNAME}"
USER_EMAIL="${USER_EMAIL}"
LIMINE_BINARY_BRANCH="${LIMINE_BINARY_BRANCH}"

echo "\$HOSTNAME_VAL" > /etc/hostname
sed -i "1i 127.0.1.1\t\$HOSTNAME_VAL" /etc/hosts

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
echo 'LANG=en_US.UTF-8' > /etc/default/locale

cat > /etc/apt/sources.list <<APTEOF
deb ${UBUNTU_PORTS_MIRROR} \$RELEASE_CODENAME main restricted universe multiverse
deb ${UBUNTU_PORTS_MIRROR} \$RELEASE_CODENAME-updates main restricted universe multiverse
deb ${UBUNTU_PORTS_MIRROR} \$RELEASE_CODENAME-security main restricted universe multiverse
APTEOF

apt-get update -y
apt-get install -y --no-install-recommends \
  linux-generic \
  cryptsetup cryptsetup-initramfs \
  btrfs-progs snapper \
  dosfstools efibootmgr \
  sudo network-manager openssh-server \
  git curl ca-certificates locales \
  systemd-zram-generator \
  console-setup keyboard-configuration

# --- utente ---
useradd -m -s /bin/bash -c "\$FULLNAME" "\$USERNAME"
usermod -aG sudo "\$USERNAME"
echo "\$USERNAME:${USER_PASSWORD}" | chpasswd
sudo -u "\$USERNAME" HOME="/home/\$USERNAME" git config --global user.name "\$FULLNAME"
sudo -u "\$USERNAME" HOME="/home/\$USERNAME" git config --global user.email "\$USER_EMAIL"

# --- initramfs (cryptsetup-initramfs si aggancia da solo via hook, rigenero per sicurezza) ---
update-initramfs -u -k all

# --- zram (systemd-zram-generator nativo, non zram-config di terze parti) ---
mkdir -p /etc/systemd
cat > /etc/systemd/zram-generator.conf <<ZRAMEOF
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAMEOF

# --- Snapper: config scritte DIRETTAMENTE (non "snapper create-config"),
#     perché .snapshots è già un subvolume top-level pre-montato, non quello
#     che "create-config" creerebbe da sé — stesso adattamento già validato
#     nella ricetta autoinstall.
mkdir -p /etc/snapper/configs
cat > /etc/snapper/configs/root <<SNAPROOTEOF
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS="\$USERNAME"
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="50"
NUMBER_LIMIT_IMPORTANT="10"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="${SNAP_ROOT_HOURLY}"
TIMELINE_LIMIT_DAILY="${SNAP_ROOT_DAILY}"
TIMELINE_LIMIT_WEEKLY="${SNAP_ROOT_WEEKLY}"
TIMELINE_LIMIT_MONTHLY="${SNAP_ROOT_MONTHLY}"
TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
SNAPROOTEOF

cat > /etc/snapper/configs/home <<SNAPHOMEEOF
SUBVOLUME="/home"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS="\$USERNAME"
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="50"
NUMBER_LIMIT_IMPORTANT="10"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="${SNAP_HOME_HOURLY}"
TIMELINE_LIMIT_DAILY="${SNAP_HOME_DAILY}"
TIMELINE_LIMIT_WEEKLY="${SNAP_HOME_WEEKLY}"
TIMELINE_LIMIT_MONTHLY="${SNAP_HOME_MONTHLY}"
TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
SNAPHOMEEOF

# DA VERIFICARE su questa specifica versione di Ubuntu: il pacchetto snapper
# per Debian/Ubuntu storicamente registra le config attive in
# /etc/conf.d/snapper (stile openSUSE) — se questa release usa un path
# diverso, aggiustare qui.
mkdir -p /etc/conf.d
echo 'SNAPPER_CONFIGS="root home"' > /etc/conf.d/snapper

# se i nomi dei timer differiscono in questa release di Ubuntu, va corretto a mano
systemctl enable snapper-timeline.timer snapper-cleanup.timer 2>/dev/null || true

# --- Limine: binario precompilato upstream (ramo "\$LIMINE_BINARY_BRANCH"),
#     NESSUNA build da sorgente qui (scelta deliberata: niente toolchain
#     clang/lld/llvm da tirare dentro il chroot solo per questo script
#     interattivo — a differenza della ricetta autoinstall che compila da
#     sorgente per altri motivi; il binario precompilato upstream è lo
#     stesso artefatto, solo distribuito già pronto).
git clone --depth 1 --branch "\$LIMINE_BINARY_BRANCH" https://github.com/limine-bootloader/limine.git /opt/limine-src
mkdir -p /boot/efi/EFI/BOOT /boot/efi/EFI/limine
cp -v /opt/limine-src/BOOTAA64.EFI /boot/efi/EFI/BOOT/BOOTAA64.EFI
cp -v /opt/limine-src/BOOTAA64.EFI /boot/efi/EFI/limine/BOOTAA64.EFI

# Registrazione NVRAM (se il firmware/QEMU la supporta); il path di fallback
# \\EFI\\BOOT\\BOOTAA64.EFI resta comunque valido anche se questo fallisce.
efibootmgr --create --disk "${DISK_DEV}" --part "${EFI_PART_NUM}" \
  --loader '\EFI\limine\BOOTAA64.EFI' --label 'Limine' 2>/dev/null || true

# --- limine.conf con i marcatori per la sync degli snapshot (stesso schema
#     già validato nella ricetta: un rigeneratore che riscrive SOLO la
#     sezione tra i marcatori non deve mai far sparire i marcatori stessi).
KVER="\$(cd /boot && ls vmlinuz-* 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -1)"
mkdir -p /boot/efi/kernels
if [ -n "\$KVER" ]; then
  cp -v "/boot/vmlinuz-\$KVER" "/boot/efi/kernels/vmlinuz-\$KVER"
  cp -v "/boot/initrd.img-\$KVER" "/boot/efi/kernels/initrd.img-\$KVER"
fi

cat > /boot/efi/limine.conf <<LIMINECONFEOF
timeout: 5

/Ubuntu (ultimate)
    protocol: linux
    kernel_path: boot():/kernels/vmlinuz-\$KVER
    module_path: boot():/kernels/initrd.img-\$KVER
    cmdline: root=/dev/mapper/${LUKS_MAPPER_NAME} rootflags=subvol=@ rw quiet splash

#### LIMINE-SNAPSHOT-SYNC:BEGIN
#### LIMINE-SNAPSHOT-SYNC:END
LIMINECONFEOF

# --- hook di sincronizzazione kernel: copia vmlinuz/initrd sull'ESP ad ogni
#     aggiornamento kernel (equivalente Limine dello zz-limine-kernel-sync
#     già usato nella ricetta autoinstall per x86).
cat > /etc/kernel/postinst.d/zz-limine-kernel-sync <<'HOOKEOF'
#!/bin/sh
set -e
KVER="\$1"
ESP=/boot/efi
mkdir -p "\$ESP/kernels"
[ -f "/boot/vmlinuz-\$KVER" ] && cp -f "/boot/vmlinuz-\$KVER" "\$ESP/kernels/vmlinuz-\$KVER"
[ -f "/boot/initrd.img-\$KVER" ] && cp -f "/boot/initrd.img-\$KVER" "\$ESP/kernels/initrd.img-\$KVER"
# aggiorna solo la entry principale (kernel_path/module_path), preservando
# tutto il resto del file inclusi i marcatori degli snapshot
sed -i "s#kernel_path: boot():/kernels/vmlinuz-.*#kernel_path: boot():/kernels/vmlinuz-\$KVER#" "\$ESP/limine.conf"
sed -i "s#module_path: boot():/kernels/initrd.img-.*#module_path: boot():/kernels/initrd.img-\$KVER#" "\$ESP/limine.conf"
HOOKEOF
chmod +x /etc/kernel/postinst.d/zz-limine-kernel-sync

# --- script di sync degli snapshot BTRFS nel menu Limine: rigenera SOLO il
#     blocco tra i marcatori, leggendo gli snapshot reali da Snapper. Il
#     boot di uno snapshot riusa lo stesso vmlinuz/initrd correnti sull'ESP,
#     cambiando solo rootflags=subvol=... (stesso principio di grub-btrfsd,
#     adattato a Limine che non ha un demone equivalente nativo).
# NOTA sull'escaping: questo blocco genera uno SCRIPT DENTRO ALLO SCRIPT (il
# chroot-setup è già a sua volta generato dallo script principale sull'host).
# Per non impazzire con livelli multipli di backslash, il delimitatore qui è
# QUOTATO ('SYNCEOF'): il chroot-script scrive il contenuto byte-per-byte,
# senza rivalutare nulla. Le variabili con un \$ singolo sono quindi quelle
# che devono restare LETTERALI nel file finale e venire valutate solo quando
# /usr/local/bin/limine-snapshot-sync gira per davvero (ESP, CONF, TMP, KVER
# ricalcolato ad ogni esecuzione, num, desc). Nessuna continuazione di riga
# con backslash: un heredoc annidato "mangia" backslash-newline anche se
# quotato più esternamente, quindi ogni pipeline sta su una riga sola.
cat > /usr/local/bin/limine-snapshot-sync <<'SYNCEOF'
#!/usr/bin/env bash
set -euo pipefail
ESP=/boot/efi
CONF="$ESP/limine.conf"
KVER="$(cd /boot && ls vmlinuz-* 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -1)"

TMP="$(mktemp)"
awk '/#### LIMINE-SNAPSHOT-SYNC:BEGIN/{print;f=1;next} /#### LIMINE-SNAPSHOT-SYNC:END/{f=0} !f' "$CONF" > "$TMP"

{
  echo "#### LIMINE-SNAPSHOT-SYNC:BEGIN"
  echo "//+Snapshot root"
  if command -v snapper >/dev/null 2>&1; then
    snapper -c root list --columns number,date,description --disable-used-space 2>/dev/null | tail -n +3 | while IFS='|' read -r num date desc; do
      num="$(echo "$num" | tr -d ' ')"
      [ -z "$num" ] && continue
      cleandesc="$(echo "$desc" | sed 's/^ *//;s/ *$//')"
      echo "    //Snapshot #$num - $cleandesc"
      echo "        protocol: linux"
      echo "        kernel_path: boot():/kernels/vmlinuz-$KVER"
      echo "        module_path: boot():/kernels/initrd.img-$KVER"
      echo "        cmdline: root=/dev/mapper/LUKS_MAPPER_NAME_PLACEHOLDER rootflags=subvol=@snapshots/$num/snapshot rw"
    done
  fi
  echo "//+Snapshot home"
  if command -v snapper >/dev/null 2>&1; then
    snapper -c home list --columns number,date,description --disable-used-space 2>/dev/null | tail -n +3 | while IFS='|' read -r num date desc; do
      num="$(echo "$num" | tr -d ' ')"
      [ -z "$num" ] && continue
      cleandesc="$(echo "$desc" | sed 's/^ *//;s/ *$//')"
      echo "    //Snapshot home #$num - $cleandesc"
      echo "        protocol: linux"
      echo "        kernel_path: boot():/kernels/vmlinuz-$KVER"
      echo "        module_path: boot():/kernels/initrd.img-$KVER"
      echo "        cmdline: root=/dev/mapper/LUKS_MAPPER_NAME_PLACEHOLDER rootflags=subvol=@ rw"
    done
  fi
  echo "#### LIMINE-SNAPSHOT-SYNC:END"
} >> "$TMP"

mv "$TMP" "$CONF"
SYNCEOF
# LUKS_MAPPER_NAME è deciso all'avvio dello script principale (sull'host),
# quindi va iniettato con un sed dopo la scrittura quotata qui sopra, invece
# che con un'espansione dentro l'heredoc (che qui è volutamente quotato).
sed -i "s#LUKS_MAPPER_NAME_PLACEHOLDER#${LUKS_MAPPER_NAME}#g" /usr/local/bin/limine-snapshot-sync
chmod +x /usr/local/bin/limine-snapshot-sync
/usr/local/bin/limine-snapshot-sync || true

# --- timer che richiama la sync periodicamente (ogni 30 min) invece di un
#     vero demone inotify come grub-btrfsd: più semplice, sufficiente per
#     uno snapshot timeline orario, ed evita di scrivere un demone Python
#     apposta solo per questo.
cat > /etc/systemd/system/limine-snapshot-sync.service <<UNITEOF
[Unit]
Description=Sync BTRFS/Snapper snapshots into limine.conf

[Service]
Type=oneshot
ExecStart=/usr/local/bin/limine-snapshot-sync
UNITEOF

cat > /etc/systemd/system/limine-snapshot-sync.timer <<TIMEREOF
[Unit]
Description=Periodic Limine snapshot menu sync

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
TIMEREOF

systemctl enable limine-snapshot-sync.timer 2>/dev/null || true

# root resta bloccato (nessuna password impostata): l'accesso amministrativo
# passa solo dall'utente creato sopra via sudo, non da un login root diretto.
passwd -l root || true
CHROOTEOF
  chmod +x "$TARGET_MNT/root/ultimate-chroot-setup.sh"
}

run_chroot_script() {
  log_info "Eseguo la configurazione dentro il chroot..."
  chroot "$TARGET_MNT" /root/ultimate-chroot-setup.sh
  rm -f "$TARGET_MNT/root/ultimate-chroot-setup.sh"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  require_root "$@"
  check_environment
  install_host_dependencies

  list_partitions
  EFI_PART="$(choose_partition "Scegli la partizione da usare come ESP (EFI System Partition, FAT32):")"
  LUKS_PART="$(choose_partition "Scegli la partizione su cui installare LUKS2+BTRFS:" "$EFI_PART")"

  DISK_DEV="/dev/$(lsblk -rno PKNAME "$EFI_PART")"
  EFI_PART_NUM="$(lsblk -rno NAME "$EFI_PART" | sed -E 's/^.*[a-z]([0-9]+)$/\1/')"

  prompt_user_details
  FORMAT_ESP=0
  confirm_summary

  setup_esp
  setup_luks_btrfs
  run_debootstrap
  write_fstab_crypttab
  prepare_chroot_binds
  write_chroot_script
  run_chroot_script

  log_info "Smontaggio..."
  for ((i = ${#MOUNTED_STACK[@]} - 1; i >= 0; i--)); do
    umount -R "${MOUNTED_STACK[$i]}" 2>/dev/null || true
  done
  cryptsetup close "$LUKS_MAPPER_NAME"
  rm -rf "$WORKDIR"
  trap - EXIT

  log_info "Fatto. Rimuovi il supporto live e riavvia per testare Limine + LUKS2 + BTRFS + Snapper."
  log_warn "Ricorda: TPM2 autounlock, Howdy, USBGuard, desktop/tema, iCloud, ecc. NON sono in questo script — sono gli script standalone numerati del repo ubuntu-ultimate, da eseguire dopo il primo boot."
}

main "$@"
