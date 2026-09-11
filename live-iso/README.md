# Live ISO remix (`live-iso/`)

Questa cartella costruisce una **vera ISO live custom** di Ubuntu 26.04
Desktop: non un semplice autoinstall confezionato, ma una ISO che si avvia
in sessione live (come Ubuntu Cinnamon Remix o simili), con gran parte del
software della ricetta già installato e navigabile PRIMA di decidere se
installare. È l'opzione "difficile" scelta esplicitamente da Antonio al
posto della singola ISO con autoinstall preconfezionato.

**Aggiornamento**: su richiesta esplicita, la ISO può anche incorporare
l'autoinstall stesso (`disk-setup/autoinstall.yaml`, se già generato) —
un solo file fa sia da ISO live navigabile sia da ISO auto-installante,
senza bisogno di una seconda chiavetta seed. Vedi "Autoinstall incorporato
(un solo file, niente seconda chiavetta)" più sotto, **compreso l'avviso
di sicurezza**: quella ISO conterrà la passphrase LUKS2 in chiaro.

## Come funziona

`build-live-remix.sh` (va lanciato con `sudo`):

1. Recupera la ISO ufficiale di Ubuntu 26.04.1 Desktop (riusa
   `test-vm/isos/...` se già presente, altrimenti la scarica riusando lo
   stesso meccanismo di `test-vm/create-test-vm.sh`: scelta del mirror più
   veloce + progress bar).
2. Estrae il contenuto della ISO (`xorriso -osirrox`).
3. Cattura i parametri di boot ORIGINALI (BIOS+UEFI hybrid, El Torito)
   direttamente da `xorriso -report_el_torito as_mkisofs`, invece di
   provare a ricostruirli a mano: così la ISO risultante resta avviabile
   con lo stesso identico meccanismo di quella ufficiale, anche se
   Canonical cambia layout in futuro.
4. Decomprime i 3 layer del filesystem live (`unsquashfs`) — vedi "Il
   filesystem live NON è un unico squashfs" più sotto — e li monta insieme
   in overlay, per avere durante la personalizzazione la stessa vista che
   ha il sistema quando è avviato davvero.
5. Entra in chroot su quella vista unita e lancia `chroot-customize.sh`,
   che installa tutto il software extra e le impostazioni di sistema (vedi
   sotto).
6. Riporta le modifiche nel solo layer "standard", lo ricomprime
   (`mksquashfs -comp xz`) lasciando gli altri due layer intatti, rigenera
   `filesystem.size` e `md5sum.txt`.
7. Ricostruisce la ISO con `xorriso -as mkisofs`, usando esattamente i
   flag di boot catturati al passo 3.

Il risultato è `ubuntu-ultimate-live-YYYYMMDD.iso`, in questa stessa
cartella.

## Autoinstall incorporato (un solo file, niente seconda chiavetta)

`build-live-remix.sh [iso] [autoinstall.yaml]` accetta anche un secondo
argomento opzionale (default `../disk-setup/autoinstall.yaml`, se esiste).
Se lo trova (e non contiene più segnaposto `__...__` non sostituiti):

1. Copia il file dentro la ISO come `/nocloud/user-data`, più
   `/nocloud/meta-data` (vuoto, va bene così — copiato da
   `disk-setup/meta-data`).
