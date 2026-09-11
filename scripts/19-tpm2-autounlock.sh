#!/usr/bin/env bash
# 19-tpm2-autounlock.sh — abilita lo sblocco automatico della root LUKS2 via
# TPM2 (nessuna password richiesta al boot), sostituendo initramfs-tools con
# dracut. Pensato per un sistema già installato con il layout di questa
# ricetta (ESP -> /boot ext4 -> LUKS2 -> BTRFS), eseguito DOPO
# 17-install-limine.sh (li richiama entrambi a fine esecuzione per
# rigenerare cmdline/copie sull'ESP con i nuovi parametri).
#
# PERCHÉ dracut e non "tpm2-device=auto" in /etc/crypttab con
# initramfs-tools: il hook cryptsetup-initramfs di Ubuntu NON supporta
# quell'opzione (bug Ubuntu #1980018, mai risolto: l'hook la ignora e torna
# a chiedere la password). Un ingegnere Canonical ha commentato quel bug
# dicendo che uno sblocco solo-TPM senza un initramfs "misurato" è
# considerato insicuro dal team sicurezza di Ubuntu — la soluzione "vera" di
# Canonical (Unified Kernel Image + Secure Boot obbligatorio) arriva da
# Ubuntu 25.10 in poi ed è incompatibile con Limine (nessun supporto Secure
# Boot). dracut ha supporto TPM2 nativo, ed è ufficialmente supportato in
# parallelo a initramfs-tools su Ubuntu 26.04 (diventerà il default da
# 25.10, initramfs-tools passa a universe da 26.10): non è un hack, ma
# comporta comunque un cambio di generatore di initramfs per l'intero
# sistema — leggi bene gli avvisi che questo script stampa prima di
# procedere.
#
# QUALE PROTEZIONE OFFRE REALMENTE (importante, senza Secure Boot): questa
# ricetta ha DUE bootloader (GRUB e Limine), ma lo sblocco automatico è
# pensato per funzionare SOLO avviando da Limine (il percorso di uso
# quotidiano) — usiamo PCR 0 (firmware) + PCR 4 (codice del bootloader).
# PCR 4 è interessante perché a estenderlo è il FIRMWARE stesso, non il
# bootloader: succede per specifica UEFI ogni volta che viene caricato un
# file eseguibile di boot, indipendentemente dal fatto che Limine non sappia
# nulla di TPM (confermato: nessun modulo PCR nel sorgente di Limine,
# discussione dei maintainer di fwupd) — quindi cattura comunque "è stato
# caricato esattamente questo BOOTX64.EFI, byte per byte", una vera
# protezione contro un binario Limine sostituito/manomesso sull'ESP.
# EFFETTO COLLATERALE VOLUTO: avviando da GRUB (rimasto solo come "break
# glass" di riserva) il valore di PCR 4 sarà diverso (misura il grubx64.efi
# di shim, non Limine), quindi lì lo sblocco automatico NON scatterà e verrà
# chiesta la password — esattamente il comportamento di oggi, nessuna
# regressione sul percorso di riserva. Con Secure Boot disattivo, PCR 7
# resta un valore fisso ("Secure Boot disabilitato"), non specifico del
# boot, quindi non lo usiamo. Conclusione onesta sul resto: questo sblocco
# protegge dal FURTO DEL DISCO (il segreto resta legato a QUESTO chip TPM)
# e da un BOOTLOADER SOSTITUITO (PCR 4), ma NON da un kernel/initrd
# manomesso caricato dallo STESSO Limine invariato (Limine non misura cosa
# carica dopo di sé) — per quello servirebbe Secure Boot, incompatibile con
# Limine. La password/passphrase originale NON viene rimossa: resta sempre
# utilizzabile come fallback manuale se il TPM non sblocca (es. dopo un
# aggiornamento firmware che invalida PCR 0, o dopo aver ricompilato Limine
# con codice diverso, che invalida PCR 4 — non un semplice re-run dello
# script, che salta la build se il binario esiste già).
#
# Uso: ./19-tpm2-autounlock.sh

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user

