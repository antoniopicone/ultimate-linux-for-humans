#!/usr/bin/env bash
# common.sh — funzioni condivise per gli script della ricetta "Ubuntu Ultimate"
#
# Viene "sourcato" (non eseguito) dagli altri script del progetto.

set -euo pipefail

# --- Colori per il log -------------------------------------------------
readonly C_RESET='\033[0m'
readonly C_BLUE='\033[1;34m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_RED='\033[1;31m'

log_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
log_ok()    { echo -e "${C_GREEN}[ OK ]${C_RESET}  $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
log_err()   { echo -e "${C_RED}[ERR ]${C_RESET}  $*" >&2; }

# --- Guardie di ambiente -------------------------------------------------

# Deve essere lanciato come utente normale (non root): gli script chiamano
# sudo internamente solo dove serve, così i file di configurazione utente
# (~/.config, ~/.bashrc, ecc.) vengono scritti col proprietario giusto.
require_normal_user() {
    if [[ "${EUID}" -eq 0 ]]; then
        log_err "Non lanciare questo script con sudo/root: verrà chiesta la password quando serve."
        exit 1
    fi
}

# Verifica (senza bloccare) che la release sia quella attesa dalla ricetta.
require_ubuntu_release() {
    local expected="${1:-26.04}"
    local current
    current="$(. /etc/os-release && echo "${VERSION_ID:-unknown}")"
    if [[ "${current}" != "${expected}" ]]; then
        log_warn "Questa ricetta è pensata per Ubuntu ${expected}, ma il sistema è ${current}. Continuo comunque."
    fi
}

# Assicura che il repository universe sia abilitato (serve per ghostty).
ensure_universe_enabled() {
    if ! grep -Rq "^deb .*universe" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null \
       && [[ ! -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
        log_info "Abilito il repository universe..."
        sudo add-apt-repository -y universe
    elif command -v add-apt-repository >/dev/null 2>&1; then
        # Su 26.04 le sorgenti sono in formato deb822 (ubuntu.sources): usare
        # sempre add-apt-repository è idempotente e non fa danni se già presente.
        sudo add-apt-repository -y universe >/dev/null 2>&1 || true
    fi
}

# Assicura che il repository multiverse sia abilitato (serve per
# ttf-mscorefonts-installer). Sulla ISO desktop è già abilitato di default,
# ma su un sistema minimizzato/server potrebbe non esserlo.
ensure_multiverse_enabled() {
    if ! grep -Rq "^deb .*multiverse" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null \
       && [[ ! -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
        log_info "Abilito il repository multiverse..."
        sudo add-apt-repository -y multiverse
    elif command -v add-apt-repository >/dev/null 2>&1; then
        # Su 26.04 le sorgenti sono in formato deb822 (ubuntu.sources): usare
        # sempre add-apt-repository è idempotente e non fa danni se già presente.
        sudo add-apt-repository -y multiverse >/dev/null 2>&1 || true
    fi
}

apt_update_once() {
    if [[ "${APT_UPDATED:-0}" -ne 1 ]]; then
        log_info "Aggiorno l'elenco pacchetti (apt update)..."
        sudo apt update -qq
        export APT_UPDATED=1
    fi
}

is_installed() {
    dpkg -s "$1" >/dev/null 2>&1
}

# --- Progresso pulito per download grossi (aria2c) -----------------------

# Converte un numero di byte in una stringa leggibile (GiB/MiB/KiB/B).
human_size() {
    local bytes="$1"
    awk -v b="${bytes}" 'BEGIN {
        split("B KiB MiB GiB TiB", units, " ");
        u = 1;
        while (b >= 1024 && u < 5) { b /= 1024; u++ }
        printf "%.1f%s", b, units[u]
    }'
}

# Disegna una riga di progresso con barra visuale (es. "[####----] 42%").
# Uso interno di download_with_progress(), non chiamarla direttamente.
# Argomenti: cur_bytes total_size(o vuoto) rate_bytes_s elapsed_s width is_tty [done]
_progress_bar_line() {
    local cur="$1" total="$2" rate="$3" elapsed="$4" width="$5" is_tty="$6" mode="${7:-}"
    local elapsed_str
    elapsed_str="$(printf '%dm%02ds' "$(( elapsed / 60 ))" "$(( elapsed % 60 ))")"

    local line speed_str
    speed_str="$(human_size "${rate}")/s"

    if [[ -n "${total}" && "${total}" -gt 0 ]]; then
        local pct=$(( cur * 100 / total ))
        (( pct > 100 )) && pct=100
        local filled=$(( pct * width / 100 ))
        local empty=$(( width - filled ))
        local filled_str empty_str
        printf -v filled_str '%*s' "${filled}" ''
        printf -v empty_str '%*s' "${empty}" ''

        local eta_str
        if [[ "${mode}" == "done" || "${cur}" -ge "${total}" ]]; then
            eta_str="fatto"
            speed_str="  --  "
        elif (( rate > 0 )); then
            local eta_sec=$(( (total - cur) / rate ))
            eta_str="$(printf '%dm%02ds' "$(( eta_sec / 60 ))" "$(( eta_sec % 60 ))")"
        else
            eta_str="in corso..."
        fi

        line="$(printf '  [%s%s] %3d%%  %s/%s  %s  ETA %-11s (%s)' \
            "${filled_str// /#}" "${empty_str// /-}" "${pct}" \
            "$(human_size "${cur}")" "$(human_size "${total}")" \
            "${speed_str}" "${eta_str}" "${elapsed_str}")"
    else
        # Content-Length sconosciuto (HEAD fallita): niente barra/percentuale,
        # solo quanto scaricato finora e a che velocità.
        line="$(printf '  %s scaricati  %s  (%s)' \
            "$(human_size "${cur}")" "${speed_str}" "${elapsed_str}")"
    fi

    if (( is_tty )); then
        printf '\r\033[K%s' "${line}"
    else
        echo "${line}"
    fi
}

# Scarica un file con aria2c mostrando UNA riga di progresso pulita con
# barra visuale, percentuale, velocità ed ETA — aggiornata sul posto (\r)
# ogni secondo se il terminale lo supporta, oppure una riga al secondo
# altrimenti — invece delle tabelle ASCII/colori di aria2c stesso, che in
# alcuni terminali (multiplexer, finestre non realmente interattive)
# escono duplicate o con codici non renderizzati.
# Uso: download_with_progress <url> <dir_output> <nome_file> <path_output>
download_with_progress() {
    local url="$1" out_dir="$2" out_name="$3" out_path="$4"

    local total_size=""
    total_size="$(curl -fsSIL "${url}" 2>/dev/null \
        | awk 'tolower($1)=="content-length:" {gsub("\r","",$2); print $2}' \
        | tail -n1)"

    local log_file
    log_file="$(mktemp)"

    aria2c \
        --dir="${out_dir}" \
        --out="${out_name}" \
        --max-connection-per-server=8 \
        --split=8 \
        --min-split-size=20M \
        --continue=true \
        --quiet=true \
        --enable-color=false \
        "${url}" > "${log_file}" 2>&1 &
    local aria_pid=$!

    local is_tty=0 bar_width=32
    [[ -t 1 ]] && is_tty=1
    local start_ts now_ts last_ts last_bytes printed_any=0
    start_ts="$(date +%s)"
    last_ts="${start_ts}"
    last_bytes=0

    # BUG REALE trovato testando build-live-remix.sh (screenshot di Antonio):
    # col terminale non riconosciuto come TTY reale, la riga "100% ETA fatto"
    # continuava a ripetersi UNA volta al secondo per minuti dopo il
    # completamento, dando l'impressione che il download non stesse
    # "andando avanti" — la versione precedente di questo fix provava a
    # deduplicare confrontando pct/eta_str/cur tra una chiamata e l'altra,
    # ma elapsed_str (i secondi trascorsi, stampati dentro la riga stessa)
    # NON entrava in quel confronto eppure cambia ad ogni secondo, quindi in
    # pratica la riga risultava sempre "diversa" e veniva ristampata
    # comunque: la deduplica non funzionava mai una volta a regime.
    # Fix strutturale: appena il download risulta completo, la riga con la
    # barra/percentuale viene stampata UNA sola volta (non più ad ogni
    # secondo), e l'attesa della chiusura di aria2c viene invece segnalata
    # con un messaggio distinto, a cadenza fissa ogni 15s — nessun confronto
    # testuale fragile, il comportamento è deterministico per costruzione.
    # BUG REALE #2 (screenshot successivo di Antonio, stavolta con rete
    # confermata funzionante): con la barra "silenziata" correttamente dal
    # fix sopra, è rimasto visibile un problema vero e distinto, che prima
    # lo spam nascondeva semplicemente ripetendo la riga: aria2c a volte NON
    # termina affatto dopo aver scritto l'ultimo byte, restando appeso per
    # minuti nonostante il file su disco sia già byte-per-byte completo
    # (dimensione = Content-Length, confermato dal nostro stesso confronto
    # cur_bytes>=total_size). Comportamento noto di aria2c con connessioni
    # HTTP keep-alive multiple (--max-connection-per-server=8) verso alcuni
    # mirror/CDN che non chiudono pulito il socket lato server: aria2c resta
    # in attesa di quella chiusura anche se non gli serve più nulla. Non è
    # un problema della nostra rete né dello script che aspetta: il file è
    # già tutto lì. Fix: dato che possiamo verificare in autonomia che il
    # download è completo (stessa condizione già usata per la riga "fatto"),
    # se aria2c non è terminato da solo entro una soglia (FORCE_KILL_AFTER_S)
    # lo terminiamo noi esplicitamente (TERM, poi KILL se non basta) invece
    # di restare in attesa indefinita — il file resta intatto, non scriviamo
    # più nulla noi né lui da quel punto in poi.
    local -r FORCE_KILL_AFTER_S=240
    local complete_since=0 complete_line_printed=0 stall_warned=0 force_killed=0
    while kill -0 "${aria_pid}" 2>/dev/null; do
        sleep 1
        local cur_bytes=0
        [[ -f "${out_path}" ]] && cur_bytes="$(stat --format=%s "${out_path}" 2>/dev/null || echo 0)"

        now_ts="$(date +%s)"
        local step=$(( now_ts - last_ts ))
        (( step <= 0 )) && step=1
        local delta=$(( cur_bytes - last_bytes ))
        (( delta < 0 )) && delta=0
        local rate=$(( delta / step ))

        local is_complete=0
        if [[ -n "${total_size}" && "${total_size}" -gt 0 && "${cur_bytes}" -ge "${total_size}" ]]; then
            is_complete=1
        fi

        if (( is_complete )); then
            # Riga con barra/percentuale finale: solo la prima volta che
            # rileviamo il completamento, non più ad ogni giro del loop.
            if (( complete_line_printed == 0 )); then
                _progress_bar_line "${cur_bytes}" "${total_size}" "${rate}" "$(( now_ts - start_ts ))" "${bar_width}" "${is_tty}" "done"
                printed_any=1
                complete_line_printed=1
                (( is_tty )) || echo  # su TTY reale la barra resta sulla stessa riga (\r); su file/pipe serve andare a capo prima dei prossimi messaggi
            fi

            (( complete_since == 0 )) && complete_since="${now_ts}"
            local since_complete=$(( now_ts - complete_since ))

            # aria2c a volte resta vivo per un po' dopo aver scritto l'ultimo
            # byte (chiusura delle connessioni aperte da --max-connection-per-
            # server=8). Normale entro qualche secondo; se dura più a lungo
            # lo segnaliamo esplicitamente, a cadenza fissa (ogni 15s) invece
            # di spammare la riga di progresso.
            if (( ! is_tty && since_complete > 0 && since_complete % 15 == 0 )); then
                log_info "Download completato, in attesa che aria2c chiuda le connessioni aperte (${since_complete}s)..."
            fi

            if (( stall_warned == 0 && since_complete >= 180 )); then
                log_warn "Tutti i byte risultano scaricati da oltre 3 minuti ma aria2c non è ancora terminato: potrebbe essere lento a chiudere le connessioni, oppure bloccato. Se non finisce entro qualche altro minuto, interrompi (Ctrl+C) e verifica la rete/il mirror."
                stall_warned=1
            fi

            if (( since_complete >= FORCE_KILL_AFTER_S )); then
                log_warn "aria2c non ha chiuso da solo entro ${FORCE_KILL_AFTER_S}s dal completamento: il file su disco è comunque già completo (dimensione = quella attesa), quindi lo forzo a terminare invece di restare in attesa indefinita."
                kill -TERM "${aria_pid}" 2>/dev/null || true
                sleep 2
                if kill -0 "${aria_pid}" 2>/dev/null; then
                    kill -KILL "${aria_pid}" 2>/dev/null || true
                fi
                force_killed=1
                break
            fi
        else
            complete_since=0
            complete_line_printed=0
            _progress_bar_line "${cur_bytes}" "${total_size}" "${rate}" "$(( now_ts - start_ts ))" "${bar_width}" "${is_tty}"
            printed_any=1
        fi

        last_bytes="${cur_bytes}"
        last_ts="${now_ts}"
    done

    if (( force_killed )); then
        # Terminato da noi (vedi sopra): non è un fallimento del download, il
        # file era già confermato completo prima del kill. "wait" restituirà
        # comunque uno stato di uscita non-zero (il processo è stato ucciso
        # da un segnale) — qui lo ignoriamo deliberatamente.
        wait "${aria_pid}" 2>/dev/null || true
        log_ok "aria2c terminato forzatamente dopo il completamento del download (vedi avviso sopra); file confermato completo."
    elif ! wait "${aria_pid}"; then
        (( is_tty && printed_any )) && printf '\n'
        log_err "Download fallito, ultime righe del log di aria2c:"
        tail -n 20 "${log_file}" >&2
        rm -f "${log_file}"
        return 1
    fi

    # Riga finale a "fatto": normalmente già stampata dentro il loop appena
    # rilevato il completamento (complete_line_printed=1) — qui serve solo
    # a coprire il caso limite in cui aria2c sia terminato così in fretta
    # (es. file già completo da un tentativo precedente) che il ciclo sopra
    # non ha fatto in tempo a girare nemmeno una volta.
    if (( complete_line_printed == 0 )); then
        local final_bytes=0
        [[ -f "${out_path}" ]] && final_bytes="$(stat --format=%s "${out_path}" 2>/dev/null || echo 0)"
        _progress_bar_line "${final_bytes}" "${total_size}" 0 "$(( $(date +%s) - start_ts ))" "${bar_width}" "${is_tty}" "done"
    fi
    printf '\n'

    rm -f "${log_file}"
}

# Testa la velocità di più mirror scaricando ~8MB (range request) da
# ciascuno e stampa su stdout quello più veloce. 8MB è abbastanza da
# superare lo slow-start TCP e dare una stima realistica senza far perdere
# troppo tempo. Se un mirror non risponde entro il timeout (o non esiste)
# curl riporta comunque speed=0 tramite -w, quindi il test non si blocca.
#
# Uso: pick_fastest_mirror <percorso_relativo_del_file_da_testare> <mirror1> [mirror2 ...]
# Es:  pick_fastest_mirror "26.04/ubuntu-26.04.1-desktop-amd64.iso" "${MIRRORS[@]}"
# Su successo stampa il mirror più veloce su stdout (da catturare con $(...));
# ritorna 1 (senza stampare nulla) se nessun mirror ha risposto.
pick_fastest_mirror() {
    local rel_path="$1"
    shift
    local mirrors=("$@")
    local test_bytes=8388608
    local best_mirror="" best_speed=0

    log_info "Provo la velocità di ${#mirrors[@]} mirror (~8MB da ciascuno, qualche secondo per mirror)..." >&2

    local mirror url speed
    for mirror in "${mirrors[@]}"; do
        url="${mirror%/}/${rel_path}"
        speed="$(curl -s -o /dev/null -w '%{speed_download}' \
            --max-time 8 --range "0-$(( test_bytes - 1 ))" "${url}" 2>/dev/null || echo 0)"
        speed="${speed%%.*}"
        [[ -z "${speed}" ]] && speed=0

        if (( speed > 0 )); then
            log_info "  $(printf '%-58s' "${mirror}") $(human_size "${speed}")/s" >&2
        else
            log_warn "  $(printf '%-58s' "${mirror}") non raggiungibile" >&2
        fi

        if (( speed > best_speed )); then
            best_speed="${speed}"
            best_mirror="${mirror}"
        fi
    done

    if [[ -z "${best_mirror}" ]]; then
        log_warn "Nessun mirror ha risposto al test di velocità." >&2
        return 1
    fi

    log_ok "Mirror più veloce: ${best_mirror} ($(human_size "${best_speed}")/s)" >&2
    echo "${best_mirror}"
}
