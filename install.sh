#!/usr/bin/env bash
# install.sh — orchestratore della ricetta "Ubuntu Ultimate".
#
# Lancia in ordine tutti gli script numerati in scripts/. Ogni script è
# anche eseguibile singolarmente per testarlo in isolamento.
#
# Uso: ./install.sh

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"

require_normal_user
require_ubuntu_release "26.04"

log_info "=== Ubuntu Ultimate: avvio provisioning ==="

for step in "${SCRIPT_DIR}"/scripts/[0-9][0-9]-*.sh; do
    log_info "--- Eseguo $(basename "${step}") ---"
    bash "${step}"
done

log_ok "=== Provisioning completato ==="