log_warn "Questo script sostituisce il generatore di initramfs (initramfs-tools -> dracut) e abilita lo sblocco automatico del disco via TPM2."
log_warn "La password del disco NON viene rimossa: resta come sblocco manuale di riserva se il TPM non dovesse funzionare."
log_warn "Sblocco automatico attivo SOLO avviando da Limine (PCR 0+4); da GRUB verrà comunque chiesta la password, come oggi. Protezione reale: furto-disco + binario Limine sostituito, non manomissioni di kernel/initrd. Vedi i commenti in cima a questo script per i dettagli."
read -r -p "Procedere? [s/N] " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[sS]$ ]]; then
    log_info "Annullato, nessuna modifica effettuata."
    exit 0
fi

# --- 1. Verifica presenza di un TPM2 reale ----------------------------------

if [[ ! -e /dev/tpmrm0 && ! -e /dev/tpm0 ]]; then
    log_err "Nessun device TPM (/dev/tpmrm0 o /dev/tpm0) trovato. Se sei in una VM serve un vTPM 2.0 esplicitamente abilitato; su hardware reale controlla che il TPM sia attivo in firmware (spesso voce 'Security Chip'/'PTT'/'fTPM')."
    exit 1
fi

# --- 2. Individua la configurazione LUKS2 -----------------------------------

CRYPTTAB_LINE="$(grep -vE '^\s*#|^\s*$' /etc/crypttab | head -n1)"
if [[ -z "${CRYPTTAB_LINE}" ]]; then
    log_err "Nessuna riga valida trovata in /etc/crypttab: questo script si aspetta una root LUKS2 (vedi disk-setup/autoinstall.yaml.tpl)."
    exit 1
fi
CRYPT_NAME="$(awk '{print $1}' <<< "${CRYPTTAB_LINE}")"
CRYPT_SOURCE="$(awk '{print $2}' <<< "${CRYPTTAB_LINE}")"
CRYPT_UUID="${CRYPT_SOURCE#UUID=}"
if [[ "${CRYPT_SOURCE}" == "${CRYPT_UUID}" ]]; then
    log_err "La sorgente in /etc/crypttab (${CRYPT_SOURCE}) non è nel formato UUID=... atteso da questa ricetta."
    exit 1
fi
log_info "Volume LUKS2 rilevato da /etc/crypttab: mapper=${CRYPT_NAME} UUID=${CRYPT_UUID}"

LUKS_DEV="/dev/disk/by-uuid/${CRYPT_UUID}"
if [[ ! -e "${LUKS_DEV}" ]]; then
    log_err "${LUKS_DEV} non esiste: non riesco a risalire alla partizione LUKS2 dall'UUID di /etc/crypttab."
    exit 1
fi
LUKS_DEV="$(readlink -f "${LUKS_DEV}")"

if ! sudo cryptsetup isLuks --type luks2 "${LUKS_DEV}"; then
    log_err "${LUKS_DEV} non è un volume LUKS2 (systemd-cryptenroll richiede LUKS2, non LUKS1)."
    exit 1
fi
log_info "Confermato: ${LUKS_DEV} è LUKS2."

# --- 3. Installa dracut + tool TPM2, lascia cryptsetup-initramfs al suo posto
# ("dracut" ha una dipendenza "Conflicts: initramfs-tools", quindi apt lo
# rimuove da solo — cryptsetup-initramfs resta installato senza conflitti,
# dracut soddisfa la sua dipendenza alternativa "linux-initramfs-tool" e
# semplicemente non fa più nulla, vedi commenti sopra).

log_info "Installo dracut, tpm2-tools, systemd-cryptsetup (apt rimuoverà initramfs-tools: dracut lo sostituisce)..."
sudo apt-get update
sudo apt-get install -y dracut tpm2-tools systemd-cryptsetup

