#!/usr/bin/env bash
# 18-limine-snapshot-sync.sh — aggiunge al menu di Limine (vedi
# 17-install-limine.sh, va eseguito PRIMA di questo) le voci per avviare
# direttamente uno snapshot BTRFS/snapper precedente, la stessa cosa che
# grub-btrfs fa già per GRUB in questa ricetta.
#
# IMPORTANTE — perché questa NON è un porting di "limine-snapper-sync":
# la versione attuale di quel progetto (github/gitlab: Zesko/limine-snapper-sync,
# usato da CachyOS) è scritta in Java e compilata con GraalVM nativeCompile,
# e si appoggia a pacchetti Arch-specifici (limine-mkinitcpio-hook,
# hook pacman) che su Ubuntu non esistono. Portarlo davvero richiederebbe
# la toolchain gradle+GraalVM (pesante e fragile in un autoinstall/VM di
# test) più la riscrittura degli hook per initramfs-tools/apt. Invece di
# questo, reimplementiamo qui lo stesso RISULTATO per l'utente (voci di
# boot per gli snapshot nel menu di Limine) con un piccolo script bash +
# inotifywait, esattamente lo stesso meccanismo (demone + watch su
# /.snapshots) già usato da grub-btrfs/grub-btrfsd in questa stessa
# ricetta per GRUB — nessuna toolchain aggiuntiva, coerente col resto del
# progetto.
#
# Layout presupposto (lo stesso di 17-install-limine.sh): @snapshots è un
# subvolume BTRFS di primo livello (fratello di @, non annidato dentro),
# montato su /.snapshots — Snapper vi crea i suoi snapshot numerati come
# /.snapshots/<N>/snapshot, che quindi (visti dalla radice del filesystem
# BTRFS, subvolid 5) hanno percorso "@snapshots/<N>/snapshot": è questo il
# valore da usare in rootflags=subvol= per avviare quello snapshot.
#
# Uso: ./18-limine-snapshot-sync.sh (richiede che 17-install-limine.sh sia
# già stato eseguito con successo)

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user

LIMINE_CONF="/boot/efi/EFI/limine/limine.conf"
# L'ESP di questa ricetta è montata con fmask/dmask=0077 (nessun uid=/gid=):
# /boot/efi/EFI/limine/ è leggibile SOLO da root, quindi ogni accesso al file
# da qui in avanti (finché siamo nella parte "utente normale" dello script)
# deve passare da sudo, altrimenti "[[ -f ... ]]"/"grep" falliscono per
# permessi e sembra (erroneamente) che il file non esista.
if ! sudo test -f "${LIMINE_CONF}"; then
    log_err "${LIMINE_CONF} non trovato: esegui prima 17-install-limine.sh."
    exit 1
fi
if ! sudo grep -q '^/Ubuntu Ultimate$' "${LIMINE_CONF}"; then
    log_err "${LIMINE_CONF} non sembra generato da 17-install-limine.sh (manca la entry '/Ubuntu Ultimate')."
    exit 1
fi

if ! mountpoint -q /.snapshots; then
    log_err "/.snapshots non è un mountpoint: questo script si aspetta il subvolume @snapshots di questa ricetta."
    exit 1
fi

sudo apt-get install -y inotify-tools

# --- 1. Prepara i marcatori nel limine.conf esistente, se non già presenti -

if ! sudo grep -q '^#### LIMINE-SNAPSHOT-SYNC:BEGIN' "${LIMINE_CONF}"; then
    log_info "Aggiungo i marcatori per le voci snapshot a ${LIMINE_CONF}..."
    printf '\n#### LIMINE-SNAPSHOT-SYNC:BEGIN (generato automaticamente da limine-snapshot-sync, non modificare a mano)\n#### LIMINE-SNAPSHOT-SYNC:END\n' \
        | sudo tee -a "${LIMINE_CONF}" >/dev/null
fi

# --- 2. Lo script generatore, installato di sistema -------------------------
# Rilegge da capo crypttab/subvolume/kernel a ogni esecuzione (non da un file
# di config separato): niente da tenere sincronizzato manualmente se cambia
# il kernel o la configurazione LUKS.

sudo tee /usr/local/bin/limine-snapshot-sync >/dev/null <<'SYNCEOF'
#!/usr/bin/env bash
# Rigenera SOLO il blocco tra i marcatori LIMINE-SNAPSHOT-SYNC in
# /boot/efi/EFI/limine/limine.conf con una voce di boot per ogni snapshot
# presente in /.snapshots/<N>/snapshot. Installato da 18-limine-snapshot-sync.sh
# — non modificarlo a mano, verrebbe sovrascritto alla prossima esecuzione
# di quello script.
#
# Kernel/initrd: Limine non legge ext4 (vedi i commenti in
# 17-install-limine.sh), quindi anche le voci snapshot puntano alla copia su
# ESP mantenuta da limine-kernel-sync — le richiamiamo qui prima di generare
# il blocco, per essere sicuri che sia allineata all'ultimo kernel anche se
# nel frattempo è stato installato un aggiornamento.
set -euo pipefail

LIMINE_CONF="/boot/efi/EFI/limine/limine.conf"
BOOT_MOUNT="/boot"
SNAPSHOTS_DIR="/.snapshots"

[[ -f "${LIMINE_CONF}" ]] || exit 0
grep -q '^#### LIMINE-SNAPSHOT-SYNC:BEGIN' "${LIMINE_CONF}" || exit 0

