#!/usr/bin/env bash
# create-test-vm.sh — crea (e avvia l'installazione unattended su) una VM
# KVM per validare disk-setup/autoinstall.yaml prima di toccare hardware
# reale.
#
# Prerequisiti:
#   - aver lanciato 00-enable-virtualization.sh (e aver rifatto login)
#   - aver generato ../disk-setup/autoinstall.yaml con
#     ../disk-setup/prepare-autoinstall.sh
#
# Uso: ./create-test-vm.sh [percorso/a/autoinstall.yaml]
#      (default: ../disk-setup/autoinstall.yaml)

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

require_normal_user

AUTOINSTALL_FILE="${1:-${SCRIPT_DIR}/../disk-setup/autoinstall.yaml}"
if [[ ! -f "${AUTOINSTALL_FILE}" ]]; then
    log_err "Non trovo ${AUTOINSTALL_FILE}."
    log_err "Genera prima il file con: ../disk-setup/prepare-autoinstall.sh"
    exit 1
fi
# Controlla solo i segnaposto veri e propri (non il generico "__...__" del
# commento esplicativo nel template, che altrimenti darebbe un falso
# positivo su se stesso).
if grep -qE '__(HOSTNAME|USERNAME|USER_PASSWORD_HASH|LUKS_PASSPHRASE|TAILSCALE_AUTHKEY)__' "${AUTOINSTALL_FILE}"; then
    log_err "${AUTOINSTALL_FILE} contiene ancora dei segnaposto non sostituiti:"
    log_err "non è stato generato da prepare-autoinstall.sh, non lo uso."
    exit 1
fi

VM_NAME="${VM_NAME:-ubuntu-ultimate-test}"
VM_RAM_MB="${VM_RAM_MB:-4096}"
VM_VCPUS="${VM_VCPUS:-2}"
VM_DISK_GB="${VM_DISK_GB:-30}"

ISO_DIR="${SCRIPT_DIR}/isos"
ISO_VERSION="26.04.1"
ISO_NAME="ubuntu-${ISO_VERSION}-desktop-amd64.iso"
ISO_PATH="${ISO_DIR}/${ISO_NAME}"

# releases.ubuntu.com è il sito ufficiale ma non è un CDN e da fuori dagli
# USA può essere lento. Mirror come GARR di solito sono molto più veloci
# dall'Italia, ma anche loro possono avere giornate storte (bandwidth
# condivisa, problemi di rete locali, ecc.): invece di tenerne uno fisso,
# di default ne testiamo alcuni e usiamo quello più veloce al momento (vedi
# pick_fastest_mirror() in scripts/lib/common.sh). Puoi personalizzare la
# lista con ISO_MIRRORS="https://a/... https://b/..." ./create-test-vm.sh,
# oppure saltare del tutto il test forzando un mirror fisso con
# ISO_MIRROR=https://... ./create-test-vm.sh
DEFAULT_ISO_MIRRORS=(
    "https://ubuntu.mirror.garr.it/ubuntu-releases"
    "https://mirror.init7.net/ubuntu-releases"
    "https://ftp.halifax.rwth-aachen.de/ubuntu-releases"
    "https://mirrors.xtom.de/ubuntu-releases"
    "https://www.mirrorservice.org/sites/releases.ubuntu.com"
    "https://releases.ubuntu.com"
)

VM_DIR="${HOME}/.local/share/ubuntu-ultimate-test-vm"
VM_DISK="${VM_DIR}/${VM_NAME}.qcow2"
SEED_ISO="${VM_DIR}/${VM_NAME}-seed.iso"

mkdir -p "${ISO_DIR}" "${VM_DIR}"

# libvirtd (qemu:///system) fa girare le VM come l'utente di sistema
# 'libvirt-qemu', non come te: per aprire i file dentro $HOME (l'ISO, il
# disco virtuale) gli serve il permesso di "attraversamento" (x) su ogni
# cartella del percorso, che sulla home di Ubuntu di solito non c'è per
# utenti/servizi esterni. Niente da spostare: basta dare quel permesso
# minimo, cartella per cartella, con una ACL dedicata (non tocchiamo i
# permessi "normali", quindi il resto degli utenti del sistema non vede
# comunque il contenuto della tua home).
command -v setfacl >/dev/null 2>&1 || sudo apt install -y acl

