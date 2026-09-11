#!/usr/bin/env bash
# verify-test-vm.sh — dopo che la VM di prova si è riavviata nel sistema
# appena installato, controlla via SSH che il layout BTRFS-su-LUKS2 sia
# davvero quello atteso.
#
# Uso: ./verify-test-vm.sh [nome-vm] <username>

set -euo pipefail

VM_NAME="${1:-ubuntu-ultimate-test}"
USERNAME="${2:?Uso: ./verify-test-vm.sh [nome-vm] <username>}"

echo "Cerco l'indirizzo IP di ${VM_NAME}..."
IP="$(virsh domifaddr "${VM_NAME}" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -n1)"

if [[ -z "${IP}" ]]; then
    echo "Impossibile trovare un IP per '${VM_NAME}'." >&2
    echo "La VM è avviata ed è già arrivata al desktop dopo aver sbloccato LUKS?" >&2
    echo "(la passphrase va inserita a mano dalla console: virt-viewer ${VM_NAME})" >&2
    exit 1
fi

echo "IP trovato: ${IP}. Mi collego via SSH come ${USERNAME}..."
ssh -o StrictHostKeyChecking=accept-new "${USERNAME}@${IP}" '
    set -x
    echo "--- mount point (ext4/btrfs/vfat) ---"
    findmnt -t btrfs,ext4,vfat

    echo "--- subvolume BTRFS su / ---"
    sudo btrfs subvolume list /

    echo "--- /etc/crypttab ---"
    cat /etc/crypttab

    echo "--- lsblk ---"
    lsblk -f

    echo "--- riga di comando kernel (deve contenere rootflags=subvol=@) ---"
    cat /proc/cmdline
'

echo
echo "Controlla sopra che compaiano: / con subvol=@, /home con subvol=@home,"
echo "/var con subvol=@var, /.snapshots con subvol=@snapshots, /boot come"
echo "ext4 separato e /boot/efi come vfat. Se torna tutto, il layout disco"
echo "è validato: possiamo passare agli step successivi della ricetta."