command -v limine-kernel-sync >/dev/null 2>&1 && limine-kernel-sync || true

CRYPTTAB_LINE="$(grep -vE '^\s*#|^\s*$' /etc/crypttab | head -n1)"
CRYPT_NAME="$(awk '{print $1}' <<< "${CRYPTTAB_LINE}")"
CRYPT_SOURCE="$(awk '{print $2}' <<< "${CRYPTTAB_LINE}")"

KERNEL_FILE="$(basename "$(readlink -f "${BOOT_MOUNT}/vmlinuz")")"
INITRD_FILE="$(basename "$(readlink -f "${BOOT_MOUNT}/initrd.img")")"

BLOCK="$(mktemp)"
trap 'rm -f "${BLOCK}"' EXIT

# Vista ad albero: una directory "/+Snapshots" (il "+" la tiene espansa di
# default nel menu, sintassi da CONFIG.md/test/limine.conf ufficiale) che
# contiene una sotto-voce ("//", due slash = un livello di profondità) per
# ogni snapshot. Se non c'è nessuno snapshot, la directory non viene proprio
# emessa (niente entry vuota nel menu).
NUM_SNAPSHOTS=0
if [[ -d "${SNAPSHOTS_DIR}" ]]; then
    # Ordina per NOME della directory (il numero di snapshot), non per il
    # path completo: affidarsi a "sort -t/ -kN" sul path intero si rompe se
    # SNAPSHOTS_DIR ha una profondità diversa da quella attesa. Più recente
    # per primo nel menu.
    for n in $(find "${SNAPSHOTS_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E '^[0-9]+$' | sort -rn); do
        n_dir="${SNAPSHOTS_DIR}/${n}"
        [[ -d "${n_dir}/snapshot" ]] || continue

        if [[ "${NUM_SNAPSHOTS}" -eq 0 ]]; then
            {
                echo ""
                echo "/+Snapshots"
                echo "    comment: Avvia un'istantanea BTRFS/Snapper precedente della root."
                echo ""
            } >> "${BLOCK}"
        fi
        NUM_SNAPSHOTS=$((NUM_SNAPSHOTS + 1))

        desc=""
        if [[ -f "${n_dir}/info.xml" ]]; then
            desc="$(sed -n 's/.*<description>\(.*\)<\/description>.*/\1/p' "${n_dir}/info.xml" | head -n1)"
        fi
        label="Snapshot #${n}"
        [[ -n "${desc}" ]] && label="Snapshot #${n} — ${desc}"

        {
            echo "    //${label}"
            echo "        protocol: linux"
            echo "        kernel_path: boot():/limine-kernels/${KERNEL_FILE}"
            echo "        module_path: boot():/limine-kernels/${INITRD_FILE}"
            echo "        kernel_cmdline: root=/dev/mapper/${CRYPT_NAME} rootflags=subvol=@snapshots/${n}/snapshot rootfstype=btrfs cryptdevice=${CRYPT_SOURCE}:${CRYPT_NAME} rw"
            echo ""
        } >> "${BLOCK}"
    done
fi

# Sostituisce tutto ciò che sta tra i due marcatori (marcatori inclusi) con:
# marcatore-begin + contenuto rigenerato + marcatore-end.
awk -v blockfile="${BLOCK}" '
    /^#### LIMINE-SNAPSHOT-SYNC:BEGIN/ {
        print
        while ((getline line < blockfile) > 0) print line
        skip = 1
        next
    }
    /^#### LIMINE-SNAPSHOT-SYNC:END/ { skip = 0 }
    skip { next }
    { print }
' "${LIMINE_CONF}" > "${LIMINE_CONF}.new"
mv "${LIMINE_CONF}.new" "${LIMINE_CONF}"
SYNCEOF
sudo chmod 755 /usr/local/bin/limine-snapshot-sync

log_ok "Script generatore installato in /usr/local/bin/limine-snapshot-sync"

# --- 3. Demone di watch (systemd, inotifywait) ------------------------------
# Stesso principio di grub-btrfsd (già nella ricetta per GRUB): resta in
# ascolto sulle directory degli snapshot e rigenera la configurazione a ogni
# creazione/cancellazione, senza bisogno di timer/polling.

sudo tee /usr/local/bin/limine-snapshot-sync-watch >/dev/null <<'WATCHEOF'
#!/usr/bin/env bash
set -euo pipefail
/usr/local/bin/limine-snapshot-sync
exec inotifywait -m -e create -e delete -e moved_to -e moved_from -r /.snapshots 2>/dev/null | \
while read -r _; do
    /usr/local/bin/limine-snapshot-sync || true
done
WATCHEOF
sudo chmod 755 /usr/local/bin/limine-snapshot-sync-watch

sudo tee /etc/systemd/system/limine-snapshot-sync.service >/dev/null <<'UNITEOF'
[Unit]
Description=Rigenera le voci snapshot di Limine da /.snapshots (equivalente locale di grub-btrfsd, per Limine)
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/local/bin/limine-snapshot-sync-watch
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNITEOF

sudo systemctl daemon-reload
sudo systemctl enable --now limine-snapshot-sync.service

log_ok "Servizio limine-snapshot-sync.service abilitato e avviato."
log_info "Rigenerata subito la configurazione con gli snapshot esistenti."
log_warn "Non ancora testato un boot reale da uno snapshot generato così: verifica riavviando e scegliendo una voce 'Snapshot #N' dal menu di Limine."