2. Modifica `boot/grub/grub.cfg` (solo la entry di default "Try or Install
   Ubuntu", non tocca "Ubuntu (safe graphics)"): aggiunge
   `autoinstall "ds=nocloud;s=/cdrom/nocloud/"` alla riga del kernel.

**Non forza l'installazione al boot.** La sessione live parte
normalmente, navigabile come sempre — il parametro dice solo a
cloud-init/Subiquity DOVE trovare i dati, *se e quando* l'installer viene
lanciato. Se poi scegli "Install Ubuntu" dal desktop live, parte con tutta
l'automazione già nota (BTRFS su LUKS2, software, snapper, ecc.) invece
dell'installer manuale normale.

Il pattern (`/nocloud/` alla radice della ISO + `ds=nocloud;s=/cdrom/...`
in grub.cfg) è documentato dalla comunità proprio per questo scopo
("custom ISO" autoinstall, senza seconda chiavetta) — verificato su più
fonti prima di implementarlo, non indovinato. Se `autoinstall.yaml` non
c'è (o ha ancora segnaposto), lo script prosegue comunque e costruisce
la ISO solo-navigabile, senza fermarsi.

### ATTENZIONE SICUREZZA — leggere prima di condividere questa ISO

Con l'autoinstall incorporato, **la passphrase LUKS2 e l'hash della
password utente finiscono in chiaro dentro `/nocloud/user-data` sulla
ISO risultante**. ISO9660 non ha permessi per-file utili: chiunque abbia
il file `ubuntu-ultimate-live-*.iso` (o la chiavetta scritta con quello)
può montarlo e leggerli, esattamente come già vale per
`disk-setup/autoinstall.yaml` da solo — solo che ora il segreto è dentro
un file che probabilmente porti in giro per la demo. Trattala di
conseguenza: non pubblicarla/condividerla, cancellala quando hai finito.

### Non ancora testato (in aggiunta a quanto già elencato più sotto)

- Che "Install Ubuntu" dal desktop live trovi davvero il datasource e
  parta senza chiedere hostname/utente/password/dischi.
- Che il parametro grub sopravviva intatto sia in modalità BIOS sia UEFI
  (lo script patcha sia `boot/grub/grub.cfg` sia `EFI/boot/grub.cfg` se
  presente, ma non è stato verificato su un boot reale).
- Che le 8 estensioni GNOME Shell installate in
  `/usr/share/gnome-shell/extensions/` vengano davvero caricate/abilitate
  al primo login della sessione live (il meccanismo è documentato da
  GNOME, ma non ancora verificato su un boot reale di questa ISO). Alcune
  impostazioni (connettore monitor `eDP-1`, sensore ventola
  `sensor:_fan_asus_cpu_fan_`, posizione di Napoli per auto-theme-switcher)
  sono quelle di badrobot: su hardware diverso semplicemente non trovano
  riscontro o vengono sovrascritte dall'estensione stessa, senza errori —
  stessa cosa già vera nella ricetta principale.

## Il filesystem live NON è un unico squashfs

Il primo tentativo di questo script assumeva ancora il vecchio schema di
Ubuntu (un solo `casper/filesystem.squashfs`) ed è fallito subito
sull'ISO reale della 26.04 con "non trovo casper/filesystem.squashfs".
Dalla 24.04 in poi Ubuntu Desktop usa un filesystem live **a più layer**,
sovrapposti in overlayfs. Invece di continuare a tentativi ho scaricato ed
esaminato i sorgenti ufficiali dei pacchetti Debian/Ubuntu `casper` e
`livecd-rootfs` (`archive.ubuntu.com/ubuntu/pool/main/{c/casper,l/livecd-rootfs}/`):

- `livecd-rootfs` scrive, al momento della build della ISO, un file
  `LAYERFS_PATH=<pass>.squashfs` dentro l'initrd (hook
  `020-ubuntu-live.chroot_early`).
- Lo script di boot di `casper` (`scripts/casper`) legge quel valore e
  ricava la catena di layer da montare togliendo un pezzo di nome alla
  volta: `minimal.standard.live` → `minimal.standard` → `minimal`.

Sull'ISO della 26.04 tra i file c'è `minimal.standard.live.squashfs`, quindi
la catena di boot di default (lingua inglese, secure boot normale) è:

1. `minimal.squashfs` — base minima.
2. `minimal.standard.squashfs` — desktop completo. **È qui che finiscono le
   nostre modifiche**: è l'equivalente moderno del vecchio
   `filesystem.squashfs` monolitico.
3. `minimal.standard.live.squashfs` — solo l'occorrente per la sessione
   live (casper, ubiquity/subiquity): non fa parte di un sistema
   installato, quindi non ha senso modificarlo.

Tutte le altre varianti presenti sulla ISO (`minimal.<lingua>.squashfs`,
`minimal.standard.<lingua>.squashfs`, tutte le `*.enhanced-secureboot*`)
sono layer alternativi per altre combinazioni lingua/secure-boot: non fanno
parte della catena di boot di default e questo script non le tocca — **la
conseguenza pratica è che un boot in una lingua diversa dall'inglese, o con
"enhanced secure boot" attivo, potrebbe non includere le nostre modifiche**
(vedi checklist di test più sotto).

Per installare software dentro `minimal.standard.squashfs` in modo
coerente (apt/dpkg devono vedere anche i pacchetti già presenti nei layer
sottostanti, non solo quelli del layer che modifichiamo), lo script monta
tutti e 3 i layer insieme in un overlay temporaneo — stessa identica
tecnica che il kernel usa quando il sistema è avviato davvero — esegue
`chroot-customize.sh` dentro quella vista unita, e alla fine riporta solo
il delta prodotto (pacchetti nuovi, file modificati) dentro
`minimal.standard.squashfs`, ricomprimendo solo quello. Questo ragionamento
è verificato leggendo il codice sorgente reale, ma **il meccanismo overlay
a 3 layer non è ancora stato eseguito nemmeno in miniatura** (a differenza
dell'estrazione/ricostruzione ISO, validata su un mini filesystem
sintetico) — vedi la sezione sui test più sotto.

