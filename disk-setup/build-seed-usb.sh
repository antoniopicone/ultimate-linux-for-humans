#!/usr/bin/env bash
# build-seed-usb.sh — costruisce la ISO "seed" (datasource NoCloud) da
# autoinstall.yaml e la scrive su una chiavetta USB, per installare su
# hardware reale senza dover editare i parametri di boot o allestire un
# server HTTP. È lo stesso identico meccanismo già validato in
# test-vm/create-test-vm.sh, solo scritto su una chiavetta fisica invece
# che montato come CD-ROM virtuale.
#
# Uso: ./build-seed-usb.sh /dev/sdX
#      (sostituisce TUTTO il contenuto della chiavetta indicata: va usata
#      una chiavetta vuota o di cui non ti importa il contenuto, DIVERSA
#      da quella con sopra l'ISO di Ubuntu)

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

require_normal_user

DEVICE="${1:?Uso: ./build-seed-usb.sh /dev/sdX (chiavetta USB vuota, diversa da quella con la ISO di Ubuntu)}"

if [[ ! -b "${DEVICE}" ]]; then
    log_err "${DEVICE} non è un device a blocchi. Controlla con 'lsblk' il nome giusto."
    exit 1
fi

AUTOINSTALL_FILE="${SCRIPT_DIR}/autoinstall.yaml"
if [[ ! -f "${AUTOINSTALL_FILE}" ]]; then
    log_err "Non trovo ${AUTOINSTALL_FILE}. Genera prima il file con: ./prepare-autoinstall.sh"
    exit 1
fi
if grep -qE '__(HOSTNAME|USERNAME|USER_PASSWORD_HASH|LUKS_PASSPHRASE)__' "${AUTOINSTALL_FILE}"; then
    log_err "${AUTOINSTALL_FILE} contiene ancora dei segnaposto non sostituiti, non lo uso."
    exit 1
fi

command -v cloud-localds >/dev/null 2>&1 || {
    log_info "Installo cloud-image-utils (fornisce cloud-localds)..."
    sudo apt install -y cloud-image-utils
}

log_warn "Questo cancellerà TUTTO il contenuto di ${DEVICE}."
lsblk "${DEVICE}"
read -rp "Confermi? Scrivi 'sì' per procedere: " CONFIRM
if [[ "${CONFIRM}" != "sì" && "${CONFIRM}" != "si" ]]; then
    log_info "Annullato."
    exit 0
fi

SEED_TMP="$(mktemp -d)"
SEED_ISO="${SEED_TMP}/seed.iso"
cp "${AUTOINSTALL_FILE}" "${SEED_TMP}/user-data"
cp "${SCRIPT_DIR}/meta-data" "${SEED_TMP}/meta-data"
cloud-localds "${SEED_ISO}" "${SEED_TMP}/user-data" "${SEED_TMP}/meta-data"

log_info "Scrivo la seed ISO su ${DEVICE}..."
sudo dd if="${SEED_ISO}" of="${DEVICE}" bs=4M status=progress conv=fsync
sync
rm -rf "${SEED_TMP}"

log_ok "Fatto. Avvia la macchina con questa chiavetta inserita insieme a"
log_ok "quella con l'ISO di Ubuntu 26.04: Subiquity trova da solo il"
log_ok "datasource 'nocloud' (etichetta CIDATA), niente da configurare al boot."
