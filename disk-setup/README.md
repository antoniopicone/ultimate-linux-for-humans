# Disk setup + software — tutto via autoinstall

## Perché autoinstall e non l'installer grafico

L'installer di Ubuntu Desktop (Subiquity) **non supporta nativamente BTRFS
su LUKS2**: la configurazione guidata gestisce la cifratura solo con
ext4/LVM, e in ogni caso non sa creare subvolume BTRFS ("the installer
cannot configure BTRFS subvolumes" — dalla documentazione ufficiale di
Subiquity). Usiamo quindi `autoinstall` (la modalità unattended di
Subiquity, basata su cloud-init/curtin): resta lo stesso file ISO
standard di Ubuntu, nessuna ISO custom da costruire/mantenere — gli forniamo
solo un file YAML con la configurazione.

## Layout risultante

```
ESP (fat32, 512M)        → /boot/efi
/boot (ext4, 1G)         → non cifrato (limite di GRUB, vedi sotto)
LUKS2 (resto del disco)
└─ BTRFS
   ├─ @            → /
   ├─ @home        → /home
   ├─ @var         → /var
   └─ @snapshots   → /.snapshots  (pronto per Timeshift/snapper in futuro)
```

`/boot` resta fuori dal container LUKS perché GRUB non legge in modo
affidabile BTRFS+LUKS2 su `/boot`; è lo stesso schema usato da Fedora e
openSUSE. Con Ubuntu 26.10 Canonical prevede peraltro di rimuovere dal GRUB
firmato il supporto a BTRFS/LUKS su `/boot` per motivi di sicurezza (non
riguarda la 26.04 LTS, ma conferma che questa è la direzione "giusta").

## Come funziona la conversione a subvolume (il punto delicato)

`curtin` (il motore di partizionamento sotto Subiquity) sa formattare BTRFS
ma **non sa creare subvolume** — è un limite noto, bug aperto dal 2023.
Il trucco usato in `autoinstall.yaml.tpl`:

1. curtin installa normalmente su un BTRFS "piatto" (senza subvolume)
   dentro il container LUKS2, come farebbe con qualunque altro filesystem;
2. a fine installazione, in `late-commands`, quel filesystem già popolato
   viene trasformato in subvolume `@` con uno **snapshot BTRFS** (istantaneo,
   copy-on-write, non ricopia i dati); vengono creati `@home`, `@var`,
   `@snapshots`, spostato dentro il poco contenuto già presente, riscritto
   `/etc/fstab` e rigenerati initramfs e grub dentro il target.

Questo è un pattern noto e testato dalla community (non un'invenzione mia
da zero), ma **non è ufficialmente documentato/supportato da Canonical**:
va validato in una VM prima di fidarsene per la demo.

## Anche il software è nell'autoinstall (niente passaggi manuali dopo)

`late-commands` non contiene solo la conversione del disco: ci sono altri
due blocchi, eseguiti in ordine subito dopo, che fanno tutto quello che
prima era nei quattro script separati in `scripts/`:

1. **Software via chroot** — `curtin in-target` installa Ghostty (apt,
   repo universe), Brave (repo ufficiale), l'estensione
   `nautilus-open-any-terminal` e configura le preferenze GNOME
   (terminale/browser predefiniti, integrazione Nautilus). apt/curl/dpkg
   funzionano dentro un chroot offline senza problemi — è la stessa cosa
   che fa curtin per installare il sistema base. Le impostazioni
   GNOME/dconf, che normalmente richiedono una sessione utente attiva,
   vengono scritte aprendo al volo un bus D-Bus privato con
   `dbus-run-session` (tecnica standard per configurare dconf in fase di
   build/immagine, senza login reale).