## Cosa c'è dentro (e perché)

Tutto ciò che NON dipende da un utente o un disco concreto:

- Ghostty (terminale) + integrazione Nautilus, impostato come terminale
  di default via dconf di sistema.
- Brave.
- Le stesse 8 estensioni GNOME Shell della ricetta principale (display-
  color-correct, Rounded_Corners, kiwi, kiwimenu, caffeine, Vitals,
  auto-theme-switcher, Tailscale for GNOME), scaricate da
  extensions.gnome.org e installate a
  livello di sistema in `/usr/share/gnome-shell/extensions/` (non nella
  home di un utente, che qui non esiste) — stesso meccanismo, adattato,
  di `disk-setup/autoinstall.yaml.tpl`. Il Gestore estensioni GNOME Shell
  (l'app grafica) è installato comunque, per gestirle a mano in futuro.
- zram (metà RAM, compressione zstd).
- Utility: vim, wget, htop, avahi-daemon, git, lm-sensors, gnome-sushi
  (anteprima file con barra spaziatrice in Nautilus).
- Font: font "core" Microsoft (`ttf-mscorefonts-installer`), Carlito/Caladea
  (sostituti liberi di Calibri/Cambria), JetBrains Mono, Hack Nerd Font —
  stessa logica della ricetta principale (vedi `README.md` principale per
  il dettaglio sulle licenze). SF Pro (macOS) escluso per licenza Apple.
- ONLYOFFICE Desktop Editors al posto di LibreOffice (rimosso se presente),
  dal repository apt ufficiale, con le stesse 3 voci `.desktop`
  (documento/foglio di calcolo/presentazione vuoti) della ricetta
  principale — vedi `README.md` principale per il dettaglio.
- Supporto APFS in sola lettura (`apfs-fuse`, compilato da sorgente) per
  leggere dischi/case USB provenienti da un Mac — stessa logica della
  ricetta principale, vedi `README.md` principale per il dettaglio
  (incluso perché nessun sistema live/disco specifico).
- USBGuard (solo il pacchetto + policy di default: niente
  notificatore/regole utente, vedi sotto).
- Tailscale: solo il pacchetto (script ufficiale `install.sh`), NON
  l'attivazione — `tailscale up` richiede il demone `tailscaled`
  realmente in esecuzione, cosa impossibile dentro il chroot; qui non ha
  comunque senso attivarlo senza un'auth key legata a un utente/uso
  specifico (vedi sotto).
- Podman rootless + `podman-docker` + `docker-compose-v2`, con
  `/etc/containers/nodocker` (silenzia il warning dell'emulazione Docker)
  e il drop-in `registries.conf.d/10-unqualified-search.conf` (permette
  di scrivere `docker run mermaid-js/...` senza specificare il registry
  per esteso).
- zsh + Oh My Zsh + tema Pure installati in `/etc/skel`, cosicché
  qualunque utente futuro (live o post-installazione) li erediti
  automaticamente.
- Rimozione di Firefox al primo avvio (systemd oneshot unit, si
  autodisabilita dopo essere girato una volta — necessario perché snapd
  non gira dentro un chroot senza init reale).
- Default GNOME di sistema via `/etc/dconf/db/local.d` + il fondamentale
  `/etc/dconf/profile/user` (vedi sotto "Un problema reale che ho
  trovato").

## Cosa NON c'è (e perché resta solo nell'autoinstall)

Tutto ciò che ha senso solo con un utente e un disco reali già decisi:

- Layout BTRFS su LUKS2, subvolume, configurazioni snapper root/home:
  legati per forza al disco di UNA installazione specifica.
- `usbguard-notifier` (si compila/installa nella home di un utente
  preciso) e il mascheramento di `gsd-usb-protection`.
- Il socket utente di Podman (unità systemd `--user` abilitata nella home
  di un utente specifico).
- Howdy: la build/installazione del pacchetto potrebbe stare in un remix
  live, ma l'enrollment del volto (`howdy add`) è per forza legato alla
  faccia dell'utente finale specifico — non ha senso pre-farlo in un'ISO
  condivisa. Vedi "Stato attuale" nel README principale per lo stato
  reale (integrato nell'autoinstall, non ancora testato su hardware).
- Attivazione di Tailscale (`tailscale up --auth-key=...`): il pacchetto
  è incluso (vedi sopra) ma l'auth key è un segreto legato a una singola
  esecuzione, raccolta da `prepare-autoinstall.sh` insieme a
  passphrase/password.

Questi restano esclusivamente in `disk-setup/autoinstall.yaml.tpl`, che
gira DOPO che Subiquity ha creato un utente e un layout disco concreti.

## Un problema reale che ho trovato (e corretto) prima ancora di testare

Nel validare il meccanismo dconf ho scoperto una cosa non ovvia: se
`/etc/dconf/profile/user` non esiste, dconf usa un profilo interno
"hard-wired" che legge **solo** `user-db:user` — nessun database di
sistema, "local" incluso. Ubuntu non spedisce questo file di default.
Senza crearlo esplicitamente, tutte le impostazioni scritte in
`/etc/dconf/db/local.d/*` sarebbero compilate nel database ma **mai lette
da nessuna sessione utente** — un bug silenzioso, difficile da notare
perché nessun comando fallisce.

`chroot-customize.sh` crea questo file (`user-db:user` / `system-db:local`)
prima di scrivere le keyfile. Ho validato il meccanismo per intero in
sandbox: creato il profilo + una keyfile di test, lanciato `dconf update`,
poi creato un utente Linux nuovo di zecca e confermato che leggeva
correttamente il default di sistema. Non è quindi solo una supposizione da
manuale: è verificato empiricamente, anche se non ancora dentro il
contesto reale di questo script.

## Un secondo problema reale: "umount: target is busy" a fine build

Testando la build completa su una macchina reale (non solo in sandbox), lo
smontaggio finale del chroot falliva con `umount: .../chroot-merged/dev:
target is busy` (e a cascata anche `chroot-merged` stesso, impedendo la
`rm -rf` della directory di lavoro). Causa: `gpg --recv-keys` (usato per
importare la chiave apt di ONLYOFFICE) avvia `dirmngr` come demone in
background per le richieste di rete al keyserver — demone che resta in
esecuzione ben oltre la fine di `chroot-customize.sh`, con file
descriptor ancora aperti dentro `/dev` (tipicamente `/dev/pts` e/o
`/dev/urandom`), impedendo lo smontaggio del bind mount.

Corretto in due punti, per robustezza:
1. In `chroot-customize.sh`, subito dopo l'uso di `gpg --recv-keys` per
   ONLYOFFICE: `gpgconf --kill dirmngr` termina esplicitamente il demone
   appena non serve più.
2. In `build-live-remix.sh`, una funzione `kill_chroot_processes()`
   (chiamata sia nel cleanup principale sia nel trap di uscita) termina
   *qualsiasi* processo il cui `/proc/PID/root` risulti essere il
   chroot, prima di tentare lo smontaggio — una rete di sicurezza più
   generale, nel caso un futuro pacchetto avviasse un altro demone
   analogo senza che ce ne accorgiamo.

## Un terzo problema reale: whiteout overlayfs non gestiti nel merge del delta

Sempre testando su macchina reale, il passo finale che riporta il delta
dentro `layer-standard` falliva con decine di righe `cp: cannot overwrite
directory '.../layer-standard/./etc/libreoffice' with non-directory
'.../overlay-delta/./etc/libreoffice'` (e analoghi per tutte le directory
di LibreOffice). Causa: quando `chroot-customize.sh` rimuove LibreOffice
con `apt-get purge`, `dpkg` cancella le sue directory — ma su overlayfs
cancellare qualcosa che esiste anche in un layer sottostante (qui
`layer-standard`, dove LibreOffice vive di serie) non lo rimuove
fisicamente: crea un **whiteout**, un file speciale device-carattere con
major:minor `0:0` che marca il percorso come "cancellato" nella vista
unita (verificato empiricamente montando un overlay di prova e cancellando
un file: il file compare esattamente come `c--------- ... 0, 0` in
`upperdir`). Lo script assumeva (erroneamente, si vedeva anche nel
commento originale) che cancellazioni così non si sarebbero mai
presentate, e usava un semplice `cp -a` per riportare il delta —
`cp -a` non capisce i whiteout: trova un device-carattere da un lato e una
directory vera dall'altro e giustamente rifiuta di sovrascriverla.

Corretto individuando i whiteout nel delta (`find -type c` + controllo
`stat -c '%t:%T'` == `0:0`) e applicandoli come vere cancellazioni
(`rm -rf`) su `layer-standard` *prima* di eseguire `cp -a` sul resto del
delta, rimuovendo anche il whiteout stesso dal delta (la cancellazione è
già stata applicata, non serve ricopiarlo come device-carattere reale
dentro `layer-standard`).

## Cosa NON è ancora stato testato — leggere prima della demo

Questo è il punto più importante di questo README: la meccanica di
estrazione/ricostruzione ISO (xorriso + squashfs-tools) è stata validata
end-to-end, ma **solo a scala sintetica** (un mini filesystem e una mini
ISO fabbricati apposta in sandbox, con lo stesso identico meccanismo ma
pochi KB invece di svariati GB) e **senza i 3 layer reali** (il mini test
usava ancora un solo squashfs). Il meccanismo a 3 layer + overlay descritto
sopra è basato su sorgenti ufficiali letti con attenzione, non su
un'esecuzione anche solo in miniatura. Non ho mai eseguito, in questo
ambiente:

- il download/uso di una ISO Ubuntu 26.04 Desktop reale (~6GB);
- il montaggio overlay dei 3 layer reali (`minimal`, `minimal.standard`,
  `minimal.standard.live`) e l'`unsquashfs`/`mksquashfs` su un filesystem
  live reale (multi-GB, probabilmente 10-20 minuti solo per la
  ricompressione xz del layer "standard");
- il boot reale (BIOS o UEFI) della ISO ricostruita;
- il boot in una lingua diversa dall'inglese o con secure boot
  "enhanced": potrebbero usare i layer `minimal.<lingua>.squashfs` /
  `*.enhanced-secureboot*` che questo script non tocca, quindi senza le
  nostre modifiche;
- che Oh My Zsh e il tema Pure installati in `/etc/skel` vengano
  effettivamente ereditati da un utente creato dopo il boot (dipende dal
  comportamento di `useradd`/`adduser` nel copiare `/etc/skel`, che non ho
  verificato in questo flusso specifico).

Non è un limite del ragionamento (il meccanismo di casper/livecd-rootfs è
verificato leggendone il codice sorgente reale, non indovinato), ma di
questo ambiente sandbox: spazio disco e tempo non erano sufficienti per un
giro completo su una ISO reale.

### Checklist di verifica prima del 17 settembre

- [ ] Eseguire `sudo ./build-live-remix.sh` su una macchina con almeno
      20-25GB liberi e tempo (probabilmente 20-40 minuti totali).
- [ ] Avviare la ISO risultante in una VM (es. `virt-manager`, o
      puntando `create-test-vm.sh` a questo file invece che a quello
      ufficiale) **con la lingua di default (inglese)**, sia in modalità
      BIOS/legacy sia UEFI.
- [ ] Verificare che la sessione live parta e che Ghostty, Brave, il
      gestore estensioni siano già presenti.
- [ ] Verificare che le 8 estensioni GNOME Shell risultino installate e
      abilitate (Estensioni/Extension Manager, o `gnome-extensions list
      --enabled` da terminale).
- [ ] Da terminale nella sessione live: `docker compose version`,
      `zsh --version`, `sensors`.
- [ ] Creare un utente reale (o installare da questa ISO) e verificare
      che trovi `~/.oh-my-zsh` e uno `.zshrc` funzionante.
- [ ] Se per la demo serve avviare in italiano, testarlo esplicitamente:
      non è detto che le nostre modifiche siano presenti in quel percorso
      di boot (vedi sopra).
- [ ] Se hai generato `disk-setup/autoinstall.yaml` prima di lanciare
      `build-live-remix.sh`, verifica anche l'autoinstall incorporato:
      dal desktop live scegli "Install Ubuntu" e controlla che parta senza
      chiedere hostname/utente/password/dischi, fino alla schermata di
      conferma nota — **e cancella quella ISO/chiavetta a fine test**
      (contiene la passphrase LUKS2 in chiaro, vedi sopra).
- [ ] Se qualcosa non torna e manca tempo prima della demo, la ISO
      ufficiale + `disk-setup/autoinstall.yaml.tpl` (autoinstall singolo,
      non live) resta l'opzione a basso rischio, già più rodata.

## Requisiti

`sudo`, `xorriso`, `squashfs-tools` (installati automaticamente se
mancanti), spazio disco abbondante (20-25GB+), rete per scaricare la ISO
sorgente se non già presente.