# cloud-localds (usato più sotto per costruire la seed ISO con
# user-data/meta-data) non è installato di default: lo fornisce il
# pacchetto cloud-image-utils. Controllato qui in cima, PRIMA del possibile
# download della ISO Ubuntu da ~6GB, per non far fallire lo script solo
# all'ultimo passo dopo un'attesa lunga.
command -v cloud-localds >/dev/null 2>&1 || {
    log_info "Installo cloud-image-utils (fornisce cloud-localds)..."
    sudo apt install -y cloud-image-utils
}

# virt-install (pacchetto virtinst) manca a volte anche quando virsh/
# libvirtd sono già a posto (es. 00-enable-virtualization.sh non ancora
# lanciato, o lanciato ma con quel pacchetto fallito a parte). Controllato
# qui in cima come gli altri prerequisiti, PRIMA del possibile download
# della ISO da ~6GB.
command -v virt-install >/dev/null 2>&1 || {
    log_info "Installo virtinst (fornisce virt-install)..."
    sudo apt install -y virtinst
}

# swtpm fornisce il vTPM 2.0 emulato passato più sotto a virt-install
# (--tpm backend.type=emulator,backend.version=2.0): senza questo pacchetto
# la VM parte comunque, ma senza alcun /dev/tpmrm0 dentro — a quel punto
# scripts/19-tpm2-autounlock.sh (sblocco automatico del disco via TPM2, non
# collegato all'autoinstall: è un passo manuale opzionale post-installazione)
# si ferma subito con "Nessun device TPM trovato". Controllato qui come gli
# altri prerequisiti, prima del possibile download della ISO.
command -v swtpm >/dev/null 2>&1 || {
    log_info "Installo swtpm (fornisce il vTPM 2.0 emulato per la VM)..."
    sudo apt install -y swtpm swtpm-tools
}

# Tutti e tre questi controlli (cloud-localds, virt-install, e questo qui)
# sono in realtà sintomo dello stesso problema di fondo: 00-enable-
# virtualization.sh (il prerequisito dichiarato in cima a questo script)
# non è mai stato lanciato — quello script installa TUTTI questi pacchetti
# insieme e abilita/avvia libvirtd in un colpo solo. I controlli sopra
# tappano i buchi pacchetto per pacchetto; questo qui invece controlla la
# causa più comune di "Failed to connect socket to '/var/run/libvirt/
# libvirt-sock'": il demone libvirtd non è (ancora) attivo.
if ! systemctl is-active --quiet libvirtd; then
    log_info "libvirtd non risulta attivo: lo abilito e avvio (come fa 00-enable-virtualization.sh)..."
    sudo systemctl enable --now libvirtd
    # Il socket non compare istantaneamente: piccola attesa attiva invece di
    # una sleep fissa, per non far fallire lo script su una macchina lenta.
    for _ in $(seq 1 20); do
        [[ -S /var/run/libvirt/libvirt-sock ]] && break
        sleep 0.5
    done
fi
if ! sudo virsh net-info default >/dev/null 2>&1; then
    log_warn "Rete libvirt 'default' non trovata/attiva: provo ad avviarla (la VM ne ha bisogno per la rete)."
    sudo virsh net-autostart default >/dev/null 2>&1 || true
    sudo virsh net-start default >/dev/null 2>&1 || log_warn "Non sono riuscito ad avviare la rete 'default': se la VM resta senza rete, lancia prima ./00-enable-virtualization.sh."
fi

grant_traverse_for_libvirt() {
    local dir
    dir="$(dirname -- "$1")"
    while [[ "${dir}" != "/" && "${dir}" != "." ]]; do
        sudo setfacl -m u:libvirt-qemu:x "${dir}" 2>/dev/null || true
        dir="$(dirname -- "${dir}")"
    done
}
grant_traverse_for_libvirt "${ISO_PATH}"
grant_traverse_for_libvirt "${VM_DISK}"

