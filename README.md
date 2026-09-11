# Ubuntu Ultimate

Ricetta di post-installazione per trasformare un'Ubuntu 26.04 LTS ("Resolute
Raccoon") standard in una configurazione attuale, sicura e curata — pensata
per la presentazione del 17 settembre a Canonical.

## Approccio

Non costruiamo una ISO custom. Partiamo dall'ISO **Ubuntu 26.04 LTS Desktop
standard** e ci pensa un unico file `autoinstall.yaml` (la modalità
unattended dell'installer Subiquity, vedi `disk-setup/`): un boot da ISO,
zero comandi da lanciare a mano dopo il primo login. `late-commands` fa,
in ordine:

1. il partizionamento con BTRFS su LUKS2, che l'installer grafico non sa
   fare da solo;
2. l'installazione del software (Brave, Ghostty, integrazione Nautilus),
   via chroot (`curtin in-target`) — funziona offline perché sono tutte
   operazioni apt/dpkg/dconf, niente che richieda un servizio attivo;
3. l'unica eccezione è Firefox: rimuoverlo richiede `snapd` in esecuzione,
   che in un chroot offline non c'è. Per quello viene installato un
   servizio systemd che gira una volta sola al **primo avvio reale** della
   macchina e poi si disabilita da solo — l'unico pezzo che richiede
   qualche secondo dopo il primo login prima di essere completo (vedi
   `disk-setup/README.md` per i dettagli).

Gli script in `scripts/` restano come riferimento leggibile di cosa fa
questa automazione (e come fallback per rifare un pezzo a mano su un
sistema già installato) ma **non sono più il percorso principale**: la demo
del 17 si basa sull'autoinstall.

Vantaggi di questo approccio rispetto a una ISO respin (Cubic / live-build):

- niente toolchain di build ISO da mantenere — l'unico artefatto "custom" è
  un file YAML;
- è facile aggiungere step (Howdy, usbguard, wizard dei servizi preferiti
  dell'utente...) man mano che la ricetta cresce, nello stesso file.

## Struttura

```
ubuntu-ultimate/
├── install.sh                  # orchestratore post-install: esegue tutti gli step in ordine
├── disk-setup/                 # fase install-time: BTRFS su LUKS2 via autoinstall
│   ├── autoinstall.yaml.tpl    # template del file di configurazione Subiquity
│   ├── prepare-autoinstall.sh  # genera l'autoinstall.yaml chiedendo le password
│   ├── build-seed-usb.sh       # scrive la ISO seed su una chiavetta USB (hardware reale)
│   ├── meta-data               # file richiesto dal datasource NoCloud
│   └── README.md               # come funziona e come si serve all'installer
├── test-vm/                    # officina per validare il layout disco in una VM KVM
│   ├── 00-enable-virtualization.sh  # installa qemu-kvm/libvirt/virt-manager sull'host di test
│   ├── create-test-vm.sh            # scarica l'ISO, crea la VM, avvia l'autoinstall
│   ├── verify-test-vm.sh            # verifica via SSH il layout BTRFS/LUKS2 risultante
│   └── README.md
├── scripts/
│   ├── lib/common.sh           # funzioni condivise (log, guardie, apt helper)
│   ├── 10-remove-firefox.sh    # rimuove Firefox (snap)
│   ├── 11-install-brave.sh     # installa Brave dal repo ufficiale
│   ├── 12-install-ghostty.sh   # installa Ghostty e lo imposta come terminale
│   └── 13-nautilus-ghostty.sh  # fa aprire Ghostty da "Apri nel terminale" di Nautilus
├── live-iso/                   # respin di una ISO live custom (remix), NON solo autoinstall
│   ├── build-live-remix.sh     # orchestratore: estrae/modifica/ricostruisce la ISO ufficiale
│   ├── chroot-customize.sh     # personalizzazioni eseguite in chroot sul filesystem live
│   └── README.md                # scope, esclusioni, rischi, checklist di test
└── README.md
```

## Stato attuale

- [x] Setup disco: BTRFS su LUKS2 via autoinstall (vedi `disk-setup/README.md`
      per dettagli e limiti) — **validato in VM: installazione, riavvio e
      boot funzionano end-to-end**
- [x] Installazione software durante l'autoinstall stesso (Brave, Ghostty +
      `x-terminal-emulator`, estensione Nautilus, rimozione Firefox al primo
      avvio) — **validato in VM insieme al disco, funziona**
- [x] Nome e Cognome completo chiesti da `prepare-autoinstall.sh` e scritti
      in `identity.realname` (campo GECOS): GDM li mostra nella schermata di
      login al posto dello username. Lo stesso Nome e Cognome viene riusato
      per `git config --global user.name` (l'email, chiesta separatamente,
      per `user.email`) — **appena aggiunto, da testare**
- [x] Strumenti per il test in VM (vedi `test-vm/README.md`): abilitazione
      KVM/libvirt sull'host di sviluppo, creazione automatica della VM di
      prova con l'ISO ufficiale e l'autoinstall, verifica via SSH del layout
      disco risultante
- [x] Gli stessi step (Firefox/Brave/Ghostty/Nautilus) esistono anche come
      script standalone in `scripts/`, per riferimento o fallback manuale
- [x] Dash configurata (Brave, File, Ghostty, Visualizzatore documenti,
      nell'ordine) e Gestore delle estensioni GNOME installato —
      **VALIDATO in VM**
- [x] 8 estensioni GNOME Shell scaricate da extensions.gnome.org e
      configurate con le impostazioni di badrobot (vedi "Note tecniche"
      più sotto) — le prime 7 **VALIDATE in VM**, l'ottava (Tailscale for
      GNOME, indicatore in Quick Settings per il Tailscale installato
      sopra) — **appena aggiunta, da testare**
- [x] Touchpad: click a due/tre dita (`click-method=fingers`) e tap-to-click
      esplicitamente attivo
- [x] Velocità dello scroll verticale a due dita sul touchpad ridotta a
      0.20 (default: 0.35) via **Wayland Scroll Factor** (wsf, terze parti
      — GNOME/Wayland non espone nessuna impostazione nativa per questo,
      vedi "Note tecniche"). Il pacchetto `.deb` viene scaricato da GitHub
      Releases durante l'autoinstall stesso; l'attivazione (`wsf enable`)
      è rimandata al primo login reale via una voce autostart che si
      autorimuove (richiede un logout/login per avere effetto, non
      verificabile dentro il chroot) — script standalone equivalente in
      `scripts/20-wayland-scroll-factor.sh` — **appena aggiunto, da
      testare**
- [x] zram (compressione RAM/swap) — **VALIDATO in VM**
- [x] Snapshot del disco con snapper + grub-btrfs, ORA anche per `/home`
      (subvolume `@home_snapshots` dedicato, config separata con
      retention più ampia) oltre che per `/`, basato sullo script
      collaudato da Antonio in un'altra sessione — **appena
      aggiornato/esteso, da ritestare** (la versione precedente, solo
      root, era già stata validata in VM, ma la configurazione è
      cambiata: config scritte direttamente invece di
      `snapper create-config`, nuovo subvolume, nuovo drop-in
      systemd per grub-btrfsd)
- [x] nautilus-snapper-restore: voce "Versioni precedenti (Snapper)…" nel
      menu tasto destro di Nautilus per aprire/ripristinare vecchie
      versioni dei file dagli snapshot Snapper, stile Time Machine —
      **VALIDATO in VM** (bug reale trovato e corretto durante il test:
      conflitto di versione GI Nautilus 4.0/4.1, vedi "Note tecniche")
- [x] GRUB con menu visibile e timeout di 5 secondi (default Ubuntu:
      nascosto, timeout 0) — **appena aggiunto, da testare**
- [x] Utility da riga di comando: vim, curl, wget, htop, avahi-daemon,
      git, lm-sensors, gnome-sushi (anteprima file con barra spaziatrice
      in Nautilus) — **appena aggiunto, da testare**
- [x] Font: font "core" Microsoft (Arial, Times New Roman, ...) via
      `ttf-mscorefonts-installer` (EULA accettata non interattivamente),
      Carlito/Caladea (sostituti liberi di Calibri/Cambria, non coperte
      dalla stessa EULA), JetBrains Mono, Hack Nerd Font (release ufficiale
      del progetto) — SF Pro di macOS intenzionalmente escluso dalla
      ricetta per licenza Apple (vedi "Note tecniche"), installabile a
      parte con `scripts/14-install-fonts.sh` — **appena aggiunto, da
      testare**
- [x] ONLYOFFICE Desktop Editors al posto di LibreOffice (rimosso se
      presente), dal repository apt ufficiale, + 3 voci `.desktop` per
      aprire direttamente un documento/foglio di calcolo/presentazione
      vuoti (`--new:word`/`--new:cell`/`--new:slide`) — idempotente, script
      standalone equivalente in `scripts/15-onlyoffice.sh` — **appena
      aggiunto, da testare**
- [x] Supporto APFS in sola lettura (`apfs-fuse`, compilato da sorgente:
      nessun pacchetto apt disponibile) per leggere dischi/case USB
      provenienti da un Mac, uso da terminale (`apfs-fuse <device>
      <mountpoint>`) e integrazione automount con Nautilus/udisks2 tramite
      l'helper `/sbin/mount.apfs` (vedi "Note tecniche") — niente scrittura
      per scelta upstream (vedi "Note tecniche"), script standalone
      equivalente in `scripts/16-install-apfs-fuse.sh` — **appena aggiunto,
      integrazione Nautilus non ancora confermata in una sessione reale**
- [x] zsh come shell di default per l'utente + Oh My Zsh (installazione
      non interattiva) + tema Pure (clonato in `~/.zsh/pure`, aggiunto a
      `.zshrc` dopo l'installer di Oh My Zsh) — **appena aggiunto, da
      testare**
- [x] Dipendenze di sviluppo GTK4/libadwaita/gtksourceview
      (`libgtk-4-dev python3-dev libadwaita-1-dev libgtksourceview-5-dev`),
      preparate in origine per un'app nativa di lettura Note/Promemoria —
      script standalone `scripts/23-icloud-notes-reminders-deps.sh`.
      **Probabilmente superato**: da quando la lettura delle Note è stata
      risolta con `icloud-md` (vedi voce sotto), quest'app nativa non è
      mai stata scritta — da confermare con Antonio se questo script va
      ancora tenuto o rimosso, vedi "Backlog"
- [x] Lettura reale delle Note di iCloud tramite il tool di terze parti
      `icloud-md` (Node.js + Playwright per il login con 2FA, client
      CloudKit reverse-engineered per i contenuti — non esiste
      un'alternativa Python "pura", vedi "Note tecniche"): script unico
      `scripts/24-icloud-notes.sh` — installa Node.js/icloud-md/Chromium,
      poi fa `clone`/`pull` scaricando davvero le note in `~/Notes`
      (override con `ICLOUD_NOTES_DIR`) e le elenca (`--json` disponibile).
      **Appena aggiunto, il login 2FA reale non è ancora stato testato in
      una sessione grafica vera**
- [x] Flatpak + Flathub (anche dentro "Software", via
      `gnome-software-plugin-flatpak`), eza (sostituto moderno di `ls`, con
      icone — repository apt di terze parti di eza-community, alias `ls`
      aggiunto a `.zshrc`) e configurazione di Ghostty (font Hack Nerd Font
      Mono, tema Catppuccin Mocha) — script standalone equivalente in
      `scripts/22-flatpak-git-eza-ghostty.sh` — **appena aggiunto, da
      testare**
- [x] Tailscale: pacchetto installato via script ufficiale (`install.sh`,
      non interattivo di suo), attivazione (`tailscale up`) rimandata a un
      servizio systemd oneshot dedicato al primo avvio reale (il demone
      deve girare per davvero, cosa impossibile dentro il chroot
      dell'autoinstall) — auth key chiesta da `prepare-autoinstall.sh`,
      opzionale: se lasciata vuota il pacchetto resta installato ma non
      attivato — **appena aggiunto, da testare**
- [x] USBGuard (controllo di accesso USB, policy generata sui dispositivi
      già connessi) + il notificatore desktop personalizzato di Antonio
      (`usbguard-notifier`, fork proprio) — **VALIDATO** installandolo a
      mano sulla partizione Ubuntu dello zenbook (4 bug trovati e già
      corretti nel `.tpl`), manca il test end-to-end via autoinstall
      completo
- [x] Podman (rootless) + wrapper CLI Docker (`podman-docker`) + "docker
      compose" reale (`docker-compose-v2`), senza installare il vero
      Docker Engine — **appena aggiunto, da testare**
- [x] Limine come bootloader SECONDARIO (voce EFI aggiuntiva, messa per
      prima nell'ordine di avvio) accanto a GRUB, che resta installato e
      raggiungibile dal firmware come rete di sicurezza — niente Secure
      Boot (disattivo per questa installazione), compilato da sorgente
      (nessun pacchetto apt su Ubuntu/Debian). Include
      `limine-snapshot-sync`, una nostra reimplementazione leggera in bash
      (non un porting del progetto Java/GraalVM originale, vedi "Note
      tecniche") dell'equivalente di grub-btrfs per il menu di Limine, con
      voci snapshot raggruppate in una directory `/+Snapshots` (vista ad
      albero) e branding/palette colori dedicati. **Boot reale VALIDATO
      sullo Zenbook di Antonio** (script 17 e 18 eseguiti con successo,
      dopo aver risolto in corsa dipendenze di build mancanti, il limite
      di Limine a soli FAT32/ISO9660, e un problema di permessi sull'ESP
      — vedi "Note tecniche"); non ancora verificato un boot reale da una
      voce "Snapshot #N" né un `apt upgrade` con nuovo kernel. Script
      standalone equivalenti in `scripts/17-install-limine.sh` e
      `scripts/18-limine-snapshot-sync.sh` per un sistema già installato.
- [x] `live-iso/`: respin della ISO ufficiale in una vera ISO **live**
      custom (remix), non solo un autoinstall — sessione live navigabile
      con gran parte del software della ricetta già installato prima di
      decidere se installare (vedi `live-iso/README.md` per scope
      completo, cosa resta escluso e perché) — **ALTO RISCHIO, NON
      TESTATO a scala reale**. Primo tentativo fallito su hardware reale
      (assumeva un solo `filesystem.squashfs`, schema ormai superato):
      corretto dopo aver letto i sorgenti ufficiali di casper/livecd-rootfs
      — il filesystem live è a 3 layer overlay, le modifiche vanno solo nel
      layer "standard" (vedi "Note tecniche"). La meccanica di
      estrazione/ricostruzione ISO (xorriso + squashfs-tools) resta
      validata solo su un filesystem/ISO sintetici di pochi KB, mai su una
      ISO Ubuntu reale (~6GB) né con i 3 layer veri; da provare su una
      macchina con 20-25GB liberi e tempo prima di fidarsene per la demo.
      La ISO ufficiale + l'autoinstall
      singolo (`disk-setup/`) resta l'opzione a basso rischio già rodata,
      in caso il remix non sia pronto in tempo.
- [x] Planify (`io.github.alainm23.planify`) e Paper (fork privato
      `paper-rs` se raggiungibile via SSH, altrimenti l'upstream ufficiale
      `codeberg.org/zagura/paper-notes`, marcato "discontinued" dall'autore
      originale) compilati da sorgente, con icone custom Promemoria/Note al
      posto di quelle upstream — `scripts/26-planify-paper-install.sh`.
      Verificato in sandbox (Ubuntu 24.04): Paper compila ed installa
      end-to-end (con un fix reale a un pin di versione errato di
      libadwaita in `src/meson.build`); Planify richiede libadwaita
      >= 1.7.0 (non verificabile in sandbox, dovrebbe essere soddisfatto da
      Ubuntu 26.04). **Non ancora verificato end-to-end su Ubuntu 26.04
      reale né integrato nell'autoinstall** — vedi "Prossimi step".

Il test in VM completo (disco + software + dash + estensioni + zram +
snapshot) è andato a buon fine. Dal dconf della VM dopo il test sono
emersi due aggiustamenti, già applicati:

- **`dash-to-dock@micxgx.gmail.com` non viene più scaricata**: Ubuntu
  26.04 porta già di suo `ubuntu-dock@ubuntu.com` (un fork con lo stesso
  schema dconf) insieme ad altre due estensioni di default
  (`ding@rastersoft.com`, `tiling-assistant@ubuntu.com`) che compaiono da
  sole al primo avvio reale; GNOME Shell disabilita comunque in automatico
  la nostra per conflitto, quindi installarla era solo un download
  sprecato. Le nostre impostazioni per quello schema restano e si
  applicano a `ubuntu-dock`.
- Aggiunta la chiave `disable-overview-on-startup` mancante nelle
  impostazioni dash-to-dock/ubuntu-dock, e scritto esplicitamente anche il
  nuovo percorso dconf `org/gnome/desktop/applications/terminal` (lo
  schema legacy `org.gnome.desktop.default-applications.terminal` è
  deprecato in GNOME 49/50 — vedi "Note tecniche").

Prossimo passo: rigenerare `autoinstall.yaml` (il `.tpl` è cambiato ancora,
per USBGuard + notificatore) e rifare un test in VM per confermare anche
questi, poi verifica di dettaglio (`test-vm/verify-test-vm.sh`, check
manuale di Brave/Ghostty/Nautilus/rimozione Firefox/`snapper
list-configs`/voce "Snapshots" nel menu GRUB/`usbguard list-devices`/
notifiche USB), poi prova su hardware reale prima della demo del 17.

**Bootloader**: GRUB resta il bootloader principale, ma abbiamo aggiunto
Limine come voce EFI SECONDARIA (Limine primario nell'ordine di avvio,
GRUB raggiungibile dal firmware come rete di sicurezza se qualcosa non
va) — deciso di procedere nonostante il rischio di scrivere da zero,
dentro un `late-commands` non interattivo, l'equivalente dell'automazione
che su CachyOS/Zenbook Antonio ha già pronta via hook pacman. Include
anche una nostra reimplementazione in bash (non un porting) dell'analogo
di grub-btrfs per il menu di Limine (`limine-snapshot-sync`, vedi "Note
tecniche" per i dettagli), con le voci snapshot raggruppate in una
directory ad albero (`/+Snapshots`). **Boot reale VALIDATO sullo Zenbook**
(non solo build/generazione config: il sistema si avvia davvero da
Limine) — resta da verificare un boot reale da una voce "Snapshot #N" e
un `apt upgrade` con nuovo kernel. GRUB resta comunque la scelta sicura
per la demo del 17 come rete di sicurezza.

**Howdy (sblocco con webcam)**: integrato su richiesta esplicita di Antonio
(inizialmente rimandato a dopo il 17, poi anticipato). Compilato da
SORGENTE anziché dalla PPA ufficiale (`ppa:boltgolt/howdy`): non esiste
ancora una build per Ubuntu 26.04 (issue upstream `boltgolt/howdy#1097`,
aperta da marzo 2026, mai una risposta del maintainer — un utente riporta
successo con una PPA di terzi non ufficiale, scartata qui per non
introdurre una fonte non verificabile). **ATTENZIONE**: la compilazione di
dlib è lunga (l'upstream stesso avverte "can hang on 100% for over a
minute") — allunga sensibilmente il tempo dell'autoinstall. Resta un bug
noto e ancora aperto upstream (`boltgolt/howdy#1104`, nessuna risposta del
maintainer): su Ubuntu 26.04/GNOME 50 il modulo PAM di Howdy blocca in un
modale non chiudibile la finestra di sblocco di Impostazioni→Utenti,
perché quella finestra passa dal servizio PAM `polkit-1`, che erediterebbe
Howdy tramite l'inclusione di `common-auth` fatta da `pam-auth-update`.
**Mitigato** (non risolto upstream) inserendo nel frammento
`pam-configs/howdy` una riga `pam_succeed_if.so` che salta Howdy quando il
service è `polkit-1` (tecnica standard PAM, vedi `man pam_succeed_if`,
sezione ESEMPI) — login/lock screen/sudo restano protetti dal
riconoscimento facciale, solo Impostazioni→Utenti passa direttamente alla
password. **NON verificato su hardware reale** (nessun vero
polkit/gnome-control-center disponibile in sandbox): il rischio di un
blocco visibile durante la demo non è escluso, va confermato sull'hardware
di Antonio **prima** del 17. L'enrollment del volto (`sudo howdy add`)
richiede una webcam reale: nell'autoinstall è rimandato a una voce
autostart al primo login (si autorimuove dopo l'esecuzione, stesso schema
già usato per Wayland Scroll Factor); nello script standalone
(`scripts/27-howdy-facial-auth.sh`) avviene direttamente, interattivo.
Come da avviso upstream, Howdy non è mai l'unico metodo di autenticazione:
in caso di volto non riconosciuto si scende sempre alla password.

**Sblocco disco automatico via TPM2 — CONFERMATO FUNZIONANTE su hardware
reale** (`scripts/19-tpm2-autounlock.sh`, richiesto da Antonio, non ancora
nell'autoinstall — script standalone per un sistema già installato):
sostituisce `initramfs-tools` con `dracut` (l'unico modo reale su Ubuntu
oggi per uno sblocco TPM2 in initramfs — il hook `cryptsetup-initramfs` di
Ubuntu ignora silenziosamente l'opzione `tpm2-device=`, bug Ubuntu #1980018
mai risolto; dracut è comunque supportato ufficialmente in parallelo su
26.04, non un hack). La password LUKS2 esistente NON viene rimossa, resta
sempre disponibile come sblocco manuale di riserva. Binding **PCR 0+4**
(firmware + bootloader misurato dal firmware stesso): funziona avviando da
Limine (che non fa ALCUNA misurazione TPM propria, confermato dal suo
stesso maintainer — è il firmware a misurare PCR 4), non da GRUB (misura un
valore diverso, resta protetto dalla password manuale). Testato sullo
Zenbook di Antonio: riavvio da Limine, nessuna richiesta di password —
sblocco automatico riuscito. Diagnosi in corsa di due bug reali durante il
test (vedi "Note tecniche"): un bug interno di `dracut --regenerate-all`
nella scelta automatica del percorso di output, e un effetto collaterale
sulle voci snapshot di Limine (marcatori mancanti in
`scripts/17-install-limine.sh`, richiamato in coda da questo script).

**iCloud Drive su Linux** (`scripts/21-icloud-nautilus-status.sh`, non
ancora nell'autoinstall — dipende da
[icloud-linux](https://github.com/IsmaeelAkram/icloud-linux), progetto
terzo installato manualmente da Antonio, non da questa ricetta): in
origine solo un'estensione Nautilus (emblema di stato sulla cartella di
mount, voce di menu, etichetta dinamica sul segnalibro "iCloud" — vedi
dettagli in "Note tecniche"), **RISCRITTO in una sessione successiva** per
fare anche il lavoro più grosso: patcha `driver.py` di icloud-linux per
passare da un crawl ricorsivo completo all'avvio a un'elencazione
ON-DEMAND per cartella (stesso comportamento di Finder/Files.app su
macOS — `ls ~/iCloud` elenca solo i figli diretti, una cartella si scarica
solo quando la si apre). Con questo cambiamento la lunga attesa "cartella
vuota per minuti/ore" prima del mount sparisce, quindi l'estensione
Nautilus non ha più bisogno del meccanismo di placeholder pre-mount: si
limita a riflettere in tempo reale quale cartella sta venendo elencata e
quale file scaricato. Script idempotente (confronta un checksum del
`driver.py` patchato con quello su disco, installa solo se diverso, con
backup e verifica di compilazione post-copia). **Emblema ed etichetta del
segnalibro erano CONFERMATI funzionanti su hardware reale** nella versione
precedente (screenshot di Antonio); il nuovo comportamento on-demand e la
patch a `driver.py` **non sono ancora stati verificati su hardware
reale**. Il dettaglio completo di rationale/verifiche è nell'header del
file — vedi "Note tecniche" sotto solo per la storia della prima versione
(emblema/etichetta segnalibro), che resta accurata.

## Prossimi step (non ancora implementati)

- [ ] Howdy (sblocco con webcam) — integrato nel `.tpl` e in
      `scripts/27-howdy-facial-auth.sh` (vedi "Stato attuale"), ma **non
      ancora testato su hardware reale**: build da sorgente mai completata
      fuori sandbox, workaround per il bug Impostazioni→Utenti/polkit-1
      non verificato, enrollment del volto mai provato con una webcam
      reale. Priorità alta da confermare prima del 17/09, considerando
      anche i tempi di compilazione lunghi di dlib.
- [ ] Sblocco TPM2 (`scripts/19-tpm2-autounlock.sh`) — CONFERMATO
      funzionante su hardware reale, non ancora integrato nell'autoinstall;
      restano da verificare un `apt upgrade` con nuovo kernel e il
      comportamento dopo un aggiornamento firmware/ricompilazione di Limine
      (invalidano rispettivamente PCR 0 e PCR 4)
- [ ] Riverificare che le voci snapshot siano tornate visibili nel menu di
      Limine dopo il fix ai marcatori in `scripts/17-install-limine.sh`
      (vedi "Note tecniche")
- [x] Emblema e etichetta del segnalibro della prima versione di
      `scripts/21-icloud-nautilus-status.sh` — ENTRAMBI CONFERMATI
      funzionanti sullo Zenbook di Antonio
- [ ] Testare su hardware reale la versione RISCRITTA di
      `scripts/21-icloud-nautilus-status.sh`: la patch a `driver.py` per
      l'elencazione on-demand per cartella e l'estensione Nautilus
      semplificata di conseguenza — non ancora verificate fuori sandbox
- [ ] Testare il nuovo campo `identity.realname` (Nome e Cognome mostrato da
      GDM) e `scripts/22-flatpak-git-eza-ghostty.sh` (Flatpak, git, eza,
      config Ghostty) — né in VM né su hardware finora
- [ ] `scripts/23-icloud-notes-reminders-deps.sh`: da confermare con
      Antonio se va ancora tenuto (dipendenze per un'app nativa mai
      scritta, probabilmente superata da `icloud-md`, vedi sopra) o va
      rimosso
- [ ] Testare in sessione reale il login 2FA di `icloud-md`
      (`scripts/24-icloud-notes.sh`): finora solo verificato che
      compila/gira, mai autenticato per davvero contro un account iCloud
      reale
- [ ] Testare `scripts/26-planify-paper-install.sh` (Planify + Paper da
      sorgente, icone custom) su Ubuntu 26.04 reale: build completa non
      verificata end-to-end con libadwaita >= 1.7 (bloccata in sandbox su
      Ubuntu 24.04) né il clone SSH del fork privato `paper-rs` — non
      ancora integrato in `disk-setup/autoinstall.yaml.tpl`
- [ ] Wizard di configurazione servizi preferiti (cloud, posta, streaming...)
- [ ] Altre app "stock" da sostituire (da definire)

## Uso

```bash
git clone <questo-repo> ubuntu-ultimate
cd ubuntu-ultimate
chmod +x install.sh scripts/*.sh
./install.sh
```

Oppure per testare un singolo step:

```bash
./scripts/11-install-brave.sh
```

Lo script **non va lanciato con `sudo`**: chiede la password quando serve
(alcuni comandi girano come utente normale per scrivere correttamente le
preferenze in `~/.config`).

## Note tecniche

- **icloud-linux + Nautilus (`scripts/21-icloud-nautilus-status.sh`)**:
  progetto terzo giovane ([issue tracker](https://github.com/IsmaeelAkram/icloud-linux/issues)
  con bug aperti su deadlock di enumerazione e race condition nel crawl in
  background). Non espone nessun IPC per lo stato corrente — l'unico canale
  è il file di log (`~/.local/state/icloud-linux/icloud.log`, path del
  mount letto da `~/.config/icloud-linux/icloud.env`, chiave
  `ICLOUD_MOUNT=`, NON in `config.yaml`). L'estensione Nautilus deduce lo
  stato ("syncing"/"error"/niente) rileggendo la coda del log ogni 5s con
  regex sulle stringhe di log reali (verificate leggendo `driver.py`:
  `"Remote metadata crawl progress: ..."`, `"Background cache warmup
  progress: ..."`, `"Upload loop failed: ..."`, ecc.) — un'attività più
  vecchia di 30s è considerata ferma, un errore più vecchio di 5 minuti
  smette di contare. Stesso schema di aggiornamento delle estensioni
  Nautilus di Dropbox/Nextcloud: `GLib.timeout_add_seconds` per il polling
  periodico + `file_info.invalidate_extension_info()` per far richiedere a
  Nautilus informazioni fresche (altrimenti l'emblema non cambierebbe mai
  dopo il primo caricamento). Riusato lo stesso fix già trovato per
  `nautilus-snapper-restore` in questa ricetta: `gi.require_version` va
  dentro un `try/except ValueError`, perché Nautilus può aver già caricato
  un'altra versione del proprio namespace GI (confermato reale su Ubuntu
  26.04). Emblemi usati: `emblem-synchronizing-symbolic` ed
  `emblem-important-symbolic`, entrambi presenti nel set di icone
  simboliche di Yaru (verificato). **L'emblema e l'etichetta del segnalibro
  sono confermati funzionanti su hardware reale** (screenshot di Antonio:
  cerchio di sync visibile sull'icona di `~/iCloud` nella vista Home, ed
  etichetta "iCloud (... sync...)" nella barra laterale).
  Sulle richieste successive di Antonio — un'icona vera nella barra
  laterale e un messaggio al posto di "La cartella è vuota" — nessuna delle
  due ha un'API di estensione dedicata, verificato prima di scrivere
  codice: (1) non esiste NESSUNA API dedicata, né in nautilus-python né in
  Nautilus stesso, per disegnare un *emblema/overlay* su una riga della
  barra laterale (`GtkPlacesSidebar`) — confermato da un maintainer di
  Nautilus (António Fernandes) su [discourse.gnome.org](https://discourse.gnome.org/t/how-to-customize-bookmark-icon-in-nautilus-sidebar/12020):
  "It's not currently possible, but it's a nice idea to consider for the
  sidebar redesign!". **Tentato un aggiramento e poi scartato dopo un test
  reale**: esiste un meccanismo più generale a livello di GIO/GVfs che la
  barra laterale eredita automaticamente (l'icona di una riga bookmark
  viene presa interrogando l'attributo `standard::symbolic-icon` del file,
  verificato leggendo direttamente il sorgente di `gtkplacessidebar.c`,
  funzione `on_bookmark_query_info_complete`) — lo STESSO meccanismo usato
  dalla funzione nativa "Cambia icona" di Nautilus (metadato GVfs
  `metadata::custom-icon-name`, impostabile con
  `gio set -t string <cartella> metadata::custom-icon-name <nome-icona>`).
  Provato a cambiare questo metadato in sincrono con l'emblema, ma **il
  test su hardware reale (screenshot di Antonio) ha mostrato che sostituiva
  del tutto l'icona della cartella**, facendole perdere forma e colore
  (restava solo l'icona di sync "a galleggiare", senza sfondo, diversa da
  tutte le altre cartelle arancioni) — non un'emblema/overlay come sperato,
  e comunque non un'animazione vera (`GtkPlacesSidebar` non anima icone
  personalizzate). **Rimosso**: il costo visivo non vale un effetto che
  comunque non sarebbe stato uno spinner reale. Resta quindi solo
  l'etichetta testuale dinamica sul segnalibro stesso, riscritta in
  `~/.config/gtk-3.0/bookmarks` — file usato anche dalle app GTK4 come
  Nautilus, perché il formato dei bookmark non è cambiato da GTK3
  (verificato sul sorgente di `gtkbookmarksmanager.c`: GTK riusa lo stesso
  file, non ne crea uno `gtk-4.0` separato). Il file è sorvegliato da GTK
  con un `GFileMonitor`, quindi la barra laterale si aggiorna da sola senza
  riavviare Nautilus — **confermato funzionante su hardware reale**.
  (2) non esiste nessuna API per sostituire il
  messaggio nativo "La cartella è vuota". Soluzione adottata: dato che
  PRIMA che icloud-linux monti davvero il filesystem FUSE, `~/iCloud` è
  ancora una normale cartella vuota di proprietà dell'utente (la scansione
  iniziale in `driver.py` è sincrona e avviene PRIMA della chiamata che
  monta), l'estensione ci scrive dentro un file di testo reale con lo
  stato aggiornato ogni 5s; appena icloud-linux monta il filesystem vero
  sopra lo stesso percorso, il placeholder viene automaticamente oscurato
  dal mount (resta sul disco sottostante, ma non più visibile) — nessuna
  pulizia esplicita necessaria in quel momento, e l'estensione comunque
  controlla `os.path.ismount()` prima di scrivere per non toccare mai la
  cartella una volta che il mount reale è attivo. **Bug reale trovato dal
  log di Antonio dopo un uso prolungato**: su cartelle KNIME molto annidate
  (nomi con spazi/parentesi, es. "Spark Partitioning (#62)/port_1/object"),
  icloud-linux logga `WARNING - Timed out enumerating ... after 60s —
  skipping folder` quando una sottocartella non risponde entro 60s — la
  scansione NON si ferma, salta solo quella cartella e prosegue con la
  successiva, ma questo messaggio non era tra quelli riconosciuti da
  `_ACTIVITY_RE`: l'emblema/etichetta sparivano (tornavano a "fermo")
  anche se la sincronizzazione stava proseguendo per davvero. Aggravato dal
  fatto che ogni timeout richiede 60s pieni prima di essere scritto nel
  log, un gap più lungo della vecchia finestra di 30s usata per decidere
  se l'attività è "recente". Fix: aggiunto il pattern al riconoscimento di
  attività, e alzata `ACTIVITY_WINDOW_SECONDS` da 30 a 90 (margine sopra i
  60s del timeout); aggiunta anche una voce di dettaglio dedicata, così la
  voce di menu "Stato sincronizzazione iCloud…" mostra quale cartella è
  stata saltata invece di restare generica.
- **Note e Promemoria di iCloud NON sono VJOURNAL/VTODO** — verificato
  prima di progettare l'integrazione, non assunto. Le Note di Apple (via
  iCloud/CloudKit) non hanno mai usato CalDAV: sono record CloudKit
  proprietari con payload serializzato `NSKeyedArchiver` (binary plist) e
  dati "mergeable" cifrati lato client, senza alcun formato iCalendar
  coinvolto (confermato dall'analisi forense di
  [ciofecaforensics.com](https://www.ciofecaforensics.com/2020/10/20/apple-notes-cloudkit-data/), che
  ha dovuto scrivere un parser Ruby ad hoc perché nessun decoder standard
  funzionava). I Promemoria invece USAVANO CalDAV/VTODO in passato, ma
  Apple lo ha rimosso: da iOS 13/macOS Catalina in poi, l'app Promemoria
  "aggiornata" migra le liste fuori da CalDAV in uno store CloudKit
  proprietario separato — le vecchie liste CalDAV restano accessibili ma
  sono ORMAI UN NEGOZIO DIVERSO, scollegato: modificare una lista CalDAV
  legacy non aggiorna più i Promemoria veri usati oggi, e viceversa
  (confermato da [busymac.com](https://www.busymac.com/docs/faqs/112990-reminders-in-ios-13-and-macos-catalina-drops-support-for-caldav/),
  che per questo offre "direct Reminders syncing" come alternativa a
  CalDAV). Conseguenza pratica per l'integrazione: leggere Note/Promemoria
  richiede parlare con CloudKit stesso (come fa `icloud-linux` per iCloud
  Drive, o come i tool di terze parti tipo `icloud-md`/
  `apple_cloud_notes_parser` che decodificano questi stessi payload
  proprietari), non un client CalDAV standard — approccio scelto: vedi la
  voce successiva su `icloud-md`.
- **Lettura reale delle Note tramite `icloud-md` (`scripts/24-icloud-notes.sh`)**
  — valutate tre alternative prima di scegliere: (1) `pyicloud` (Python),
  che gestisce benissimo login+2FA (`requires_2fa` /
  `validate_2fa_code` / `trust_session`) ma non copre le Note in nessun
  modo — nessun endpoint da chiamare, non è un limite dello script ma
  della libreria; (2) una reimplementazione Python da zero di un client
  CloudKit privato (auth SRP + protobuf reverse-engineered) — fattibile in
  teoria ma un progetto di reverse engineering serio, non uno script, con
  alto rischio di rottura a ogni cambio lato Apple; (3) **scelta fatta**:
  usare [`icloud-md`](https://github.com/coddingtonbear/icloud-md) come
  motore. Uno script unico (`24-icloud-notes.sh` — unifica i precedenti
  `24-icloud-notes-md-setup.sh` + `25-icloud-notes-list.py`, ora rimossi)
  installa Node.js via repository NodeSource (i pacchetti Ubuntu sono
  troppo vecchi, icloud-md richiede Node 20+), `icloud-md` via npm e
  Chromium per Playwright, poi fa `icloud-md clone`/`pull` (login con 2FA
  reale — un vero browser Chromium pilotato da Playwright, è Apple stessa
  a gestire password/2FA/eventuali sfide anti-bot, non un flusso
  reverse-engineered) scaricando le note per davvero in `~/Notes`, e le
  elenca con `--json` per output machine-readable. Introduce Node.js come
  dipendenza nella ricetta (finora tutto era apt/Python/Rust), compromesso
  accettato esplicitamente da Antonio per avere un'integrazione che legge
  davvero i contenuti, invece di una che si autentica ma non può leggere
  nulla.
- **Nome e Cognome (GDM) + Flatpak/git/eza/Ghostty
  (`scripts/22-flatpak-git-eza-ghostty.sh`)**: `identity.realname` è un
  campo ufficiale dello schema autoinstall di Subiquity (GECOS a livello di
  sistema — verificato sulla documentazione ufficiale), che GDM mostra al
  posto dello username quando valorizzato; `prepare-autoinstall.sh` lo
  chiede insieme all'email per git, e riusa lo stesso Nome e Cognome per
  `git config --global user.name` (per non chiederlo due volte). I comandi
  per eza (repository apt di terze parti di eza-community, deb.gierens.de)
  sono stati riverificati contro l'INSTALL.md ufficiale del progetto prima
  di embedderli: ancora corretti. Punto tecnico da non confondere in
  futuro: la chiave `language` di Ghostty NON è il layout di tastiera —
  controlla la lingua dei testi della SUA interfaccia grafica (richiede
  GTK e Ghostty 1.3+, verificato sulla documentazione ufficiale di
  ghostty.org), non ha alcun effetto su come si scrive nel terminale.
  Il layout di tastiera resta quello di sistema (`keyboard: layout: it` in
  cima a `autoinstall.yaml.tpl`), che Ghostty eredita automaticamente senza
  bisogno di nessuna configurazione propria — impostato comunque
  `language = it` solo per coerenza con locale/tastiera del resto della
  ricetta. Il nome del tema builtin è cambiato da `catppuccin-mocha` a
  `Catppuccin Mocha` (con spazio e maiuscole) dalla versione 1.2.0 di
  Ghostty in poi — verificato prima di scriverlo nel file di config.
- **Wayland Scroll Factor (wsf)**: confermato (documentazione ufficiale
  GNOME + un articolo dedicato a Ubuntu 26.04 su UbuntuHandbook, luglio
  2026) che GNOME su Wayland non ha tuttora nessuna impostazione nativa,
  né in Impostazioni né come chiave gsettings/dconf, per la velocità dello
  scroll a due dita — wsf (github.com/daniel-g-carrasco/wayland-scroll-
  factor, ancora in fase di prototipo/richiesta di linee guida upstream su
  GNOME Discourse) è al momento il tool di terze parti più maturo per
  colmare la lacuna. Zona grigia lasciata esplicita: la documentazione del
  progetto non spiega il meccanismo interno di `wsf enable` (non usa
  `/etc/ld.so.preload`, dichiara solo "preload guardato dentro
  gnome-shell" + necessità di logout/login) né se funzioni in una sessione
  D-Bus finta come quella usata per gli altri gsettings di questa ricetta
  (`dbus-run-session`, senza un vero compositor Wayland dietro). Per non
  scommettere su un comportamento non documentato dentro il chroot
  dell'autoinstall, il pacchetto `.deb` e il file di configurazione
  (`~/.config/wayland-scroll-factor/config`, solo `scroll_vertical_factor`
  cambiato da 0.35 a 0.20) vengono scritti durante l'autoinstall, ma `wsf
  enable` viene rimandato a una voce autostart GNOME
  (`~/.config/autostart/`) che gira al primo login reale — con una vera
  sessione Wayland dietro, esattamente come se l'utente lo lanciasse a
  mano — e si autorimuove subito dopo. Non ancora verificato in pratica
  (né in VM né su hardware): da controllare alla prossima sessione di test
  che lo scroll risulti effettivamente più lento dopo il primo login.
- **TPM2 autounlock (`scripts/19-tpm2-autounlock.sh`)**: `systemd-cryptenroll`
  è lo strumento giusto, ma Ubuntu con `initramfs-tools` (il generatore di
  default) NON supporta l'opzione `tpm2-device=` in `/etc/crypttab` per la
  root — bug Ubuntu #1980018, mai risolto, l'hook la ignora e torna a
  chiedere la password. Le due vie reali sono passare a `dracut` (supporto
  TPM2 nativo, ufficialmente disponibile in parallelo su Ubuntu 26.04) o
  aspettare la soluzione nativa di Canonical basata su Unified Kernel Image
  + Secure Boot obbligatorio (in arrivo da Ubuntu 25.10, incompatibile con
  Limine che non supporta Secure Boot) — scelto `dracut`. Verificato dai
  contenuti reali dei pacchetti `.deb`: l'hook `/etc/kernel/postinst.d/dracut`
  scrive comunque `/boot/initrd.img-<versione>` (stessa convenzione Debian,
  non lo stile Fedora `initramfs-<versione>.img`), quindi GRUB e la nostra
  logica di lettura di `/boot/vmlinuz`/`/boot/initrd.img` (symlink) restano
  compatibili senza modifiche. `dracut` ha `Conflicts: initramfs-tools`
  (rimozione automatica via apt, non un autoremove "morbido"); `cryptsetup-initramfs`
  resta installato senza conflitti (soddisfa la sua dipendenza alternativa
  tramite `Provides: linux-initramfs-tool` di dracut) e semplicemente non fa
  più nulla. Scelta del PCR: NON PCR 11 (convenzione systemd-boot/UKI per
  misurare una Unified Kernel Image, che qui non usiamo), NON PCR 7/8/9
  (richiedono Secure Boot attivo, o sono estesi solo da GRUB — inutili se
  si vuole che lo sblocco funzioni con qualunque bootloader). Usati PCR 0
  (firmware) **+ PCR 4** (codice del bootloader): PCR 4 lo estende il
  FIRMWARE, non Limine, ogni volta che carica un eseguibile EFI di boot — e
  siccome Limine non misura nulla di suo (confermato da una discussione dei
  maintainer di fwupd, "Limine does not do TPM2 PCR Measurements... unlike
  GRUB and systemd-boot"), il valore che ne risulta è specifico del binario
  `BOOTX64.EFI` caricato. **Conseguenza voluta**: lo sblocco automatico
  funziona SOLO avviando da Limine (protegge anche da un binario Limine
  sostituito sull'ESP); avviando dal GRUB di riserva la password viene
  comunque richiesta, come oggi — nessuna regressione sul percorso di
  fallback. Resta comunque vero che senza Secure Boot non c'è modo di
  rilevare un kernel/initrd manomesso caricato dallo stesso Limine
  invariato. `rd.luks.uuid=` (sintassi cmdline di dracut) aggiunto sia alla
  cmdline di GRUB (`GRUB_CMDLINE_LINUX` via sed idempotente) sia a quella di
  Limine (già generata da `17-install-limine.sh`, che questo script
  richiama a fine esecuzione), accanto al `cryptdevice=` esistente (sintassi
  initramfs-tools) — innocuo tenerli entrambi. **Bug reale trovato testando
  su hardware (Zenbook), diagnosi corretta al secondo giro** (il primo
  tentativo di fix, un `/etc/kernel/install.conf` con `layout=other`
  ipotizzando un coinvolgimento di `kernel-install(8)`, non ha risolto —
  causa sbagliata): letto il sorgente reale di `/usr/bin/dracut` (pacchetto
  `dracut-core`). Senza un file di output esplicito, `dracut --regenerate-all`
  lascia decidere a dracut stesso dove scrivere, con una catena di controlli
  in cascata (esistenza di `/boot/vmlinuz-<versione>`, poi di un mountpoint
  `/boot/efi`, ecc.); quando la condizione attesa (`/boot/vmlinuz-<versione>`
  presente) non è quella che risulta vera, l'ultima condizione rimasta è
  "l'ESP è montata su `/boot/efi`", e dracut sceglie di scrivere in stile
  Boot Loader Specification dentro `${ESP}/<machine-id>/<versione>/initrd` —
  una struttura che qui non esiste — fallendo con "Can't write to
  .../<machine-id>/<versione>: ... does not exist". Il vero hook
  `/etc/kernel/postinst.d/dracut` installato dal pacchetto (che gestisce i
  PROSSIMI aggiornamenti kernel) non soffre di questo problema perché passa
  SEMPRE un output esplicito — verificato leggendo il file reale nel
  pacchetto `.deb`: `dracut -q --force /boot/initrd.img-<versione>
  <versione>`. Fix definitivo: lo script replica esattamente questo stesso
  comando, per ogni kernel installato, invece di affidarsi all'euristica
  automatica di `--regenerate-all` — elimina il problema alla radice, senza
  dipendere da assunzioni sull'ambiente.
- **Progresso download ISO in `test-vm/create-test-vm.sh`**: l'output nativo
  di aria2c (tabelle ASCII + colori, riscritte periodicamente) può uscire
  duplicato o coi codici non renderizzati in alcuni terminali. Da
  `scripts/lib/common.sh` la funzione `download_with_progress()` lancia
  aria2c in background con `--quiet=true` e disegna lei una barra di
  progresso vera (`_progress_bar_line()`: `[####----] 42%  2.5GiB/6.0GiB
  6.2MiB/s  ETA 12m34s (3m10s)`), aggiornata ogni secondo sul posto se il
  terminale è interattivo o una riga al secondo altrimenti; se aria2c
  finisce quasi subito (es. file già completo da un tentativo precedente)
  stampa comunque una riga finale pulita a "fatto" invece di restare
  bloccata a "0.0B/s ETA --"; in caso di errore mostra le ultime righe del
  log di aria2c.
- **Scelta automatica del mirror ISO più veloce**: invece di un mirror fisso
  (es. GARR, che può avere giornate lente), `pick_fastest_mirror()` in
  `scripts/lib/common.sh` scarica ~8MB (range request, oltre lo slow-start
  TCP) da una lista di mirror candidati e sceglie quello più veloce al
  momento. Lista di default in `DEFAULT_ISO_MIRRORS` in
  `test-vm/create-test-vm.sh` (GARR, Init7, RWTH Aachen, xTom DE,
  mirrorservice.org UK, releases.ubuntu.com), personalizzabile con
  `ISO_MIRRORS="https://a/... https://b/..."`; per saltare del tutto il test
  e forzare un mirror fisso resta disponibile `ISO_MIRROR=https://...` (come
  prima). Il test parte solo se l'ISO non è già scaricata/verificata.
- **Terminale predefinito (GNOME 49/50)**: la chiave storica
  `org.gnome.desktop.default-applications.terminal` è deprecata e ignorata
  ("The default terminal is handled in GIO", dal codice sorgente di
  `gsettings-desktop-schemas`) — continuiamo a scriverla per compatibilità
  ma il percorso che conta davvero ora è
  `org/gnome/desktop/applications/terminal`, scritto direttamente con
  `dconf write` (non ha uno schema gsettings compilato installato di
  default, quindi `gsettings set` fallirebbe).
- **Firefox** è distribuito su Ubuntu come snap; lo rimuoviamo con
  `snap remove --purge` e blocchiamo il pacchetto apt di transizione con
  `apt-mark hold` per evitare reinstallazioni accidentali.
- **Brave** viene installato dal repository apt ufficiale
  (`brave-browser-apt-release.s3.brave.com`), non da Flatpak/Snap, per avere
  aggiornamenti automatici via `apt upgrade` in linea con il resto del
  sistema.
- **Ghostty** è entrato nei repository *universe* di Ubuntu con la 26.04:
  lo installiamo direttamente da apt (nessuna PPA di terze parti
  necessaria) e lo agganciamo sia al meccanismo `update-alternatives`
  (`x-terminal-emulator`) sia alla chiave GNOME
  `org.gnome.desktop.default-applications.terminal`, così qualunque punto
  del desktop che apra "il terminale" apre Ghostty.
- **"Apri nel terminale" di Nautilus è un caso a parte**: l'azione
  integrata di Nautilus è hardcoded su GNOME Terminal e non legge la
  chiave `org.gnome.desktop.default-applications.terminal` (lo conferma
  il maintainer di Nautilus stesso). Non serve però nessuna estensione di
  terze parti: il pacchetto apt `ghostty` di Ubuntu 26.04 porta già di suo
  un'estensione Nautilus nativa (`/usr/share/nautilus-python/extensions/
  ghostty.py`, adattata da quella di WezTerm) che aggiunge una voce "Apri
  in Ghostty" con `--working-directory` e `--gtk-single-instance=false`
  già impostati da lei. Basta installare `python3-nautilus` perché
  Nautilus la carichi. (In precedenza usavamo `nautilus-open-any-terminal`
  via pip: con l'estensione nativa ora presente in 26.04 produceva due
  voci duplicate nel menu, quindi l'abbiamo tolta.)
- **Tailscale**: installato con lo script ufficiale
  (`curl -fsSL https://tailscale.com/install.sh | sh`), che aggiunge da solo
  repo+chiave e installa il pacchetto senza alcun prompt — a differenza di
  Brave/Ghostty non usiamo un repository apt configurato a mano, per
  semplicità (è il metodo raccomandato da Tailscale stesso ed è comunque
  gestito da apt una volta installato). L'attivazione vera e propria
  (`tailscale up --auth-key=...`) NON può però avvenire dentro il chroot
  dell'autoinstall: serve il demone `tailscaled` realmente in esecuzione
  (rete, systemd attivo), quindi è delegata a un servizio systemd oneshot
  separato (`ubuntu-ultimate-tailscale-up.service`), sullo stesso modello
  già usato per la rimozione di Firefox al primo avvio reale — tenuto
  deliberatamente come unità a sé (non unito a quello di Firefox) così un
  problema nell'uno non blocca l'altro. L'auth key è raccolta da
  `prepare-autoinstall.sh` (opzionale: se lasciata vuota il pacchetto resta
  installato ma non attivato, nessun errore) e trattata come segreto
  esattamente come la passphrase LUKS e l'hash della password — finisce in
  chiaro nello stesso `autoinstall.yaml` con permessi 600.
- **Font, cosa è liberamente ridistribuibile e cosa no**: i font "core"
  storici di Microsoft (Arial, Times New Roman, Courier New, Georgia,
  Verdana, Comic Sans MS, Impact, Trebuchet MS, Andale Mono, Webdings)
  sono liberi sotto un'EULA specifica del 1996 ("TrueType core fonts for
  the Web") — `ttf-mscorefonts-installer` (multiverse) li scarica e
  installa da solo, EULA accettata non interattivamente con
  `debconf-set-selections` (`msttcorefonts/accepted-mscorefonts-eula
  select true`) prima dell'apt-get. I font più recenti di Office (Calibri,
  Cambria, Candara, Consolas, Constantia, Corbel) NON sono coperti da
  quella EULA e restano proprietari: installiamo invece Carlito e Caladea
  (licenza OFL), sostituti liberi metric-compatible byte per byte con
  Calibri e Cambria (stessa tecnica già usata da LibreOffice/Google Docs),
  così un documento impaginato con l'uno o l'altro resta identico a video
  e in stampa. JetBrains Mono è pacchettizzato ufficialmente su Ubuntu
  (`fonts-jetbrains-mono`, licenza OFL). Hack Nerd Font non è in nessun
  repository Ubuntu: scaricato dalla release ufficiale del progetto
  nerd-fonts (`releases/latest/download/Hack.zip`, licenza MIT) e
  installato in `/usr/local/share/fonts/` (sistema, non home di un
  utente). **SF Pro (macOS) è intenzionalmente escluso dalla ricetta**: la
  licenza Apple (Apple Font License Agreement,
  developer.apple.com/fonts/) limita l'uso di San Francisco alla
  progettazione di interfacce per piattaforme Apple e ne vieta la
  ridistribuzione, quindi niente mirror non ufficiali nell'autoinstall —
  chi lo vuole se lo scarica di persona da developer.apple.com/fonts/
  (serve un Apple ID) e lo installa con `scripts/14-install-fonts.sh
  /percorso/ai/font/estratti` su una macchina già in piedi.
- **ONLYOFFICE al posto di LibreOffice**: la rimozione è idempotente per
  costruzione — `dpkg-query -W -f='${Package}\n' 'libreoffice*'` elenca i
  pacchetti libreoffice DAVVERO installati (non un elenco fisso scritto a
  mano, che rischierebbe di non far corrispondere esattamente il subset
  che Ubuntu Desktop preinstalla) e li purga solo se la lista non è vuota,
  altrimenti salta senza errori. ONLYOFFICE Desktop Editors viene dal
  repository apt ufficiale (chiave GPG `CB2DE8E5` recuperata dal keyserver
  Ubuntu, non da un mirror non ufficiale), non da Snap: stessa scelta già
  fatta per Brave/Ghostty/Tailscale, aggiornamenti automatici via
  `apt upgrade`. Le 3 voci `.desktop` (`onlyoffice-new-document`,
  `-spreadsheet`, `-presentation`) lanciano `/usr/bin/desktopeditors` con i
  flag `--new:word`/`--new:cell`/`--new:slide`, documentati da ONLYOFFICE
  stesso per aprire direttamente un file vuoto del tipo giusto invece della
  sola schermata "Start" dell'app. Icone: non quella generica di
  ONLYOFFICE, ma `x-office-document`/`x-office-spreadsheet`/
  `x-office-presentation` — nomi standard della freedesktop Icon Naming
  Specification, già forniti dal tema icone di default di Ubuntu (Yaru,
  verificato scaricando i sorgenti del tema) in tutte le risoluzioni:
  nessun asset esterno da scaricare o mantenere. Stessa logica anche in
  `live-iso/chroot-customize.sh`; script standalone equivalente in
  `scripts/15-onlyoffice.sh` per applicarla a una VM/macchina già in piedi.
- **Supporto APFS in sola lettura (`apfs-fuse`)**: nessun pacchetto apt su
  Ubuntu per leggere APFS (il filesystem di macOS dagli High Sierra in
  poi) — verificato: nessun risultato su packages.ubuntu.com per `apfs` o
  `linux-apfs`. Compiliamo `sgan81/apfs-fuse` da sorgente con lo stesso
  schema già usato per grub-btrfs (`git clone` + build + `make install`
  dentro le `late-commands`), con la differenza che qui c'è vero codice
  C++ da compilare (grub-btrfs installa solo script bash, non compila
  nulla). Un dettaglio del README ufficiale del progetto va corretto: elenca
  `gcc-c++` tra i pacchetti Debian/Ubuntu, ma è il nome usato da
  Fedora/RHEL — su Ubuntu quel pacchetto non esiste (verificato), quello
  giusto è `g++`. Altro problema reale trovato testando in VM: il cmake
  moderno di Ubuntu 26.04 ha rimosso la compatibilità con
  `cmake_minimum_required` sotto 3.5 (usato dal progetto e/o dal
  sottomodulo lzfse), quindi la configurazione falliva subito — risolto
  con `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`, il flag suggerito dallo stesso
  messaggio d'errore di cmake. Terzo problema reale trovato in VM: la
  compilazione falliva su `ApfsLib/PList.h` con `'uint8_t' does not name a
  type` — l'header usa `uint8_t`/`uint32_t` ma non include `<cstdint>`,
  contando sul fatto che arrivi per inclusione transitiva da `<memory>`
  (vero con compilatori più vecchi, non più con GCC 15 di Ubuntu 26.04,
  libstdc++ più rigorosa sugli include transitivi). Corretto iniettando
  l'include mancante subito dopo il clone, prima di compilare:
  `sed -i '1i #include <cstdint>' ApfsLib/PList.h`. **Sola lettura per scelta dello stesso progetto
  upstream**, non nostra: niente rischio di corrompere un disco Mac
  collegato per errore mentre lo si sfoglia. Deliberatamente NON
  aggiungiamo il supporto in scrittura (`linux-apfs-rw`, modulo kernel
  fuori-albero con scrittura sperimentale): richiederebbe DKMS + firma del
  modulo per Secure Boot, cioè un enrollment MOK interattivo al riavvio —
  impossibile da automatizzare in un autoinstall unattended, e comunque lo
  stesso progetto la definisce sperimentale. Uso: `apfs-fuse <device>
  <mountpoint>` da terminale. Quarto problema reale trovato: con
  `apfs-fuse` funzionante da terminale, Nautilus continuava a fallire
  provando ad automontare la partizione riconosciuta come `apfs` (via
  `blkid`) con `mount -t apfs`, che fallisce sempre perché non esiste
  nessun driver APFS nel kernel — è lo stesso errore "filesystem apfs non
  configurato nel kernel" visto anche da riga di comando quando si prova
  `mount -t apfs` invece di invocare direttamente `apfs-fuse`. Risolto con
  lo stesso meccanismo con cui `ntfs-3g`/`exfat-fuse` si integrano con
  `mount(8)` senza supporto kernel dedicato: un helper esterno
  `/sbin/mount.apfs` (verificato sul man `mount(8)`, sezione "EXTERNAL
  HELPERS": `mount` invoca automaticamente `/sbin/mount.<fstype>` se
  esiste, al posto del driver kernel) che fa da wrapper verso
  `apfs-fuse`, ignorando i flag booleani senza equivalente FUSE sensato
  (-s -f -n -v, -N, -t). Quinto problema reale trovato, questa volta
  testando l'helper in una vera sessione Nautilus: `udisksd[...]: fuse:
  unknown option(s): `-o uhelper=udisks2'`. Causa: udisks2 passa
  all'helper *tutte* le opzioni di mount, incluse quelle specifiche sue
  (`uhelper=udisks2`) o generiche del VFS
  (`nodev`/`nosuid`/`noexec`/`relatime`/...), senza sapere che la
  destinazione è un filesystem FUSE — libfuse (usata da `apfs-fuse`)
  rifiuta con `fuse: unknown option(s)` qualsiasi opzione che non
  riconosce. Risolto filtrando le opzioni in `/sbin/mount.apfs` prima di
  passarle a `apfs-fuse`: si tiene solo una whitelist di opzioni che
  libfuse/apfs-fuse capiscono davvero (`ro`, `rw`, `uid=`, `gid=`,
  `nonempty`) e si scarta silenziosamente tutto il resto. Sesto problema
  reale trovato subito dopo (una volta risolto il precedente, il mount
  riusciva ma Nautilus rispondeva "permessi non sufficienti"): udisks2
  monta sempre come **root** (demone privilegiato), e un filesystem FUSE
  montato da root è visibile di default solo a root stesso — serve
  esplicitamente `allow_other`. A differenza di NTFS/exFAT, `apfs` non è
  tra i filesystem "noti" a udisks2, quindi il demone non aggiunge da
  solo quell'opzione. Risolto forzando sempre `allow_other` nell'helper
  (indipendentemente da cosa passa udisks2): essendo root a montare,
  `allow_other` è sempre permesso senza dover toccare
  `/etc/fuse.conf`/`user_allow_other` (quella restrizione riguarda solo
  mount fatti da utenti non privilegiati). Con questi due fix,
  Nautilus/GVfs dovrebbero automontare la partizione APFS al doppio clic
  esattamente come farebbero con NTFS o exFAT — **ancora in attesa di
  conferma finale da Antonio che l'automount funzioni end-to-end**.
  Stessa logica anche in `live-iso/chroot-customize.sh`; script
  standalone equivalente in `scripts/16-install-apfs-fuse.sh`.
- **Dash**: impostata via `gsettings set org.gnome.shell favorite-apps` su
  Brave, File, Ghostty, Visualizzatore documenti (in quest'ordine). Per
  ogni app proviamo più nomi di file `.desktop` candidati, in ordine di
  preferenza, e usiamo il primo che risulta davvero presente in
  `/usr/share/applications` — utile perché GNOME sta sostituendo Evince
  con Papers, e non è garantito quale dei due sia quello installato di
  default su una data versione di Ubuntu.
- **Estensioni GNOME Shell**: installiamo 7 delle 8 abilitate sulla
  macchina di sviluppo di Antonio (badrobot) — `display-color-correct`,
  `Rounded_Corners`, `kiwi`, `kiwimenu`, `caffeine`, `Vitals`,
  `auto-theme-switcher`. **Non installiamo `dash-to-dock`**: un test in VM
  ha mostrato che Ubuntu 26.04 porta già di suo `ubuntu-dock` (fork con lo
  stesso schema dconf) insieme a `ding` (Desktop Icons NG) e
  `tiling-assistant`, prese automaticamente al primo avvio reale, e GNOME
  Shell disabilita comunque la nostra per conflitto — le impostazioni che
  avevamo per dash-to-dock restano comunque nello script e si applicano a
  `ubuntu-dock`, dato che condivide lo schema. A queste 7 abbiamo aggiunto
  un'ottava estensione non presa da badrobot: **Tailscale for GNOME**
  (`tailscale-gnome@diskmth.fr`,
  https://github.com/Disk-MTH/Tailscale-Gnome), un indicatore in Quick
  Settings per il Tailscale installato sopra — richiede solo la CLI
  `tailscale` (già presente) e `pkexec` (già di serie su Ubuntu). Tutte e
  8 vengono scaricate da extensions.gnome.org nella build compatibile con la
  versione di GNOME Shell effettivamente
  installata, e per le prime 7 applichiamo anche le impostazioni (estratte
  dal dconf di badrobot, solo le sezioni pertinenti; per Tailscale for
  GNOME usiamo i default, nessuna configurazione specifica necessaria). Se
  una singola estensione non ha ancora una build per una versione di
  GNOME Shell molto recente, viene
  saltata con un avviso, senza far fallire il resto dell'installazione.
  Alcune impostazioni (nome del connettore monitor, sensore ventola) sono
  legate all'hardware specifico di badrobot: su una macchina diversa
  quelle singole chiavi non troveranno semplicemente riscontro, senza
  causare errori. Il **Gestore delle estensioni** (`gnome-shell-extension-
  manager`) viene installato comunque, per gestirle da interfaccia
  grafica in futuro. Aggiornato anche `kiwimenu` per usare l'icona Ubuntu
  (`icon=8`, era `13`) e aggiunta la sezione dconf di `ding` (Desktop
  Icons NG, l'estensione di default di Ubuntu per le icone sul desktop)
  con `show-home=false`, per non mostrare l'icona Home sul desktop —
  entrambe prese dal dump dconf più recente di badrobot.
- **zram**: pacchetto ufficiale Ubuntu `systemd-zram-generator` (non
  abilitato di default nella 26.04, la comunità l'ha rimandato a versioni
  successive — vedi la discussione su discourse.ubuntu.com), configurato
  con compressione zstd e una dimensione pari a metà della RAM disponibile
  (`/etc/systemd/zram-generator.conf`).
- **Snapshot del disco (snapper + grub-btrfs)**: `snapper` (pacchettizzato
  su Ubuntu) crea/gestisce gli snapshot BTRFS nel subvolume `@snapshots`
  già esistente (creato durante la conversione del disco, non lo ricrea);
  `grub-btrfs` (non pacchettizzato — va compilato da sorgente via
  `make install`, come da documentazione ufficiale del progetto per
  Debian/Ubuntu) aggiunge una voce "Snapshots" al menu di GRUB da cui
  avviare direttamente uno snapshot precedente, utile per un rollback
  rapido dopo un aggiornamento andato storto. **Non abilitiamo**
  `GRUB_BTRFS_ENABLE_CRYPTODISK`: serve solo quando `/boot` vive dentro il
  volume cifrato, e nel nostro layout `/boot` è volutamente fuori da LUKS
  (vedi `disk-setup/README.md`) — GRUB non deve mai decifrare nulla per
  trovare kernel/initrd, nemmeno quelli di uno snapshot: la decifratura la
  fa sempre l'initramfs via cryptsetup, cambia solo il
  `rootflags=subvol=` nella riga di comando del kernel.
- **Limine, ripreso in considerazione e aggiunto come bootloader
  SECONDARIO** (la nota precedente in questo README lo dava per scartato:
  Antonio lo usa con successo su CachyOS sul proprio Zenbook, ma lì esiste
  già l'automazione — hook pacman — che sincronizza kernel/initrd sulla ESP
  a ogni aggiornamento, mentre su Ubuntu andrebbe scritta da zero). Deciso
  di procedere comunque, ma con GRUB tenuto come rete di sicurezza: Limine
  viene aggiunto come voce EFI aggiuntiva (messa per prima nell'ordine di
  avvio via `efibootmgr`, senza cancellare la voce "ubuntu" di shim+GRUB),
  non installato al posto di GRUB — se qualcosa nella configurazione di
  Limine non funziona, dal firmware si sceglie comunque "ubuntu" e si
  avvia normalmente. Nessun pacchetto apt `limine` esiste su Ubuntu/Debian
  (verificato: nessun risultato su packages.ubuntu.com/packages.debian.org,
  a differenza di Arch dove è pacchettizzato) — si compila dal sorgente
  ufficiale (`github.com/limine-bootloader/limine`, branch `v12.x`),
  abilitando solo la porta UEFI x86-64 (`./configure --enable-uefi-x86-64
  --disable-bios ...`): niente Secure Boot per questa installazione (resta
  disattivo in firmware), quindi niente bisogno di firmare Limine o
  arruolare una chiave MOK. LUKS2 non richiede alcun supporto speciale da
  parte di Limine: lo sblocco lo fa sempre l'initramfs (hook cryptsetup di
  initramfs-tools), esattamente come con GRUB — il bootloader si limita a
  caricare kernel/initrd dalla partizione `/boot` (non cifrata, fuori dal
  container LUKS2 in questo layout) e a passare la cmdline giusta
  (`root=/dev/mapper/<nome>`, `rootflags=subvol=@`, `cryptdevice=UUID=...`).
  **Scoperta importante testando su hardware reale (Zenbook di Antonio,
  panic "linux: Failed to open kernel with path"): Limine supporta SOLO
  FAT12/16/32 e ISO9660** (suo README ufficiale, sezione "Supported
  filesystems" — confermato leggendo il sorgente: `common/fs/file.s2.c`
  prova solo `fat32_open()`/`iso9660_open()`, nessun driver ext2/ext3/ext4
  esiste). Il nostro `/boot` è ext4: qualunque `uuid(<uuid-di-/boot>):/...`
  o `guid(...)` puntasse lì non avrebbe mai funzionato — non un bug
  isolato, un limite strutturale del bootloader. Valutato (e scartato)
  riformattare `/boot` in FAT32 per aggirarlo: FAT32 non supporta i
  symlink POSIX, e il pacchetto del kernel Ubuntu crea
  `/boot/vmlinuz` → `/boot/vmlinuz-X.Y.Z-N-generic` come symlink a ogni
  aggiornamento (default dal 20.04, `link_in_boot`) — su FAT32 quella
  `ln -sf` fallisce con "Operation not permitted" e romperebbe ogni
  `apt upgrade` che installa un nuovo kernel (bug Ubuntu #1318951 "kernel
  update fails with /boot on FAT32", stesso sintomo con `flash-kernel` su
  Debian/Proxmox). Soluzione adottata: `/boot` resta ext4 come per GRUB
  (zero rischio sugli aggiornamenti kernel); kernel e initrd correnti
  vengono invece copiati sull'ESP (che Limine legge) in una directory
  dedicata `limine-kernels/`, e `limine.conf` punta lì con
  `boot():/limine-kernels/...` (la partizione che contiene `limine.conf`
  stesso, cioè l'ESP — sintassi da `CONFIG.md`, sezione "Paths"). Il
  mantenimento nel tempo è affidato a un nuovo script,
  `/usr/local/bin/limine-kernel-sync`, agganciato a
  `/etc/kernel/postinst.d/` e `postrm.d/`: si rilancia da solo a ogni
  installazione/rimozione di un pacchetto `linux-image-*`, ricopia
  kernel/initrd correnti sull'ESP, ripulisce le versioni non più presenti
  in `/boot` e riscrive le righe `kernel_path`/`module_path` di TUTTE le
  entry di `limine.conf` (incluse le eventuali voci snapshot: usano lo
  stesso kernel/initrd corrente, cambia solo `rootflags=subvol=`). Non
  ancora verificato un riavvio reale con un secondo kernel installato
  (solo la generazione/gli hook sono stati validati in isolamento).
  **Boot reale confermato dopo questo fix** sullo Zenbook di Antonio.
  Script standalone equivalente (per un sistema già installato) in
  `scripts/17-install-limine.sh`.
- **Permessi sull'ESP**: trovato eseguendo `scripts/18-limine-snapshot-sync.sh`
  su un sistema reale — l'ESP di questa ricetta è montata con
  `fmask=0077,dmask=0077` (nessun `uid=`/`gid=` in `/etc/fstab`), quindi
  `/boot/efi/EFI/limine/` è leggibile SOLO da root. I controlli iniziali
  di `18-limine-snapshot-sync.sh` (eseguito da utente normale) leggevano
  `limine.conf` senza `sudo`: fallivano per permessi, ma l'errore
  risultante ("non trovato") sembrava un problema diverso (file
  mancante) invece che un problema di permessi. Fix: `sudo test -f`/
  `sudo grep` per quei controlli. Lo script generatore installato di
  sistema (`/usr/local/bin/limine-snapshot-sync`, eseguito dal servizio
  systemd) non ha lo stesso problema: gira sempre come root.
- **`limine-snapshot-sync`: reimplementazione nostra, non un porting** —
  l'obiettivo era dare a Limine lo stesso "boot diretto in uno snapshot
  BTRFS/snapper precedente" che grub-btrfs offre già per GRUB in questa
  ricetta. Esiste un progetto con questo esatto nome (usato da CachyOS),
  ma verificato che la versione attuale (1.31.0) è scritta in Java e
  compilata con GraalVM `nativeCompile` (serve una toolchain
  gradle+GraalVM), e si appoggia a pacchetti Arch-specifici
  (`limine-mkinitcpio-hook`, hook `pacman`) che su Ubuntu non esistono —
  portarlo davvero avrebbe richiesto riscrivere quegli hook per
  initramfs-tools/apt, con un rischio/tempo sproporzionati rispetto al
  beneficio a ridosso della demo del 17. Reimplementato invece lo stesso
  RISULTATO con un piccolo script bash (`/usr/local/bin/limine-snapshot-sync`)
  che rigenera un blocco delimitato da marcatori
  (`#### LIMINE-SNAPSHOT-SYNC:BEGIN/END`) dentro `limine.conf`, con una
  voce per ogni `/.snapshots/<N>/snapshot` trovato — più un demone di
  watch (`limine-snapshot-sync-watch`, `inotifywait` su `/.snapshots`,
  servizio systemd `limine-snapshot-sync.service`), esattamente lo stesso
  meccanismo (demone + watch via inotify) già usato da
  grub-btrfs/grub-btrfsd in questa stessa ricetta per GRUB — nessuna
  toolchain aggiuntiva, coerente col resto del progetto. Le voci snapshot
  puntano a kernel/initrd con lo stesso `boot():/limine-kernels/...` della
  voce principale (non `uuid(...)`, vedi sopra: Limine non legge ext4) —
  `limine-snapshot-sync` richiama `limine-kernel-sync` a ogni esecuzione
  per essere sicuro che la copia sull'ESP sia allineata. Il valore di
  `rootflags=subvol=` per uno snapshot è `@snapshots/<N>/snapshot`: nel
  layout di questa ricetta `@snapshots` è un subvolume di primo livello
  (fratello di `@`, non annidato dentro), montato su `/.snapshots` — gli
  snapshot numerati di Snapper vivono quindi, visti dalla radice del
  filesystem BTRFS, sotto `@snapshots/<N>/snapshot`. La logica di
  sostituzione dei marcatori (idempotente: rigenerare non duplica le
  voci) e l'ordinamento decrescente per numero di snapshot sono stati
  validati con un test reale in sandbox (mount/directory finti, non solo
  letti a mente). **Non ancora verificato un boot reale da uno snapshot
  generato così** — solo la generazione della configurazione è testata.
  Script standalone equivalente in `scripts/18-limine-snapshot-sync.sh`.
- **Interfaccia Limine: branding e vista ad albero per gli snapshot** —
  `limine.conf` ora imposta opzioni globali di tema (`interface_branding`
  "Ubuntu Ultimate", `interface_branding_colour` E95420 arancione Ubuntu,
  `term_palette`/`term_background`/`term_foreground` per una palette scura
  coerente). Le voci snapshot non sono più entry piatte allo stesso livello
  della voce principale: `limine-snapshot-sync` le raggruppa ora sotto una
  directory `/+Snapshots` (il `+` la tiene espansa di default nel menu),
  con ogni snapshot come sotto-voce (`//Snapshot #N`, sintassi verificata
  su `test/limine.conf` del progetto Limine — stesso schema del loro
  esempio `/+Legacy` → `//Multiboot1 Test`). La directory viene emessa solo
  se esiste almeno uno snapshot (nessuna entry vuota nel menu). Generazione
  del blocco (indentazione, ordine, assenza di entry vuota) validata con un
  test reale in sandbox; il boot da uno snapshot resta comunque non ancora
  verificato su hardware (vedi punto sopra).
- **Bug reale trovato su hardware: le snapshot sparivano dal menu dopo aver
  rieseguito `17-install-limine.sh`** (es. dopo `19-tpm2-autounlock.sh`, che
  lo richiama a fine esecuzione per propagare `rd.luks.uuid=`) — causa:
  l'heredoc che scrive `limine.conf` in `scripts/17-install-limine.sh` (a
  differenza di quello, corretto, dentro `disk-setup/autoinstall.yaml.tpl`)
  non includeva i marcatori `#### LIMINE-SNAPSHOT-SYNC:BEGIN/END`. Ogni
  rigenerazione completa di `limine.conf` li cancellava del tutto (non solo
  li svuotava), e `limine-snapshot-sync`, trovandoli assenti, usciva subito
  senza scrivere nulla (`grep ... || exit 0`) — anche se veniva richiamato
  subito dopo apposta per ripopolare le voci. Fix: aggiunti i marcatori
  (vuoti) anche nell'heredoc di `scripts/17-install-limine.sh`, così restano
  sempre presenti e la rigenerazione successiva li ripopola correttamente.
- **USBGuard**: pacchetto ufficiale Ubuntu, blocca di default qualunque
  dispositivo USB non esplicitamente permesso. La policy iniziale
  (`/etc/usbguard/rules.conf`) viene generata con `usbguard generate-policy`
  sui dispositivi GIA' connessi al momento dell'installazione — funziona
  perché il chroot di curtin condivide `/dev` e `/sys` con l'ambiente live
  dell'installer (stesso meccanismo già sfruttato per il blocco disco),
  quindi vede i device reali della macchina, tastiera/trackpad interne
  comprese: fondamentale per non ritrovarsi con tastiera e mouse bloccati
  al primo avvio. Diamo accesso IPC al gruppo `sudo` (di default solo
  root può interrogare/gestire usbguard) modificando
  `/etc/usbguard/usbguard-daemon.conf`.
- **usbguard-notifier**: il fork personale di Antonio
  (github.com/antoniopicone/usbguard-notifier), non pacchettizzato — si
  compila con autotools (`autogen.sh`/`configure`/`make`) e si installa
  nell'home dell'utente come servizio **systemd utente** (non di sistema),
  coerente con come il progetto documenta l'installazione locale. Richiede
  il pacchetto `systemd-dev` (fornisce `systemd.pc` per pkg-config): senza,
  `configure` fallisce con "Cannot detect the systemd system unit dir".
  Quarto problema reale trovato, questa volta dopo un'installazione vera
  sullo Zenbook: il servizio risultava installato (`systemctl --user
  status` lo vedeva come "loaded") ma **mai abilitato** ("disabled"), e
  quindi mai partito al login. Causa: l'attivazione veniva fatta dentro il
  chroot dell'autoinstall con `dbus-run-session -- systemctl --user enable
  usbguard-notifier.service` — `dbus-run-session` crea un bus D-Bus di
  sessione "usa e getta", ma non un vero manager `systemd --user`
  funzionante come quello di una sessione di login reale, quindi l'`enable`
  falliva silenziosamente (il comando comunque usciva con successo, per
  cui il nostro `|| echo ATTENZIONE` non lo intercettava). Risolto
  bypassando del tutto `systemctl --user enable`: quel comando altro non fa
  che creare un symlink verso l'unità dentro la directory `.wants` del
  target indicato da `WantedBy=` nella sezione `[Install]` dell'unità
  stessa (`usbguard-notifier.service` ha `WantedBy=default.target`,
  verificato leggendo `usbguard-notifier.service.in` nel repository
  sorgente) — lo creiamo quindi direttamente con `ln -sf`, senza bisogno di
  un manager systemd --user realmente attivo nel chroot.
- **USBGuard vs "USB Protection" di GNOME**: per default GNOME
  (`org.gnome.desktop.privacy usb-protection-level = 'lockscreen'`) il
  componente `gsd-usb-protection` di gnome-settings-daemon inserisce
  dinamicamente in `/etc/usbguard/rules.conf` una regola jolly
  `allow id *:* label "GNOME_SETTINGS_DAEMON_RULE"` ogni volta che lo
  schermo è sbloccato, lasciando passare qualunque dispositivo — la
  protezione di GNOME è pensata contro un attacco tipo "evil maid" a
  schermo bloccato, non per l'uso quotidiano. Scoperto testando una
  chiavetta USB mai vista prima che veniva comunque montata a schermo
  sbloccato. Dato che qui vogliamo che usbguard blocchi i device
  sconosciuti sempre, non solo a lockscreen, forziamo
  `usb-protection-level=always` via `gsettings` durante il setup.
- **Notifica nativa di GNOME per USB bloccate: disattivata, resta solo
  usbguard-notifier**. Anche con `usb-protection-level=always`,
  `gsd-usb-protection` mostra una sua notifica critica/bloccante
  ("Protezione USB — Dispositivo USB bloccato") ad ogni device
  sconosciuto respinto, in sovrapposizione a quella del nostro
  `usbguard-notifier` — confermato leggendo il sorgente di
  gnome-settings-daemon (`show_notification` con urgenza `CRITICAL`,
  chiamata incondizionatamente, nessuna chiave gsettings per disattivare
  solo la notifica). Il plugin gira come servizio systemd utente
  D-Bus-attivato a sé stante, `org.gnome.SettingsDaemon.UsbProtection.service`
  (separato dagli altri plugin di gnome-settings-daemon, che restano
  intatti, e dal demone di sistema usbguard, che continua a bloccare per
  conto suo): lo mascheriamo creando il symlink verso `/dev/null` in
  `~/.config/systemd/user/` (in chroot non c'è un'istanza reale di
  systemd --user su cui usare `systemctl --user mask`). ATTENZIONE:
  disattivare `usb-protection` via gsettings mentre il plugin è ancora
  vivo NON basta e anzi peggiora le cose — il suo stesso codice, quando
  rileva `usb-protection=false` (o livello `lockscreen`), reinserisce la
  regola jolly `allow id *:*` in `/etc/usbguard/rules.conf`; va mascherato
  il servizio, non spenta la sua configurazione.
- **Bug correlato, trovato testando sulla partizione Ubuntu dello zenbook
  (installazione manuale, non ancora via autoinstall completo): un
  device con una regola "allow" permanente (scritta da usbguard-notifier
  dopo aver cliccato "Consenti") veniva comunque bloccato e richiedeva
  sempre una nuova autorizzazione manuale ad ogni reinserimento, invece
  di essere riconosciuto in automatico**. Causa: `gsd-usb-protection`,
  quando ha girato con `usb-protection-level=always` (prima di essere
  mascherato), aveva impostato via IPC il parametro RUNTIME del demone
  usbguard `InsertedDevicePolicy=block` (blocca sempre, ignorando le
  regole esistenti) al posto del default di pacchetto `apply-policy`
  (autorizza automaticamente se una regola combacia). Il parametro resta
  in memoria finché il demone non viene riavviato — da qui la falsa
  impressione di "nessuna memoria" nel notificatore, che invece scriveva
  le regole permanenti correttamente fin dall'inizio. Fix verificato:
  `sudo systemctl restart usbguard.service` per far ricaricare il default
  `apply-policy` da file. Dato che ora mascheriamo `gsd-usb-protection`
  PRIMA che possa mai partire, questo scenario non si presenta affatto
  su un'installazione pulita via autoinstall — è stato un artefatto della
  cronologia di test su quella macchina specifica (mascherato a
  posteriori, non da zero), non un difetto strutturale della ricetta.
- **Podman + wrapper Docker + "docker compose" reale, senza il vero
  Docker Engine**: `podman-docker` fornisce `/usr/bin/docker` come
  wrapper minimo (`exec podman "$@"`), quindi ogni comando `docker`
  diventa un comando `podman`. `docker-compose-v2` (pacchetto Ubuntu
  universe, il vero Compose v2 upstream in Go, non la vecchia versione
  Python deprecata) installa **solo** il plugin CLI
  (`/usr/libexec/docker/cli-plugins/docker-compose`), non un binario
  standalone: va invocato con `docker compose ...` (o `podman compose
  ...`, identico dato che `docker`=`podman`). Verificato che il comando
  nativo `podman compose` di podman 4.9 lo trova ed esegue da solo,
  senza bisogno di configurare `compose_provider` in
  `containers.conf`. Trappola apt verificata e da evitare: installare
  `docker-compose-v2` PRIMA di `podman-docker`, o senza
  `--no-install-recommends`, fa sì che apt scarichi anche `docker.io`
  (il vero Docker Engine, raccomandato da `docker-compose-v2`) e siccome
  `podman-docker` dichiara `Conflicts: docker.io`, apt risolve
  **rimuovendo silenziosamente `podman-docker`** per fare spazio al vero
  Docker — nessun errore, il wrapper semplicemente sparisce. Ordine
  corretto nel recipe: `podman`+`podman-docker` prima, poi
  `docker-compose-v2 --no-install-recommends`. Per il funzionamento in
  modalità rootless (l'utente normale) serve inoltre l'unit systemd
  utente `podman.socket` (di serie nel pacchetto podman) abilitata per
  l'utente target, altrimenti `docker compose`/`podman compose` (che
  parlano con l'API Docker-compatibile di podman via socket Unix, a
  differenza dei comandi `docker` "semplici" che passano diretti per
  podman senza bisogno di alcun socket) restituiscono "Cannot connect to
  the Docker daemon" — abilitata con lo stesso trucco del symlink già
  usato per usbguard-notifier (`~/.config/systemd/user/sockets.target.wants/`).
  Il wrapper `/usr/bin/docker` di `podman-docker` stampa anche "Emulate
  Docker CLI using podman..." su stderr ad ogni invocazione, a meno che
  non esista `/etc/containers/nodocker` (condizione esplicita dello script
  del wrapper stesso, non un hack aggiunto da noi): lo creiamo per
  zittirlo. Il pacchetto Ubuntu di podman spedisce inoltre
  `/etc/containers/registries.conf` con `unqualified-search-registries`
  commentato (nessun registry di default): un nome corto senza registry
  esplicito (es. `docker pull mermaid-js/mermaid-live-editor`) fallisce con
  "short-name ... did not resolve to an alias and no unqualified-search
  registries are defined" a meno che non combaci con uno degli alias già
  pronti in `registries.conf.d/shortnames.conf` (immagini "note" tipo
  ubuntu/alpine/nginx). Aggiungiamo un file di drop-in in
  `/etc/containers/registries.conf.d/` (si somma al file principale, non
  lo sostituisce) che imposta `docker.io`, replicando il comportamento di
  default di Docker stesso.
- **Snapshot anche per /home, non solo /**: aggiunto un subvolume
  gemello di `@snapshots`, `@home_snapshots`, creato allo stesso livello
  top (subvolid=5) durante la conversione a subvolume nel blocco disco,
  montato su `/home/.snapshots` (fstab dedicato). Le config snapper per
  `root` e `home` sono scritte DIRETTAMENTE come file (non con `snapper
  create-config`, che genera valori generici) usando i retention già
  collaudati da Antonio in un'altra sessione: `home` tiene più storico
  (12/14/8/6 vs 6/7/4/3 per ora/giorno/settimana/mese) dato che i dati
  utente cambiano più spesso e pesano meno cancellarli tardi. A
  differenza dello script originale (pensato per un sistema già vivo, che
  faceva `systemctl restart snapperd.service` + verifica con `snapper -c
  <config> list` per invalidare la cache D-Bus di snapperd), qui questi
  passaggi non servono: in un chroot offline durante l'autoinstall non
  c'è alcuna istanza di snapperd già in esecuzione con una cache da
  invalidare — leggerà le config appena scritte alla primissima
  esecuzione, al primo avvio reale.
  Entrambe le config impostano anche `ALLOW_USERS="<utente>"` e
  `SYNC_ACL="yes"` (invece dei precedenti `""`/`"no"`): Snapper mantiene così
  da solo le ACL POSIX su `.snapshots`, permettendo all'utente normale di
  leggerci dentro senza essere root — prerequisito per strumenti come
  **nautilus-snapper-restore** (aggiunge a Nautilus una voce "Versioni
  precedenti (Snapper)…" per ripristinare file, stile Time Machine — vedi
  la voce dedicata più sotto). Il pacchetto Ubuntu di snapper non spedisce
  alcuna regola polkit per l'accesso via D-Bus a `snapperd` (verificato:
  `dpkg -L snapper` non elenca nulla sotto `polkit`), quindi senza questa
  ACL un utente normale non avrebbe comunque modo di sfogliare gli
  snapshot.
- **nautilus-snapper-restore**: progetto consegnato a parte in questa
  stessa sessione (menu tasto destro su un file -> "Versioni precedenti
  (Snapper)…" -> apri o ripristina, senza passare da snapperd/D-Bus), ora
  incluso anche nella ricetta su richiesta esplicita — validato prima in
  una VM di test, dove è emerso e stato corretto un bug reale:
  `gi.require_version("Nautilus", "4.0")` va in conflitto con la versione
  **4.1** che Nautilus carica già da solo su Ubuntu 26.04 (crash
  immediato dell'estensione, mai visibile nel menu, visto solo lanciando
  `nautilus -q && nautilus .` da un terminale) — corretto ignorando
  l'eccezione e usando qualunque versione Nautilus abbia già caricato.
  Installato a livello di SISTEMA, non nella home di un utente specifico
  (stesso motivo delle estensioni GNOME Shell): l'estensione va in
  `/usr/share/nautilus-python/extensions/` (che `python3-nautilus` legge
  oltre a `~/.local/share/nautilus-python/extensions/`), il visualizzatore
  GTK4 in `/usr/local/bin/nautilus-snapper-viewer` — quest'ultimo posto
  deliberatamente diverso da `~/.local/bin` usato nella versione
  standalone originale: `/usr/local/bin` è già nel `PATH` di default per
  qualunque utente/sessione senza bisogno di un logout/login, un problema
  reale incontrato validando la versione per-utente in VM. Nessuna azione
  è distruttiva senza un modo per tornare indietro: il ripristino salva
  sempre prima una copia del file attuale (`<file>.bak-AAAAMMGG-HHMMSS`).
- **grub-btrfsd ora monitora anche `/home/.snapshots`**, non solo
  `/.snapshots`, via un drop-in systemd (`ExecStart=` vuoto per azzerare
  il default, poi il nuovo comando con entrambi i path). Percorso del
  binario **confermato dal Makefile upstream** (`PREFIX=/usr`,
  `BIN_DIR=$PREFIX/bin`): `/usr/bin/grub-btrfsd` — NON
  `/usr/local/bin/grub-btrfsd` come assume qualche guida in giro (lo
  script di Antonio stesso segnalava questa incertezza con un commento;
  verificato qui scaricando direttamente il Makefile dal repository).
- **GRUB con menu visibile, timeout 5s**: il default Ubuntu tiene il menu
  nascosto (`GRUB_TIMEOUT_STYLE=hidden`, timeout 0, si mostra solo
  tenendo premuto Shift) — utile per una demo dove si vuole mostrare le
  voci di boot-da-snapshot di grub-btrfs. Modifica idempotente di
  `/etc/default/grub` via `sed`, poi rigenerato da `update-grub` (che il
  recipe chiama già comunque alla fine del blocco software).
- **zsh + Oh My Zsh**: la shell si imposta con `usermod --shell`, non
  `chsh` — in un chroot offline, senza una sessione utente reale, `chsh`
  passa da PAM e può comportarsi in modo imprevedibile o chiedere conferme
  che qui nessuno può dare; `usermod` scrive direttamente `/etc/passwd`,
  stesso risultato, senza sorprese. Oh My Zsh si installa con lo script
  ufficiale in modalità `--unattended` (equivale a `RUNZSH=no` +
  `CHSH=no`, dato che la shell la impostiamo già noi, +
  `OVERWRITE_CONFIRMATION=no`), eseguito come l'utente target via `su -`
  perché scriva in `~/.oh-my-zsh` e `~/.zshrc` con i permessi giusti. Il
  tema **Pure** (`sindresorhus/pure`) va clonato e aggiunto a `.zshrc`
  DOPO l'installer di Oh My Zsh, non prima o insieme: l'installer
  sovrascrive `.zshrc` da zero, quindi qualunque riga aggiunta prima
  andrebbe persa. Stesso ordine (Oh My Zsh, poi Pure) replicato in
  `live-iso/chroot-customize.sh`, dove Oh My Zsh e Pure finiscono in
  `/etc/skel` invece che nella home di un utente concreto.
- **`live-iso/`, come si ricostruisce una ISO avviabile senza indovinare
  i flag di boot**: invece di ricostruire a mano i parametri BIOS+UEFI
  hybrid/El Torito (facile sbagliarli e ottenere una ISO che non si
  avvia), `build-live-remix.sh` li legge direttamente dalla ISO sorgente
  con `xorriso -indev <iso> -report_el_torito as_mkisofs`, e li riusa
  identici nella `xorriso -as mkisofs` finale — così lo script resta
  valido anche se Canonical cambia il layout di boot in futuro. Il
  meccanismo completo (estrai → modifica squashfs → ricomprimi →
  ricostruisci con gli stessi flag → verifica) è stato validato in
  sandbox su un filesystem/ISO sintetici di pochi KB, non ancora su una
  ISO Ubuntu reale multi-GB (vedi `live-iso/README.md`).
- **`live-iso/`, il filesystem live NON è un unico squashfs (scoperto
  testando su hardware reale, non a tavolino)**: il primo tentativo
  assumeva ancora il vecchio schema Ubuntu con un solo
  `casper/filesystem.squashfs` ed è fallito subito sulla ISO reale della
  26.04. Invece di continuare a tentativi ho scaricato ed esaminato i
  sorgenti ufficiali dei pacchetti `casper` e `livecd-rootfs`
  (`archive.ubuntu.com`): dalla 24.04 il filesystem live è a più layer
  sovrapposti in overlayfs (`minimal.squashfs` base → `minimal.standard.
  squashfs` desktop completo → `minimal.standard.live.squashfs` solo
  extra di sessione live), con la combinazione da montare al boot
  (`LAYERFS_PATH`) cablata dentro l'initrd al momento della build Canonical
  e ricavata da casper togliendo un pezzo di nome alla volta. Le nostre
  modifiche finiscono solo in `minimal.standard.squashfs` (l'equivalente
  moderno del vecchio `filesystem.squashfs`), montando tutti e 3 i layer
  insieme in overlay durante la personalizzazione per una vista apt/dpkg
  coerente. Conseguenza da testare esplicitamente: un boot in una lingua
  diversa dall'inglese o con secure boot "enhanced" userebbe layer
  alternativi (`minimal.<lingua>.squashfs`, `*.enhanced-secureboot*`) mai
  toccati da questo script — vedi `live-iso/README.md` per la checklist
  completa.
- **`live-iso/`, il problema dconf che ho trovato PRIMA di testare**:
  senza `/etc/dconf/profile/user`, dconf usa un profilo interno
  "hard-wired" che legge **solo** `user-db:user` — nessun database di
  sistema, incluso `local`. Ubuntu non spedisce questo file di default:
  senza crearlo esplicitamente, tutte le impostazioni scritte in
  `/etc/dconf/db/local.d/*` (terminale di default, touchpad) verrebbero
  compilate nel database ma non lette mai da nessuna sessione utente —
  un bug silenzioso, nessun comando fallisce. `chroot-customize.sh` crea
  questo file (`user-db:user` / `system-db:local`) prima di scrivere le
  keyfile; validato empiricamente in sandbox creando un utente Linux di
  test nuovo e confermando che leggeva il default di sistema.
- **`live-iso/`, cosa resta fuori e perché**: layout BTRFS su LUKS2,
  config snapper root/home, `usbguard-notifier` e il socket utente di
  Podman restano esclusivamente in `disk-setup/autoinstall.yaml.tpl`,
  perché dipendono tutti da un utente e/o un disco concreti che in un
  filesystem live generico (condiviso da chiunque lo avvii) non esistono
  ancora. Le impostazioni GNOME invece sono incluse anche nel live,
  scritte come default di sistema via dconf invece che per un utente
  preciso via `dbus-run-session`, proprio perché quel meccanismo si
  applica a qualunque utente senza bisogno di sapere in anticipo chi
  sarà — comprese le stesse 8 estensioni GNOME Shell della ricetta
  principale, installate in `/usr/share/gnome-shell/extensions/` (il
  percorso di sistema documentato da GNOME per estensioni valide per
  ogni utente) invece che nella home di un utente specifico.
- **`live-iso/`, autoinstall incorporato nella stessa ISO (niente seconda
  chiavetta)**: `build-live-remix.sh` accetta ora anche
  `disk-setup/autoinstall.yaml` come secondo argomento opzionale e, se lo
  trova già generato, incorpora una cartella `/nocloud/` alla radice della
  ISO più `autoinstall "ds=nocloud;s=/cdrom/nocloud/"` in `grub.cfg` (solo
  sulla entry di default) — pattern verificato su più fonti community per
  esattamente questo scopo ("custom ISO" autoinstall). Non forza
  l'installazione al boot: la sessione live parte normale e navigabile,
  l'automazione parte solo se scegli "Install Ubuntu" dal desktop live.
  **Avviso di sicurezza**: così facendo la passphrase LUKS2 e l'hash della
  password finiscono in chiaro dentro quella ISO (ISO9660 non ha permessi
  per-file) — vedi `live-iso/README.md` per i dettagli e per cancellarla a
  fine test. Non ancora testato che l'installer trovi davvero il
  datasource al boot.
