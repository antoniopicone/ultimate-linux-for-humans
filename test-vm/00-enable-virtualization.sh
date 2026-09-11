#!/usr/bin/env bash
# 00-enable-virtualization.sh — abilita KVM/QEMU/libvirt sulla macchina che
# useremo per testare la ricetta (host Ubuntu). Non ha nulla a che vedere
# con la macchina "target" della ricetta: qui installiamo solo gli
# strumenti per creare e far girare la VM di prova.
#
# Uso: ./00-enable-virtualization.sh

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

require_normal_user

log_info "Verifico che la CPU supporti la virtualizzazione hardware (VT-x/AMD-V)..."
VIRT_FLAGS="$(egrep -c '(vmx|svm)' /proc/cpuinfo || true)"
if [[ "${VIRT_FLAGS}" -eq 0 ]]; then
    log_err "La CPU non espone i flag vmx/svm: la virtualizzazione hardware"
    log_err "non è supportata (o va abilitata nel BIOS/UEFI). KVM non funzionerà."
    exit 1
fi
log_ok "Virtualizzazione hardware supportata (${VIRT_FLAGS} core con vmx/svm)."

apt_update_once

# NOTA: qui NON facciamo un "apt upgrade" generale prima di installare lo
# stack di virtualizzazione. L'avevamo aggiunto per un problema di versioni
# pinnate di libvirt, ma su questa macchina "apt upgrade" si blocca per un
# pacchetto scorrelato già installato (onlyoffice-desktopeditors, con
# dipendenze non soddisfatte) — non è un problema della ricetta, ma va
# risolto a parte con calma (vedi README). "apt install" con i pacchetti
# espliciti sotto non tocca onlyoffice e basta a risolvere le dipendenze
# di libvirt.

# "qemu-kvm" è un pacchetto virtuale: su alcune installazioni (es. con lo
# stack HWE) apt lo vede fornito sia da qemu-system-x86 che da
# qemu-system-x86-hwe e non lo risolve da solo ("è necessario sceglierne
# esplicitamente uno"). Stesso discorso vale per il meta-pacchetto
# "ubuntu-virt" (nuovo in Ubuntu 26.04, raggruppa le dipendenze base dello
# stack di virtualizzazione): esiste anche una variante "-hwe". Scegliamo
# noi in automatico, preferendo la variante HWE se è quella già in uso sul
# sistema (kernel HWE), altrimenti quella standard — e la installiamo
# esplicitamente, perché senza di essa apt segnala come irrisolvibili
# anche qemu-system-x86, libvirt-daemon-system, ovmf, ecc.
if dpkg -l 'linux-image-*-generic-hwe-*' 2>/dev/null | grep -q '^ii'; then
    IS_HWE=1
else
    IS_HWE=0
fi

if [[ "${IS_HWE}" -eq 1 ]] && apt-cache show qemu-system-x86-hwe >/dev/null 2>&1; then
    QEMU_PKG="qemu-system-x86-hwe"
elif apt-cache show qemu-system-x86 >/dev/null 2>&1; then
    QEMU_PKG="qemu-system-x86"
else
    QEMU_PKG="qemu-system-x86-hwe"
fi

if [[ "${IS_HWE}" -eq 1 ]] && apt-cache show ubuntu-virt-hwe >/dev/null 2>&1; then
    UBUNTU_VIRT_PKG="ubuntu-virt-hwe"
elif apt-cache show ubuntu-virt >/dev/null 2>&1; then
    UBUNTU_VIRT_PKG="ubuntu-virt"
else
    UBUNTU_VIRT_PKG="ubuntu-virt-hwe"
fi

log_info "Uso i pacchetti: ${QEMU_PKG}, ${UBUNTU_VIRT_PKG}"

log_info "Installo ${QEMU_PKG}, libvirt, virt-manager, virt-viewer e il firmware UEFI (ovmf)..."
sudo apt install -y \
    "${UBUNTU_VIRT_PKG}" \
    "${QEMU_PKG}" \
    qemu-utils \
    libvirt-daemon-system \
    libvirt-clients \
    bridge-utils \
    virtinst \
    virt-manager \
    virt-viewer \
    ovmf \
    genisoimage \
    cloud-image-utils

log_info "Abilito e avvio libvirtd..."
sudo systemctl enable --now libvirtd

log_info "Aggiungo ${USER} ai gruppi kvm e libvirt..."
sudo usermod -aG kvm,libvirt "${USER}"

log_info "Attivo la rete NAT di default di libvirt..."
sudo virsh net-autostart default >/dev/null 2>&1 || true
sudo virsh net-start default >/dev/null 2>&1 || log_warn "Rete 'default' già attiva o non disponibile."

log_info "Verifica finale con virt-host-validate (qualche WARN è normale, gli ERROR no):"
sudo virt-host-validate qemu || log_warn "virt-host-validate ha segnalato dei problemi, controlla sopra."

log_ok "Virtualizzazione pronta."
log_warn "Devi fare logout/login (o riavviare) perché l'appartenenza ai gruppi"
log_warn "kvm/libvirt diventi effettiva senza dover usare sudo per virsh/virt-install."