# --- 1. Scarica l'ISO di Ubuntu 26.04, se manca (o non è ancora verificata) -
# Un file .verified accanto alla ISO è la prova che il checksum è stato
# controllato con successo: senza questo controllo, un download interrotto
# a metà (es. Ctrl-C su un tentativo precedente) sarebbe scambiato per "già
# scaricato" solo perché il file esiste.
ISO_VERIFIED_MARKER="${ISO_PATH}.verified"
if [[ ! -f "${ISO_VERIFIED_MARKER}" ]]; then
    if ! command -v aria2c >/dev/null 2>&1; then
        log_info "Installo aria2 (download multi-connessione, molto più veloce di curl per file grossi)..."
        sudo apt install -y aria2 || log_warn "Installazione di aria2 fallita, proseguo con curl."
    fi

    if [[ -n "${ISO_MIRROR:-}" ]]; then
        # L'utente ha forzato un mirror specifico: niente test, lo usiamo così com'è.
        log_info "Uso il mirror forzato da ISO_MIRROR: ${ISO_MIRROR}"
    else
        ISO_MIRROR_CANDIDATES=()
        if [[ -n "${ISO_MIRRORS:-}" ]]; then
            read -r -a ISO_MIRROR_CANDIDATES <<< "${ISO_MIRRORS}"
        else
            ISO_MIRROR_CANDIDATES=("${DEFAULT_ISO_MIRRORS[@]}")
        fi
        ISO_MIRROR="$(pick_fastest_mirror "26.04/${ISO_NAME}" "${ISO_MIRROR_CANDIDATES[@]}")" || {
            log_warn "Nessun mirror testabile, ripiego sul primo della lista."
            ISO_MIRROR="${ISO_MIRROR_CANDIDATES[0]}"
        }
    fi
    ISO_URL="${ISO_MIRROR%/}/26.04/${ISO_NAME}"

    log_info "Scarico ${ISO_NAME} da ${ISO_MIRROR} (~6 GB, può volerci un po')..."
    if command -v aria2c >/dev/null 2>&1; then
        # aria2c apre più connessioni in parallelo verso lo stesso file:
        # su un mirror con tanta banda (come GARR) è molto più veloce di un
        # singolo stream curl, e riprende da dove interrotto se rilanciato.
        # Il progresso viene disegnato da download_with_progress() (vedi
        # scripts/lib/common.sh): una riga sola, pulita, invece delle
        # tabelle ASCII/colori di aria2c che in alcuni terminali escono
        # duplicate o coi codici non renderizzati.
        download_with_progress "${ISO_URL}" "${ISO_DIR}" "${ISO_NAME}" "${ISO_PATH}"
    else
        log_warn "aria2c non disponibile: uso curl a connessione singola (più lento)."
        curl -fL --progress-bar --continue-at - -o "${ISO_PATH}" "${ISO_URL}"
    fi

    log_info "Verifico il checksum SHA256 contro releases.ubuntu.com (fonte ufficiale, indipendentemente dal mirror usato)..."
    EXPECTED_SUM="$(curl -fsSL "https://releases.ubuntu.com/26.04/SHA256SUMS" | awk -v f="${ISO_NAME}" '$2 == "*"f {print $1}')"
    ACTUAL_SUM="$(sha256sum "${ISO_PATH}" | awk '{print $1}')"
    if [[ -z "${EXPECTED_SUM}" ]]; then
        log_warn "Non ho trovato il checksum atteso in SHA256SUMS, salto la verifica."
    elif [[ "${EXPECTED_SUM}" != "${ACTUAL_SUM}" ]]; then
        log_err "Checksum non corrispondente! Il file scaricato è corrotto o manomesso."
        rm -f "${ISO_PATH}"
        exit 1
    else
        log_ok "Checksum verificato."
        touch "${ISO_VERIFIED_MARKER}"
    fi
else
    log_warn "${ISO_NAME} già presente e verificata in ${ISO_DIR}, non la riscarico."
fi

# --- 2. Costruisci la ISO "seed" (datasource NoCloud) ----------------------
log_info "Costruisco la ISO seed con i dati di autoinstall (user-data/meta-data)..."
SEED_TMP="$(mktemp -d)"
cp "${AUTOINSTALL_FILE}" "${SEED_TMP}/user-data"
cp "${SCRIPT_DIR}/../disk-setup/meta-data" "${SEED_TMP}/meta-data"
cloud-localds "${SEED_ISO}" "${SEED_TMP}/user-data" "${SEED_TMP}/meta-data"
rm -rf "${SEED_TMP}"
log_ok "Seed ISO pronta: ${SEED_ISO}"