# --- 4. Rigenera l'initramfs di TUTTI i kernel installati con dracut --------
# L'hook di dracut in /etc/kernel/postinst.d si attiva solo per i PROSSIMI
# kernel installati/rimossi: quelli già presenti hanno ancora un initrd
# generato da initramfs-tools finché non li rigeneriamo esplicitamente qui.
#
# NON usiamo "dracut --regenerate-all": trovato un bug reale testando su
# hardware (Zenbook). Leggendo il sorgente di /usr/bin/dracut (pacchetto
# dracut-core), quando non gli si passa un file di output esplicito, dracut
# decide da sé dove scrivere con una catena di controlli sull'esistenza di
# /boot/vmlinuz-<versione>; se quel controllo fallisce per qualunque motivo
# (osservato in pratica, causa non isolata con certezza) l'ultima condizione
# che rimane vera in questo layout è "l'ESP è montata su /boot/efi", e dracut
# sceglie di scrivere in stile Boot Loader Specification dentro
# ${ESP}/<machine-id>/<versione>/initrd — una directory che qui non esiste e
# nessuno crea, quindi fallisce con "Can't write to .../<machine-id>/<versione>:
# ... does not exist". Il file /etc/kernel/postinst.d/dracut installato dal
# pacchetto (quello che gestirà i PROSSIMI aggiornamenti kernel) non soffre
# di questo problema perché passa SEMPRE un output esplicito
# (`dracut -q --force /boot/initrd.img-<versione> <versione>`, verificato
# leggendo il file reale nel pacchetto .deb) — replichiamo qui esattamente
# lo stesso comando invece di affidarci all'euristica automatica di
# "--regenerate-all", eliminando il problema alla radice per ogni kernel.

log_info "Rigenero l'initramfs di tutti i kernel installati con dracut (stesso comando esplicito usato dall'hook postinst di dracut, non --regenerate-all)..."
for kdir in /lib/modules/*/; do
    kver="$(basename "${kdir%/}")"
    [[ -f "${kdir}modules.dep" || -f "${kdir}modules.dep.bin" ]] || continue
    log_info "  -> ${kver}"
    sudo dracut -q --force "/boot/initrd.img-${kver}" "${kver}"
done

# --- 5. Abilita lo sblocco TPM2: enroll + crypttab --------------------------
# systemd-cryptenroll AGGIUNGE un nuovo keyslot sigillato al TPM: non tocca
# né rimuove il keyslot della password esistente, che resta sempre
# utilizzabile come fallback manuale.
#
# PCR scelti: 0 (firmware) + 4 (codice del bootloader, misurato dal
# FIRMWARE quando carica BOOTX64.EFI — non da Limine, che non sa nulla di
# TPM). Vedi i commenti in cima al file per il perché: questo sigillo
# sblocca SOLO avviando da Limine (il percorso quotidiano) e protegge anche
# contro un binario Limine sostituito sull'ESP. Avviando dal "break glass"
# GRUB, PCR 4 non combacia e verrà chiesta la password — comportamento
# voluto, nessuna regressione lì.

log_info "Richiedo la passphrase LUKS2 esistente per autorizzare l'aggiunta del nuovo keyslot TPM2..."
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+4 "${LUKS_DEV}"
log_ok "Keyslot TPM2 aggiunto (la passphrase originale resta valida come fallback; sblocco automatico solo avviando da Limine)."

CRYPTTAB_FILE=/etc/crypttab
if grep -q "tpm2-device=" "${CRYPTTAB_FILE}"; then
    log_warn "/etc/crypttab ha già un'opzione tpm2-device=, non la tocco."
else
    log_info "Aggiungo tpm2-device=auto alle opzioni di /etc/crypttab..."
    sudo cp "${CRYPTTAB_FILE}" "${CRYPTTAB_FILE}.bak-pre-tpm2"
    # Il 4° campo di crypttab sono le opzioni (es. "luks" o "luks,discard");
    # se il campo è vuoto o assente lo impostiamo, altrimenti accodiamo con
    # una virgola — gestito con awk per non rompere righe con spazi/tab
    # diversi.
    sudo awk -v name="${CRYPT_NAME}" '
        BEGIN { OFS="\t" }
        $1 == name {
            if (NF < 4 || $4 == "" || $4 == "-") {
                $4 = "tpm2-device=auto"
            } else {
                $4 = $4 ",tpm2-device=auto"
            }
        }
        { print }
    ' "${CRYPTTAB_FILE}" | sudo tee "${CRYPTTAB_FILE}.new" >/dev/null
    sudo mv "${CRYPTTAB_FILE}.new" "${CRYPTTAB_FILE}"
    log_ok "/etc/crypttab aggiornato (backup in ${CRYPTTAB_FILE}.bak-pre-tpm2)."
fi

# --- 6. Rigenera di nuovo l'initramfs (deve incorporare il nuovo crypttab) --
# Stesso comando esplicito della sezione 4 sopra (non "--regenerate-all"),
# per lo stesso motivo.

log_info "Rigenero di nuovo l'initramfs (deve includere l'opzione tpm2-device= appena aggiunta)..."
for kdir in /lib/modules/*/; do
    kver="$(basename "${kdir%/}")"
    [[ -f "${kdir}modules.dep" || -f "${kdir}modules.dep.bin" ]] || continue
    log_info "  -> ${kver}"
    sudo dracut -q --force "/boot/initrd.img-${kver}" "${kver}"
