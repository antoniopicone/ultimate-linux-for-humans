#!/usr/bin/env bash
# prepare-autoinstall.sh — genera un autoinstall.yaml pronto all'uso a
# partire dal template, chiedendo interattivamente hostname, username,
# password utente e passphrase LUKS.
#
# Uso: ./prepare-autoinstall.sh
#
# Il file finisce in disk-setup/autoinstall.yaml (accanto a questo script:
# è dove create-test-vm.sh se lo aspetta di default, e dove punta il
# metodo "server HTTP locale" del README). Contiene la passphrase LUKS in
# chiaro: permessi impostati a 600 e riga aggiunta a .gitignore, ma resta
# un segreto — non condividerlo, cancellalo quando hai finito i test.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

command -v mkpasswd >/dev/null 2>&1 || {
    echo "mkpasswd non trovato: installo il pacchetto 'whois' (lo fornisce)."
    sudo apt install -y whois
}

read -rp "Hostname della macchina [ubuntu-ultimate]: " HOSTNAME
HOSTNAME="${HOSTNAME:-ubuntu-ultimate}"

CURRENT_USER="$(whoami)"
read -rp "Username [${CURRENT_USER}]: " USERNAME
USERNAME="${USERNAME:-${CURRENT_USER}}"
while [[ -z "${USERNAME}" ]]; do
    read -rp "Username (obbligatorio): " USERNAME
done

# Nome e Cognome: va nel campo GECOS dell'utente (identity.realname
# nell'autoinstall di Subiquity), che GDM mostra nella schermata di login al
# posto dello username quando è valorizzato. Riusato anche come "user.name"
# di git più sotto, per non chiederlo due volte.
read -rp "Nome e Cognome completo (mostrato da GDM al posto dello username): " FULLNAME
while [[ -z "${FULLNAME}" ]]; do
    read -rp "Nome e Cognome (obbligatorio): " FULLNAME
done

read -rp "Email per la configurazione globale di git: " GIT_EMAIL
while [[ -z "${GIT_EMAIL}" ]]; do
    read -rp "Email per git (obbligatoria): " GIT_EMAIL
done

read -rsp "Password per l'utente ${USERNAME}: " USER_PASSWORD
echo
read -rsp "Ripeti la password: " USER_PASSWORD_CONFIRM
echo
if [[ "${USER_PASSWORD}" != "${USER_PASSWORD_CONFIRM}" ]]; then
    echo "Le due password non coincidono." >&2
    exit 1
fi

read -rsp "Passphrase LUKS2 per il disco: " LUKS_PASSPHRASE
echo
read -rsp "Ripeti la passphrase LUKS2: " LUKS_PASSPHRASE_CONFIRM
echo
if [[ "${LUKS_PASSPHRASE}" != "${LUKS_PASSPHRASE_CONFIRM}" ]]; then
    echo "Le due passphrase non coincidono." >&2
    exit 1
fi

# Opzionale, a differenza di password/passphrase: se lasciata vuota, il
# pacchetto Tailscale viene comunque installato ma non attivato (vedi
# ubuntu-ultimate-tailscale-up.service nel .tpl) — nessun errore, va solo
# lanciato "sudo tailscale up" a mano quando si vuole collegarlo.
read -rsp "Auth key Tailscale (opzionale, invio per saltare): " TAILSCALE_AUTHKEY
echo

USER_PASSWORD_HASH="$(mkpasswd -m sha-512 "${USER_PASSWORD}")"

OUT_FILE="${SCRIPT_DIR}/autoinstall.yaml"

sed \
    -e "s|__HOSTNAME__|${HOSTNAME}|g" \
    -e "s|__USERNAME__|${USERNAME}|g" \
    -e "s|__REALNAME__|${FULLNAME}|g" \
    -e "s|__GIT_EMAIL__|${GIT_EMAIL}|g" \
    -e "s|__USER_PASSWORD_HASH__|${USER_PASSWORD_HASH}|g" \
    -e "s|__LUKS_PASSPHRASE__|${LUKS_PASSPHRASE}|g" \
    -e "s|__TAILSCALE_AUTHKEY__|${TAILSCALE_AUTHKEY}|g" \
    "${SCRIPT_DIR}/autoinstall.yaml.tpl" > "${OUT_FILE}"
chmod 600 "${OUT_FILE}"

HAD_TAILSCALE_AUTHKEY=0
[[ -n "${TAILSCALE_AUTHKEY}" ]] && HAD_TAILSCALE_AUTHKEY=1

unset USER_PASSWORD USER_PASSWORD_CONFIRM LUKS_PASSPHRASE LUKS_PASSPHRASE_CONFIRM TAILSCALE_AUTHKEY

# Assicura che il file coi segreti non finisca mai in git per sbaglio.
GITIGNORE="${SCRIPT_DIR}/../.gitignore"
touch "${GITIGNORE}"
grep -qxF 'disk-setup/autoinstall.yaml' "${GITIGNORE}" || echo 'disk-setup/autoinstall.yaml' >> "${GITIGNORE}"

echo
echo "Generato: ${OUT_FILE} (permessi 600)"
if [[ "${HAD_TAILSCALE_AUTHKEY}" -eq 1 ]]; then
    echo "Contiene la passphrase LUKS, l'hash della password e la auth key"
    echo "Tailscale: trattalo come un segreto, non condividerlo, cancellalo"
    echo "quando hai finito i test."
else
    echo "Contiene la passphrase LUKS e l'hash della password: trattalo come"
    echo "un segreto, non condividerlo, cancellalo quando hai finito i test."
    echo "(nessuna auth key Tailscale: il pacchetto verrà installato ma non"
    echo "attivato — lancia 'sudo tailscale up' a mano quando vuoi)."
fi
echo
echo "Prossimo passo:"
echo "  cd ../test-vm && ./create-test-vm.sh"
echo "(usa automaticamente ../disk-setup/autoinstall.yaml)"