# --- 3. Determina l'os-variant migliore disponibile in libosinfo ----------
if osinfo-query os --fields=short-id 2>/dev/null | grep -qx 'ubuntu26.04'; then
    OS_VARIANT=ubuntu26.04
elif osinfo-query os --fields=short-id 2>/dev/null | grep -qx 'ubuntu24.04'; then
    OS_VARIANT=ubuntu24.04
    log_warn "libosinfo non conosce ancora ubuntu26.04 su questo host, uso ubuntu24.04 come approssimazione."
else
    OS_VARIANT=generic
    log_warn "libosinfo non conosce Ubuntu 26.04/24.04 su questo host, uso 'generic'."
fi

# --- 4. Elimina un'eventuale VM di prova precedente con lo stesso nome ----
if virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
    log_warn "Esiste già una VM '${VM_NAME}': la rimuovo per ripartire pulito."
    virsh destroy "${VM_NAME}" >/dev/null 2>&1 || true
    virsh undefine "${VM_NAME}" --nvram >/dev/null 2>&1 || true
fi
rm -f "${VM_DISK}"

# --- 5. Crea e avvia la VM -------------------------------------------------
# BUG REALE trovato testando il boot dopo l'installazione: con "--boot uefi"
# secco, libvirt sceglie da solo quale firmware OVMF usare tra quelli
# descritti in /usr/share/qemu/firmware/*.json sull'host, e su alcuni host
# il primo/il default che matcha è una variante con Secure Boot ABILITATO
# (enrollment Microsoft già presente in OVMF_VARS). Risultato osservato:
# "efibootmgr -v" mostrava Boot0005 (Limine, EFI\limine\BOOTX64.EFI, NON
# firmato) correttamente PRIMO in BootOrder, ma BootCurrent risultava 0004
# (Ubuntu/GRUB via EFI\ubuntu\shimx64.efi, firmato Microsoft) — cioè il
# firmware ha provato Limine per primo, l'ha rifiutato perché non firmato, ed
# è silenziosamente "caduto" sulla voce successiva. Coerente con l'assunzione
# scritta nei commenti di disk-setup/autoinstall.yaml.tpl ("Secure Boot è
# disattivo per questa installazione"): quell'assunzione vale sull'hardware
# reale della demo (dove Secure Boot va disattivato a mano dal firmware/BIOS
# prima di avviare la live ISO), ma qui nella VM di test nessuno la
# garantiva esplicitamente. Fix: si forza esplicitamente lo spegnimento del
# Secure Boot nel firmware OVMF scelto per la VM, invece di lasciare la
# scelta implicita a libvirt.
log_info "Creo la VM '${VM_NAME}' (RAM ${VM_RAM_MB}MB, ${VM_VCPUS} vCPU, disco ${VM_DISK_GB}GB, UEFI, Secure Boot disattivo)..."
virt-install \
    --name "${VM_NAME}" \
    --memory "${VM_RAM_MB}" \
    --vcpus "${VM_VCPUS}" \
    --cpu host-passthrough \
    --machine q35 \
    --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
    --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
    --disk path="${VM_DISK}",size="${VM_DISK_GB}",format=qcow2,bus=virtio \
    --disk path="${SEED_ISO}",device=cdrom,bus=sata,readonly=on \
    --cdrom "${ISO_PATH}" \
    --os-variant "${OS_VARIANT}" \
    --graphics spice \
    --network network=default \
    --noautoconsole

log_ok "VM avviata: l'installazione unattended sta partendo."
echo
echo "Per seguire l'installazione a video:"
echo "  virt-viewer ${VM_NAME}          # finestra grafica"
echo "  virsh console ${VM_NAME}        # console testuale (utile per i log)"
echo
echo "A fine installazione la VM si riavvia da sola: al riavvio verrà chiesta"
echo "la passphrase LUKS2 (tramite virt-viewer/virsh console, non SSH). Questo è"
echo "normale ed è atteso: lo sblocco automatico via TPM2 NON è parte"
echo "dell'autoinstall, è un passo manuale opzionale a sistema già installato"
echo "(scripts/19-tpm2-autounlock.sh) — questa VM ha già un vTPM 2.0 emulato"
echo "collegato, quindi puoi testarlo lanciando quello script dopo il primo boot."
echo "Dopo il boot, verifica il layout disco con:"
echo "  ./verify-test-vm.sh ${VM_NAME} <username>"
