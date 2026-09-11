#!/usr/bin/env bash
# 16-install-apfs-fuse.sh — compila e installa apfs-fuse (driver FUSE per
# APFS, SOLA LETTURA) su un sistema già installato e in esecuzione (VM di
# test inclusa). Versione standalone dello stesso blocco presente in
# disk-setup/autoinstall.yaml.tpl e live-iso/chroot-customize.sh.
#
# Perché sola lettura: è una scelta del progetto upstream stesso
# (sgan81/apfs-fuse), non nostra — niente scrittura, quindi nessun rischio
# di corrompere un disco Mac collegato per errore. Il supporto in scrittura
# esiste solo come modulo kernel sperimentale fuori-albero (linux-apfs-rw),
# che richiederebbe DKMS + firma del modulo per Secure Boot (enrollment MOK
# interattivo al riavvio): troppo fragile/manuale per uno script
# automatico, non lo installiamo qui.
#
# Uso: ./16-install-apfs-fuse.sh
# Poi:  apfs-fuse <device> <mountpoint>   (es. apfs-fuse /dev/sdb2 /mnt/mac)

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user

if command -v apfs-fuse >/dev/null 2>&1; then
    log_warn "apfs-fuse già installato ($(command -v apfs-fuse)), salto la compilazione."
else

log_info "Installo le dipendenze di build..."
# Il README ufficiale del progetto elenca "gcc-c++" tra i pacchetti
# Debian/Ubuntu: è il nome usato da Fedora/RHEL, su Ubuntu non esiste
# (verificato su packages.ubuntu.com) — il pacchetto giusto è "g++".
sudo apt-get install -y fuse3 libfuse3-dev bzip2 libbz2-dev cmake g++ libattr1-dev zlib1g-dev git

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

log_info "Clono apfs-fuse (con il sottomodulo lzfse di Apple)..."
git clone https://github.com/sgan81/apfs-fuse.git "${BUILD_DIR}/apfs-fuse"
(cd "${BUILD_DIR}/apfs-fuse" && git submodule init && git submodule update)

# ApfsLib/PList.h usa uint8_t/uint32_t senza includere <cstdint>: con GCC
# 15 (Ubuntu 26.04) non arriva più per inclusione transitiva da <memory>,
# la compilazione fallisce con "'uint8_t' does not name a type" — errore
# reale riscontrato in VM, lo stesso messaggio del compilatore suggerisce
# il fix.
sed -i '1i #include <cstdint>' "${BUILD_DIR}/apfs-fuse/ApfsLib/PList.h"

log_info "Compilo (cmake + make)..."
mkdir -p "${BUILD_DIR}/apfs-fuse/build"
(
    cd "${BUILD_DIR}/apfs-fuse/build"
    # -DCMAKE_POLICY_VERSION_MINIMUM=3.5: il CMakeLists.txt di apfs-fuse
    # (e/o del sottomodulo lzfse) dichiara "cmake_minimum_required" con una
    # versione troppo vecchia per il cmake moderno di Ubuntu 26.04 (>= 4.0
    # ha rimosso la compatibilità con < 3.5) — errore reale riscontrato in
    # VM, risolto con il flag suggerito dallo stesso messaggio d'errore.
    cmake .. -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    make -j"$(nproc)"
    sudo make install
)

log_ok "apfs-fuse installato in $(command -v apfs-fuse). Uso: apfs-fuse <device> <mountpoint>"
log_warn "Sola lettura: nessuna scrittura sul disco APFS montato."

fi

# --- Integrazione con Nautilus/udisks2 --------------------------------------
# apfs-fuse da solo funziona benissimo da riga di comando, ma Nautilus non
# lo sa: quando riconosce una partizione APFS (via blkid) prova ad
# automontarla con "mount -t apfs", che fallisce perché non esiste nessun
# driver APFS nel kernel — l'errore "filesystem apfs non configurato nel
# kernel" che si vede da Nautilus. La soluzione è lo stesso meccanismo con
# cui ntfs-3g/exfat-fuse si integrano con mount(8) senza bisogno di
# supporto kernel dedicato: un helper esterno "/sbin/mount.apfs" che
# mount(8) (e quindi udisks2/Nautilus) esegue automaticamente al posto del
# driver kernel inesistente. Sintassi imposta da mount(8) stesso (man
# mount, sezione "EXTERNAL HELPERS"):
#   /sbin/mount.apfs spec dir [-sfnv] [-N namespace] [-o options] [-t type.subtype]
# Le opzioni booleane (-s -f -n -v) e -N/-t vengono ignorate: non hanno
# equivalente sensato per un mount FUSE in sola lettura. Solo -o (uid=,
# gid=, ro, nosuid, nodev, ecc. — tutte riconosciute nativamente da
# libfuse) viene passato a apfs-fuse.
log_info "Installo l'helper /sbin/mount.apfs per l'integrazione con Nautilus/udisks2..."
APFS_FUSE_BIN="$(command -v apfs-fuse)"
sudo tee /sbin/mount.apfs >/dev/null <<MOUNTAPFSEOF
#!/bin/bash
set -euo pipefail
SPEC="\$1"
DIR="\$2"
shift 2
OPTS=""
while getopts ":sfnvN:o:t:" opt; do
    case "\$opt" in
        o) OPTS="\$OPTARG" ;;
        *) ;;
    esac
done

# udisks2 passa a questo helper TUTTE le opzioni di mount, incluse quelle
# specifiche sue (es. "uhelper=udisks2") o generiche del VFS
# (nodev/nosuid/noexec/relatime/...) senza sapere che la destinazione è
# un filesystem FUSE: libfuse (usata da apfs-fuse) rifiuta con "fuse:
# unknown option(s)" qualsiasi opzione che non riconosce — errore reale
# riscontrato in VM ("fuse: unknown option(s): \`-o uhelper=udisks2'").
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
IFS=',' read -ra OPT_ARR <<< "\${OPTS}"
for o in "\${OPT_ARR[@]}"; do
    case "\$o" in
        ro|rw|uid=*|gid=*|nonempty)
            FILTERED="\${FILTERED},\${o}"
            ;;
        *) ;;
    esac
done

exec ${APFS_FUSE_BIN} -o "\${FILTERED}" "\${SPEC}" "\${DIR}"
MOUNTAPFSEOF
sudo chmod 755 /sbin/mount.apfs

log_ok "Helper installato: /sbin/mount.apfs. Prova ora a montare il disco da Nautilus (o scollega/ricollega il case USB)."