done

# --- 7. Aggiorna la cmdline di GRUB con rd.luks.uuid= -----------------------
# "cryptdevice=" (sintassi initramfs-tools) resta già nella cmdline di GRUB
# da quando questa ricetta ha configurato LUKS2 — aggiungiamo "rd.luks.uuid="
# (sintassi dracut) accanto, senza toccare il resto.

GRUB_DEFAULT=/etc/default/grub
if grep -q "rd.luks.uuid=${CRYPT_UUID}" "${GRUB_DEFAULT}"; then
    log_warn "${GRUB_DEFAULT} ha già rd.luks.uuid=${CRYPT_UUID}, non lo tocco."
else
    log_info "Aggiungo rd.luks.uuid=${CRYPT_UUID} a GRUB_CMDLINE_LINUX in ${GRUB_DEFAULT}..."
    sudo cp "${GRUB_DEFAULT}" "${GRUB_DEFAULT}.bak-pre-tpm2"
    sudo sed -i -E "s/^(GRUB_CMDLINE_LINUX=\")([^\"]*)(\")/\1\2 rd.luks.uuid=${CRYPT_UUID}\3/" "${GRUB_DEFAULT}"
    sudo update-grub
    log_ok "GRUB aggiornato."
fi

# --- 8. Riallinea Limine (cmdline con rd.luks.uuid= + copia kernel/initrd) --
# 17-install-limine.sh genera SEMPRE l'intera cmdline da capo (inclusa
# rd.luks.uuid=, dopo l'aggiornamento fatto insieme a questa funzionalità) e
# a fine esecuzione richiama da solo limine-snapshot-sync: rieseguirlo qui è
# il modo più semplice per propagare il cambiamento anche a limine.conf,
# oltre a ricopiare sull'ESP l'initrd appena rigenerato da dracut (altrimenti
# Limine continuerebbe a usare la vecchia copia generata da initramfs-tools).

if [[ -x "${SCRIPT_DIR}/17-install-limine.sh" ]]; then
    log_info "Rieseguo 17-install-limine.sh per aggiornare cmdline/copia kernel-initrd di Limine..."
    "${SCRIPT_DIR}/17-install-limine.sh"
else
    log_warn "17-install-limine.sh non trovato/eseguibile: se usi Limine, aggiorna manualmente limine.conf (rd.luks.uuid=${CRYPT_UUID}) e ricopia kernel/initrd sull'ESP con 'sudo limine-kernel-sync'."
fi

log_ok "Sblocco automatico via TPM2 configurato."
log_info "Riavvia per verificare: scegliendo Limine dal firmware, il sistema dovrebbe avviarsi senza chiedere la passphrase."
log_info "Scegliendo GRUB, invece, la password verrà comunque richiesta (voluto: PCR 4 misura un binario diverso, GRUB non è coperto da questo sblocco)."
log_warn "Se anche da Limine chiede comunque la password, inseriscila pure (il keyslot originale è intatto) e poi indaga con 'sudo journalctl -b -u systemd-cryptsetup@${CRYPT_NAME}.service' o riavviando in modalità recovery."
log_warn "Un aggiornamento firmware/BIOS invalida PCR 0, e una RICOMPILAZIONE di Limine (non un semplice re-run di 17-install-limine.sh, che salta la build se il binario esiste già) invalida PCR 4: in entrambi i casi va rifatto il passo di enroll."