2. **Rimozione Firefox al primo avvio reale** — qui c'è un limite tecnico
   che non si può aggirare: `snap remove` parla con `snapd`, che è un
   servizio, e nessun servizio gira dentro un chroot offline durante
   l'installazione. La soluzione: un servizio systemd (`ubuntu-ultimate-
   firstboot.service`) viene installato e abilitato durante l'autoinstall,
   ma si esegue solo al **primo avvio vero** della macchina appena
   installata — quando snapd è realmente attivo. Si disabilita da solo
   subito dopo essere girato una volta, quindi ai riavvii successivi non
   fa nulla. È l'unico pezzo della ricetta che richiede un secondo minuto
   dopo il primo login prima di essere completo (il tempo che il servizio
   giri in background).

Risultato: un solo boot da ISO, zero comandi da lanciare a mano dopo il
login — a parte aspettare pochi secondi che il servizio di primo avvio
finisca (lo vedi sparire da `systemctl status ubuntu-ultimate-firstboot`).
Gli script in `scripts/` restano nel repo come riferimento leggibile di
cosa fa questa automazione, e come fallback se un giorno serve rifare solo
un pezzo a mano su un sistema già installato.

**Richiede rete durante l'installazione** (per scaricare i pacchetti Brave/
Ghostty/pip): normale se il PC è via cavo o ha il Wi-Fi già configurato da
Subiquity, indipendentemente da come hai consegnato l'autoinstall.yaml
stesso (server HTTP o chiavetta USB offline — sono cose separate).

## Installazione "minimal" invece di "normal" (meno tempo, meno spazio)

`autoinstall.yaml.tpl` imposta `source: id: ubuntu-desktop-minimal`. Non
esiste una ISO Ubuntu Desktop "minimal" separata da quella "completa": la
stessa ISO ufficiale 26.04.1 contiene già entrambe le varianti come layer
squashfs distinti dentro `casper/` (`minimal.squashfs` = base, `minimal.
standard.squashfs` = le aggiunte del "desktop completo": LibreOffice,
giochi, editor multipli — lo stesso layer su cui lavora `live-iso/
chroot-customize.sh` per il remix). Questa chiave dice a curtin di copiare
sul disco di destinazione SOLO il layer base, invece del default
`ubuntu-desktop` (installazione "normal"): install più veloce (meno dati
scritti su disco) e sistema installato più leggero (niente LibreOffice/
giochi preinstallati che comunque non usiamo).

**Non riduce la dimensione della ISO da scaricare né quella di un eventuale
remix live-iso**: la sessione live che fa girare l'installer stesso è
sempre il merge di TUTTI i layer (base + standard + extra di sessione
live), indipendentemente da quale variante verrà poi installata sul disco
— è così che casper è strutturato su questa release, non una nostra scelta.
Chi cerca di ridurre il peso della ISO/remix deve agire altrove (rimuovere
pacchetti dal layer "standard" in `chroot-customize.sh`, come già si fa per
LibreOffice/Firefox), non sulla scelta `source` qui.

**Da verificare prima della demo**: la documentazione ufficiale di Subiquity
segnala esplicitamente che l'ID di `source` è specifico della singola ISO
("the correct ID to use is specific to a given installation ISO") e va
confermato leggendo `casper/install-sources.yaml` dentro la ISO 26.04.1
reale — non ancora fatto in questa sessione (nessuna ISO scaricata qui per
ispezionarla). Se l'ID risultasse diverso, l'installazione fallirebbe
subito con un errore chiaro (sorgente non trovata), non silenziosamente.

## Come si usa

### 1. Genera il file autoinstall.yaml

```bash
./prepare-autoinstall.sh
```

Chiede hostname, username, password utente e passphrase LUKS2, e produce
un `autoinstall.yaml` completo in una directory temporanea (stampata a
schermo). Il file contiene la passphrase LUKS in chiaro: trattalo come un
segreto, non versionarlo, cancellalo dopo l'uso.

### 2. Servilo all'installer — due modi

**A) Server HTTP locale (consigliato, niente da scrivere sulla chiavetta)**

Boot dell'ISO Ubuntu 26.04 standard, poi al menu GRUB premi `e` per
modificare i parametri di boot e aggiungi in fondo alla riga `linux`:

```
autoinstall ds="nocloud-net;s=http://<IP-DEL-TUO-LAPTOP>:3003/"
```

Sul tuo laptop, nella stessa rete, nella cartella con `autoinstall.yaml` e
`meta-data`:

```bash
cd /percorso/con/autoinstall.yaml
python3 -m http.server 3003
```

**B) Chiavetta USB con datasource NoCloud (per demo offline, senza rete)**

È lo stesso identico meccanismo già validato in `test-vm/create-test-vm.sh`
per la VM di prova (una ISO NoCloud etichettata `cidata`, costruita con
`cloud-localds`): lì la montiamo come CD-ROM virtuale, qui la scriviamo su
una chiavetta fisica. Subiquity la rileva da solo all'avvio, senza bisogno
di toccare i parametri di boot.

```bash
./build-seed-usb.sh /dev/sdX   # /dev/sdX = una chiavetta USB vuota,
                                 # DIVERSA da quella con l'ISO di Ubuntu
```

Poi avvia la macchina con entrambe le chiavette inserite (quella con l'ISO
di Ubuntu 26.04 e questa col seed).

## Da testare assolutamente prima del 17 settembre

- [ ] Prova completa in una VM (QEMU o VirtualBox, con firmware UEFI/OVMF
      abilitato) prima di toccare hardware reale.
- [ ] Verifica che al riavvio venga chiesta la passphrase LUKS e che il
      sistema si avvii correttamente sul subvolume `@`.
- [ ] Verifica coi comandi `findmnt` e `btrfs subvolume list /` che i mount
      point risultino esattamente quelli attesi.
- [ ] Verifica che Brave, Ghostty e l'integrazione Nautilus siano già
      presenti al primo login (niente da lanciare a mano).
- [ ] Verifica che Firefox sparisca da solo entro pochi secondi dal primo
      login (`systemctl status ubuntu-ultimate-firstboot` per seguirlo).
