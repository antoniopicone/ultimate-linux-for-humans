#cloud-config
# autoinstall.yaml — layout disco per la ricetta "Ubuntu Ultimate":
#   ESP (fat32) → /boot (ext4, non cifrato) → LUKS2 → BTRFS con subvolume
#   @, @home, @var, @snapshots.
#
# QUESTO È UN TEMPLATE: i segnaposto __TRA_DOPPI_UNDERSCORE__ vengono
# sostituiti da prepare-usb.sh (o dal server HTTP di boot) prima dell'uso.
# Non usarlo mai con il testo dei segnaposto ancora presente: cryptsetup
# fallirebbe o, peggio, userebbe una passphrase letterale sbagliata.
#
# NOTE IMPORTANTI (leggere prima di fidarsi ciecamente in demo):
# - Subiquity (l'installer di Ubuntu Desktop) non sa creare subvolume BTRFS
#   né gestire correttamente LUKS2+BTRFS in modo nativo. Il trucco qui è:
#   1) far installare curtin normalmente su un BTRFS "piatto" (senza
#      subvolume) dentro il container LUKS2;
#   2) a fine installazione (late-commands), convertire quel filesystem
#      piatto già popolato in un vero layout a subvolume con uno snapshot
#      BTRFS (rapido, senza ricopiare i dati), poi rigenerare fstab,
#      initramfs e grub.
# - Questa tecnica è un pattern noto nella community (non ufficialmente
#   documentato/supportato da Canonical) — VA TESTATA in una VM (QEMU/
#   VirtualBox) prima del 17 settembre. Non fidarsi che funzioni al primo
#   colpo su hardware reale senza una prova a secco.
# - /boot resta volutamente FUORI dal container LUKS: GRUB non legge in
#   modo affidabile BTRFS+LUKS2 su /boot (ed è comunque la direzione in cui
#   sta andando anche Canonical stessa, vedi le modifiche a GRUB annunciate
#   per Ubuntu 26.10). Solo la root (e quindi i tuoi dati/home) è cifrata.

autoinstall:
  version: 1

  locale: it_IT.UTF-8
  keyboard:
    layout: it

  # "source" sceglie QUALE variante del sistema curtin copia sul disco di
  # destinazione (chiave documentata nello schema autoinstall di Subiquity,
  # sezione "source"): "ubuntu-desktop-minimal" invece del default
  # "ubuntu-desktop" ("normal install"). NON è un'altra ISO — la stessa ISO
  # ufficiale Ubuntu 26.04.1 Desktop contiene già entrambe le varianti come
  # layer squashfs separati (casper/minimal.squashfs = base minimale,
  # casper/minimal.standard.squashfs = aggiunte "desktop completo" come
  # LibreOffice, giochi, editor multipli — vedi anche live-iso/
  # chroot-customize.sh, che lavora proprio su quel secondo layer). Con
  # questa chiave, curtin copia SOLO il layer base sul disco: install più
  # veloce (meno dati da scrivere) e sistema installato più leggero, non
  # una ISO/sessione live più piccola (la sessione live per avviare
  # l'installer resta comunque il merge di tutti i layer, minimal compreso,
  # qualunque sia la scelta qui).
  # ATTENZIONE: l'ID esatto è specifico della singola ISO (lo dice la stessa
  # documentazione ufficiale) — va confermato contro
  # casper/install-sources.yaml dentro la ISO 26.04.1 reale prima di
  # fidarsene ciecamente in demo; non ancora verificato in questa sessione
  # (nessuna ISO scaricata qui per ispezionarla).
  source:
    id: ubuntu-desktop-minimal
    search_drivers: true

  identity:
    hostname: __HOSTNAME__
    username: __USERNAME__
    # Nome e Cognome (campo "realname" dello schema autoinstall di
    # Subiquity, GECOS a livello di sistema): GDM lo mostra nella schermata
    # di login al posto dello username quando è valorizzato.
    realname: "__REALNAME__"
    # Hash SHA-512 (crypt), generato da prepare-usb.sh con `mkpasswd -m sha-512`.
    # Mai mettere qui una password in chiaro.
    password: "__USER_PASSWORD_HASH__"

  ssh:
    install-server: true
    allow-pw: true

  # Pacchetti necessari perché la conversione post-install a subvolume e il
  # boot cifrato funzionino (initramfs deve includere i hook cryptsetup).
  packages:
    - cryptsetup
    - cryptsetup-initramfs
    - btrfs-progs

  storage:
    config:
      - id: disk0
        type: disk
        match:
          size: largest
        ptable: gpt
        wipe: superblock-recursive
        grub_device: true
        preserve: false

      # --- ESP --------------------------------------------------------
      - id: part_efi
        type: partition
        device: disk0
        size: 512M
        flag: boot
        grub_device: true
      - id: fmt_efi
        type: format
        volume: part_efi
        fstype: fat32
      - id: mnt_efi
        type: mount
        device: fmt_efi
        path: /boot/efi

      # --- /boot, non cifrato (limite di GRUB su BTRFS+LUKS2) ---------
      - id: part_boot
        type: partition
        device: disk0
        size: 1G
      - id: fmt_boot
        type: format
        volume: part_boot
        fstype: ext4
      - id: mnt_boot
        type: mount
        device: fmt_boot
        path: /boot

      # --- root: resto del disco, dentro LUKS2 -------------------------
      - id: part_root
        type: partition
        device: disk0
        size: -1
      - id: dm_crypt_root
        type: dm_crypt
        volume: part_root
        key: "__LUKS_PASSPHRASE__"
        dm_name: cryptroot
        # Non serve forzare la versione: cryptsetup >= 2.x (quello di
        # Ubuntu 26.04) usa LUKS2 di default con 'cryptsetup luksFormat'.
      - id: fmt_root
        type: format
        volume: dm_crypt_root
        fstype: btrfs
      - id: mnt_root
        type: mount
        device: fmt_root
        path: /

  # -----------------------------------------------------------------------
  # late-commands: qui avviene la conversione da BTRFS "piatto" a layout a
  # subvolume. Gira nell'ambiente del live-installer, con /target ancora
  # montato con l'installazione appena completata da curtin.
  # -----------------------------------------------------------------------
  late-commands:
    - |
      set -eux

      # 1. Individua i device reali già montati da curtin (funziona sia con
      #    dischi /dev/sdX che /dev/nvme0nX, senza hardcodare nomi).
      ROOT_DEV="$(findmnt -no SOURCE /target)"
      BOOT_DEV="$(findmnt -no SOURCE /target/boot)"
      EFI_DEV="$(findmnt -no SOURCE /target/boot/efi)"

      # 2. Smonta tutto sotto /target per poter lavorare sul BTRFS "a nudo".
      # -R (ricorsivo) è necessario: curtin, per poter fare chroot su
      # /target a fine installazione (update-grub ecc.), ci monta dentro
      # anche /dev, /proc, /sys, /run in bind mount. Uno "umount /target"
      # semplice fallirebbe con "target is busy" perché restano questi
      # mount figli; -R li smonta tutti insieme, in ordine corretto.
      umount -R /target

      # 3. Monta il subvolume di livello massimo (id 5, quello "piatto" già
      #    popolato dall'installazione appena fatta) e trasformalo in @ con
      #    uno snapshot BTRFS: operazione istantanea (copy-on-write), non
      #    ricopia i dati.
      mkdir -p /mnt/btrfs-top
      mount -o subvolid=5 "${ROOT_DEV}" /mnt/btrfs-top
      btrfs subvolume snapshot /mnt/btrfs-top /mnt/btrfs-top/@

      # 4. Crea i subvolume figli, vuoti.
      btrfs subvolume create /mnt/btrfs-top/@home
      btrfs subvolume create /mnt/btrfs-top/@var
      btrfs subvolume create /mnt/btrfs-top/@snapshots
      # @home_snapshots: sibling top-level a sé stante (non annidato dentro
      # @home) per gli snapshot di /home gestiti da snapper, sullo stesso
      # schema "flat" di @/@home/@var/@snapshots — vedi il blocco snapper
      # più sotto nel blocco software.
      btrfs subvolume create /mnt/btrfs-top/@home_snapshots

      # 5. Sposta il contenuto (skeleton di /home e /var appena installati,
      #    non c'è ancora alcun dato utente a questo punto) dentro ai nuovi
      #    subvolume dedicati.
      rsync -aHAX --remove-source-files /mnt/btrfs-top/@/home/ /mnt/btrfs-top/@home/ 2>/dev/null || true
      rsync -aHAX --remove-source-files /mnt/btrfs-top/@/var/ /mnt/btrfs-top/@var/ 2>/dev/null || true
      find /mnt/btrfs-top/@/home -mindepth 1 -type d -empty -delete 2>/dev/null || true
      find /mnt/btrfs-top/@/var -mindepth 1 -type d -empty -delete 2>/dev/null || true

      umount /mnt/btrfs-top

      # 6. Rimonta tutto secondo il layout definitivo a subvolume.
      MNTOPTS="compress=zstd:3,noatime,ssd,space_cache=v2"
      mount -o "subvol=@,${MNTOPTS}" "${ROOT_DEV}" /target
      mkdir -p /target/home /target/var /target/.snapshots /target/boot
      mount -o "subvol=@home,${MNTOPTS}" "${ROOT_DEV}" /target/home
      mount -o "subvol=@var,${MNTOPTS}" "${ROOT_DEV}" /target/var
      mount -o "subvol=@snapshots,${MNTOPTS}" "${ROOT_DEV}" /target/.snapshots
      # /home/.snapshots va creato SOLO dopo aver montato /target/home (la
      # cartella deve vivere dentro il subvolume @home appena montato, non
      # su @ come placeholder).
      mkdir -p /target/home/.snapshots
      mount -o "subvol=@home_snapshots,${MNTOPTS}" "${ROOT_DEV}" /target/home/.snapshots
      mount "${BOOT_DEV}" /target/boot
      mkdir -p /target/boot/efi
      mount "${EFI_DEV}" /target/boot/efi

      # 7. Riscrivi /etc/fstab dentro il target con gli UUID e le opzioni
      #    subvol= corrette (quello scritto da curtin è per il layout
      #    "piatto" originale e non è più valido).
      ROOT_UUID="$(blkid -s UUID -o value "${ROOT_DEV}")"
      BOOT_UUID="$(blkid -s UUID -o value "${BOOT_DEV}")"
      EFI_UUID="$(blkid -s UUID -o value "${EFI_DEV}")"

      # (niente heredoc qui: dentro un blocco YAML indentato un terminatore
      # "EOF" indentato non verrebbe riconosciuto da bash; si scrive riga
      # per riga con printf, più a prova di indentazione)
      {
        printf '%s\n' '# <file system> <mount point> <type> <options> <dump> <pass>'
        printf 'UUID=%s /            btrfs subvol=@,%s          0 0\n' "${ROOT_UUID}" "${MNTOPTS}"
        printf 'UUID=%s /home        btrfs subvol=@home,%s      0 0\n' "${ROOT_UUID}" "${MNTOPTS}"
        printf 'UUID=%s /var         btrfs subvol=@var,%s       0 0\n' "${ROOT_UUID}" "${MNTOPTS}"
        printf 'UUID=%s /.snapshots  btrfs subvol=@snapshots,%s 0 0\n' "${ROOT_UUID}" "${MNTOPTS}"
        printf 'UUID=%s /home/.snapshots btrfs subvol=@home_snapshots,%s 0 0\n' "${ROOT_UUID}" "${MNTOPTS}"
        printf 'UUID=%s /boot        ext4  defaults             0 2\n' "${BOOT_UUID}"
        printf 'UUID=%s /boot/efi    vfat  umask=0077           0 1\n' "${EFI_UUID}"
      } > /target/etc/fstab

      # 8. Rigenera initramfs e grub dentro il target: initramfs deve
      #    includere gli hook cryptsetup e conoscere /etc/crypttab; grub
      #    deve rileggere il nuovo fstab per aggiungere rootflags=subvol=@
      #    alla riga di comando del kernel.
      curtin in-target --target=/target -- update-initramfs -u -k all
      curtin in-target --target=/target -- update-grub

    # -----------------------------------------------------------------
    # Secondo blocco di late-commands: software (browser, terminale,
    # integrazione Nautilus). Gira DOPO il blocco sopra, quindi /target è
    # già il layout definitivo a subvolume. apt/curl/dpkg funzionano
    # dentro un chroot senza problemi (curtin li usa già per installare
    # il sistema base); dconf/gsettings invece hanno bisogno di un bus
    # D-Bus, che in un chroot offline non esiste — li apriamo al volo con
    # dbus-run-session (tecnica standard per configurare dconf in fase di
    # build, senza un login reale).
    #
    # ECCEZIONE: la rimozione di Firefox (snap) NON può stare qui, perché
    # "snap remove" parla con snapd, che è un servizio — dentro un chroot
    # offline durante l'installazione non gira. Per quello vedi il terzo
    # blocco sotto: un servizio systemd che si esegue una volta sola al
    # primo avvio reale della macchina installata.
    - |
      set -eux

      cat > /target/root/ubuntu-ultimate-software-setup.sh <<'SETUPEOF'
      #!/bin/bash
      set -eux
      export DEBIAN_FRONTEND=noninteractive

      apt-get update

      # Ghostty: repo universe, nativo in Ubuntu 26.04, nessuna PPA.
      apt-get install -y ghostty
      update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator /usr/bin/ghostty 50
      update-alternatives --set x-terminal-emulator /usr/bin/ghostty

      # Brave: repo apt ufficiale.
      apt-get install -y curl
      curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
      curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources https://brave-browser-apt-release.s3.brave.com/brave-browser.sources
      apt-get update
      apt-get install -y brave-browser

      # Nautilus -> Ghostty: il pacchetto "ghostty" di Ubuntu 26.04 porta già
      # di suo un'estensione Nautilus nativa in
      # /usr/share/nautilus-python/extensions/ghostty.py (voce "Apri in
      # Ghostty", con --working-directory e --gtk-single-instance=false già
      # impostati da lei). Serve solo python3-nautilus per farla caricare;
      # NON installiamo nautilus-open-any-terminal via pip, altrimenti
      # comparirebbero due voci duplicate nel menu.
      apt-get install -y python3-nautilus

      # Gestore delle estensioni GNOME (per installare/gestire le estensioni
      # Shell da interfaccia grafica invece che da extensions.gnome.org).
      apt-get install -y gnome-shell-extension-manager

      # Dipendenze di sviluppo per l'integrazione dei contenuti iCloud
      # (Note, Promemoria, ecc.) — PREPARAZIONE: qui installiamo solo le
      # librerie di base per compilare un'app GTK4/libadwaita che li mostri;
      # l'app vera e propria non esiste ancora in questa ricetta, arriva in
      # un prossimo passo. python3-dev è già servito altrove in questa
      # ricetta (icloud-linux/fuse-python: vedi "Note tecniche" nel README).
      apt-get install -y libgtk-4-dev python3-dev libadwaita-1-dev libgtksourceview-5-dev

      # zram: compressione di RAM e swap. Pacchetto ufficiale Ubuntu
      # (systemd-zram-generator), non abilitato di default nella 26.04
      # (la comunità l'ha rimandato a versioni successive). zstd è un
      # buon compromesso compressione/velocità; metà della RAM è la
      # dimensione tipica consigliata.
      apt-get install -y systemd-zram-generator
      mkdir -p /etc/systemd
      cat > /etc/systemd/zram-generator.conf <<'ZRAMEOF'
      [zram0]
      zram-size = ram / 2
      compression-algorithm = zstd
      ZRAMEOF

      # Snapshot del disco: snapper (crea/gestisce gli snapshot BTRFS, sia
      # per / che per /home) + grub-btrfs (li rende selezionabili come voci
      # di avvio dal menu di GRUB, per un rollback rapido in caso di
      # aggiornamento andato storto). snapper e btrfs-assistant (GUI) sono
      # pacchettizzati su Ubuntu; grub-btrfs no — il progetto non fornisce
      # un .deb, va installato da sorgente (make install), come da sua
      # stessa documentazione per le distribuzioni Debian/Ubuntu-based.
      # Configurazione basata sullo script testato da Antonio
      # (setup-snapper-ubuntu2604.sh) su un sistema già vivo, adattata qui
      # per girare offline dentro curtin in-target (vedi note sotto).
      apt-get install -y snapper btrfs-assistant git make gawk inotify-tools

      # I subvolume @snapshots e @home_snapshots (montati su /.snapshots e
      # /home/.snapshots) esistono già, creati nel primo blocco di questo
      # autoinstall durante la conversione a layout BTRFS. Scriviamo le
      # config direttamente (invece di 'snapper create-config', che
      # genera valori di default generici) per usare i retention/policy
      # già collaudati da Antonio: root più conservativo (spazio limitato,
      # meno storia), home con più margine e più storico.
      cat > /etc/snapper/configs/root <<'SNAPPERROOTEOF'
      SUBVOLUME="/"
      FSTYPE="btrfs"
      QGROUP=""
      SPACE_LIMIT="0.5"
      FREE_LIMIT="0.2"
      # ALLOW_USERS + SYNC_ACL=yes: Snapper mantiene da solo le ACL POSIX su
      # .snapshots per l'utente indicato, così può sfogliare/ripristinare le
      # versioni precedenti dei file direttamente dal filesystem (es. da
      # Nautilus, vedi nautilus-snapper-restore) senza dover passare da
      # snapperd/D-Bus/polkit (che il pacchetto Ubuntu di snapper non
      # configura affatto: nessuna regola polkit né ACL di default).
      ALLOW_USERS="__USERNAME__"
      ALLOW_GROUPS=""
      SYNC_ACL="yes"
      BACKGROUND_COMPARISON="yes"
      NUMBER_CLEANUP="yes"
      NUMBER_MIN_AGE="1800"
      NUMBER_LIMIT="50"
      NUMBER_LIMIT_IMPORTANT="10"
      TIMELINE_CREATE="yes"
      TIMELINE_CLEANUP="yes"
      TIMELINE_MIN_AGE="1800"
      TIMELINE_LIMIT_HOURLY="6"
      TIMELINE_LIMIT_DAILY="7"
      TIMELINE_LIMIT_WEEKLY="4"
      TIMELINE_LIMIT_MONTHLY="3"
      TIMELINE_LIMIT_YEARLY="0"
      EMPTY_PRE_POST_CLEANUP="yes"
      EMPTY_PRE_POST_MIN_AGE="1800"
      SNAPPERROOTEOF

      cat > /etc/snapper/configs/home <<'SNAPPERHOMEEOF'
      SUBVOLUME="/home"
      FSTYPE="btrfs"
      QGROUP=""
      SPACE_LIMIT="0.5"
      FREE_LIMIT="0.2"
      # Vedi commento sopra sulla config "root": stesso motivo.
      ALLOW_USERS="__USERNAME__"
      ALLOW_GROUPS=""
      SYNC_ACL="yes"
      BACKGROUND_COMPARISON="yes"
      NUMBER_CLEANUP="yes"
      NUMBER_MIN_AGE="1800"
      NUMBER_LIMIT="50"
      NUMBER_LIMIT_IMPORTANT="10"
      TIMELINE_CREATE="yes"
      TIMELINE_CLEANUP="yes"
      TIMELINE_MIN_AGE="1800"
      TIMELINE_LIMIT_HOURLY="12"
      TIMELINE_LIMIT_DAILY="14"
      TIMELINE_LIMIT_WEEKLY="8"
      TIMELINE_LIMIT_MONTHLY="6"
      TIMELINE_LIMIT_YEARLY="0"
      EMPTY_PRE_POST_CLEANUP="yes"
      EMPTY_PRE_POST_MIN_AGE="1800"
      SNAPPERHOMEEOF

      echo 'SNAPPER_CONFIGS="root home"' > /etc/default/snapper
      chmod 750 /.snapshots /home/.snapshots
      chown root:root /.snapshots /home/.snapshots

      # A differenza dello script originale (pensato per un sistema già
      # vivo), qui NON riavviamo/verifichiamo snapperd via D-Bus: in
      # questo chroot offline non c'è un'istanza reale di systemd/D-Bus in
      # esecuzione, quindi non serve invalidare nessuna cache — snapperd
      # leggerà le config appena scritte al primo avvio vero, che è anche
      # la prima volta che gira.
      systemctl enable snapper-timeline.timer snapper-cleanup.timer || true
      systemctl enable snapper-boot.timer 2>/dev/null || true

      # nautilus-snapper-restore: estensione Nautilus (menu tasto destro ->
      # "Versioni precedenti (Snapper)...") + visualizzatore GTK4 standalone
      # per ripristinare versioni precedenti dei file dagli snapshot Snapper
      # senza passare da snapperd/D-Bus (che il pacchetto Ubuntu di snapper
      # non configura affatto, vedi sopra) — richiede solo che le ACL sopra
      # (ALLOW_USERS/SYNC_ACL) diano accesso in lettura a .snapshots, cosa
      # che avviene al primo snapshot creato dopo il boot, non subito qui
      # nel chroot offline. Consegnato/validato a parte in questa stessa
      # sessione (progetto "nautilus-snapper-restore"), incluso qui perché
      # richiesto esplicitamente da Antonio dopo averlo provato in VM.
      # Installato a livello di SISTEMA (non nella home di un utente
      # specifico, stesso motivo delle estensioni GNOME Shell sopra):
      # python3-nautilus cerca le estensioni anche in
      # /usr/share/nautilus-python/extensions/, non solo in
      # ~/.local/share/nautilus-python/extensions/, e /usr/local/bin/ è
      # già nel PATH di default per qualunque utente/sessione (a differenza
      # di ~/.local/bin, che senza un logout/login non lo è sempre: un
      # problema reale incontrato validando la versione per-utente).
      apt-get install -y python3-nautilus gir1.2-gtk-4.0

      mkdir -p /usr/share/nautilus-python/extensions
      cat > /usr/share/nautilus-python/extensions/snapper_restore_menu.py <<'SNAPPERMENUEOF'
      """
      snapper_restore_menu.py — estensione Nautilus (API 4.0 / GTK4) che aggiunge
      una voce "Versioni precedenti (Snapper)…" al menu tasto destro di un file,
      per aprire il visualizzatore/ripristino versioni (nautilus-snapper-viewer).

      Perché così: da Nautilus 43 (API nautilus-python 4.0) PropertyPageProvider
      è stato sostituito da PropertiesModelProvider, che mostra solo coppie
      nome/valore testuali — niente più widget custom dentro Nautilus stesso
      (vedi la guida ufficiale "Migrating to Nautilus API 4.0"). L'interfaccia
      vera e propria vive quindi in un programma a parte (bin/nautilus-snapper-
      viewer, GTK4), lanciato da questa voce di menu — esattamente il pattern
      suggerito dalla guida per chi ha bisogno di UI più ricca di una semplice
      lista di proprietà.

      Installazione: vedi ../install.sh (copia questo file in
      ~/.local/share/nautilus-python/extensions/ e il viewer in ~/.local/bin/).
      """

      import subprocess
      from urllib.parse import unquote, urlparse

      import gi

      try:
          gi.require_version("Nautilus", "4.0")
      except ValueError:
          # Nautilus stesso carica già il proprio namespace GI PRIMA di eseguire le
          # estensioni: su alcune versioni (es. Ubuntu 26.04, verificato in
          # questa stessa sessione con il traceback reale dell'utente) è già la
          # 4.1, non la 4.0, e richiederne esplicitamente un'altra fa fallire
          # gi.require_version con ValueError "Namespace Nautilus is already
          # loaded with version 4.1" — l'estensione moriva qui, prima ancora di
          # registrarsi, senza che comparisse nessuna voce di menu. L'API usata
          # da questa estensione (MenuProvider.get_file_items) non è cambiata tra
          # 4.0 e 4.1, quindi va bene semplicemente usare qualunque versione
          # Nautilus abbia già caricato, invece di pretenderne una precisa.
          pass
      from gi.repository import GObject, Nautilus  # noqa: E402

      VIEWER_COMMAND = "nautilus-snapper-viewer"


      def _uri_to_path(uri):
          """file:///a/b%20c -> /a/b c (None se non è un file locale)."""
          parsed = urlparse(uri)
          if parsed.scheme != "file":
              return None
          return unquote(parsed.path)


      class SnapperRestoreMenuProvider(GObject.GObject, Nautilus.MenuProvider):
          def get_file_items(self, files):
              # Solo per selezioni singole: il viewer ragiona su un file alla
              # volta. Su una selezione multipla non mostriamo la voce, invece
              # di aprire N finestre o comportarci in modo ambiguo.
              if len(files) != 1:
                  return []

              file_info = files[0]
              if file_info.is_directory():
                  return []

              path = _uri_to_path(file_info.get_uri())
              if not path:
                  return []

              item = Nautilus.MenuItem.new(
                  name="SnapperRestoreMenuProvider::open_versions",
                  label="Versioni precedenti (Snapper)…",
                  tip="Mostra le versioni precedenti di questo file salvate dagli snapshot Snapper",
                  icon="document-open-recent-symbolic",
              )
              item.connect("activate", self._on_activate, path)
              return [item]

          def get_background_items(self, current_folder):
              # Non ha senso sulla cartella stessa (il viewer lavora su un file
              # preciso): nessuna voce nel menu di sfondo.
              return []

          def _on_activate(self, _menu_item, path):
              # Processo staccato: se il viewer si pianta o impiega tempo, non
              # deve bloccare né far apparire errori dentro Nautilus stesso.
              subprocess.Popen([VIEWER_COMMAND, path])
      SNAPPERMENUEOF

      cat > /usr/local/bin/nautilus-snapper-viewer <<'SNAPPERVIEWEREOF'
      #!/usr/bin/env python3
      """
      nautilus-snapper-viewer — finestra GTK4 standalone che mostra le versioni
      precedenti di un file, prese dagli snapshot Snapper, e permette di aprirle
      o ripristinarle. Lanciata dall'estensione Nautilus (vedi
      ../nautilus-python/snapper_restore_menu.py), ma funziona anche da riga di
      comando: nautilus-snapper-viewer /percorso/al/file

      Perché un programma separato invece di un tab dentro Nautilus:
      Nautilus, dalla API 4.0 (Nautilus 43+, GTK4), ha sostituito
      PropertyPageProvider con PropertiesModelProvider, che mostra SOLO coppie
      nome/valore testuali — niente più widget custom (liste, pulsanti) dentro
      Nautilus stesso. Un'interfaccia interattiva come questa deve quindi vivere
      in una finestra propria, lanciata da una voce di menu (vedi la guida
      ufficiale di migrazione di nautilus-python alla API 4.0).

      Come vengono trovate le versioni precedenti:
      Legge direttamente da <subvolume>/.snapshots/<N>/snapshot/<percorso relativo>
      (il layout con cui Snapper organizza gli snapshot Btrfs su disco), SENZA
      passare da snapperd/D-Bus: più semplice, non richiede polkit, e funziona
      anche se snapperd non gira. Perché l'utente normale possa leggere dentro
      .snapshots serve però che la config Snapper del subvolume abbia
      ALLOW_USERS/ALLOW_GROUPS + SYNC_ACL=yes (Snapper mantiene lui le ACL POSIX
      di conseguenza) — vedi disk-setup/scripts/... nella ricetta "Ubuntu
      Ultimate", che imposta esattamente questo per le config root/home.
      """

      import datetime
      import glob
      import os
      import shutil
      import sys
      import xml.etree.ElementTree as ET

      import gi

      gi.require_version("Gtk", "4.0")
      from gi.repository import Gio, GLib, Gtk  # noqa: E402


      # --- Logica (senza GTK, testabile da sola) ---------------------------------


      def find_snapper_configs(configs_dir="/etc/snapper/configs"):
          """Legge /etc/snapper/configs/* e ritorna {nome_config: percorso_subvolume}."""
          configs = {}
          for path in glob.glob(os.path.join(configs_dir, "*")):
              if not os.path.isfile(path):
                  continue
              name = os.path.basename(path)
              subvolume = None
              try:
                  with open(path, encoding="utf-8") as f:
                      for line in f:
                          line = line.strip()
                          if line.startswith("SUBVOLUME="):
                              subvolume = line.split("=", 1)[1].strip().strip('"')
                              break
              except OSError:
                  continue
              if subvolume:
                  configs[name] = subvolume
          return configs


      def find_config_for_path(path, configs):
          """Sceglie la config il cui subvolume è l'antenato più vicino di 'path'.

          Ritorna (nome_config, percorso_subvolume_reale) oppure None se il
          percorso non è sotto nessuna config nota.
          """
          real_path = os.path.realpath(path)
          best = None
          for name, subvolume in configs.items():
              real_subvolume = os.path.realpath(subvolume)
              if real_path == real_subvolume or real_path.startswith(
                  real_subvolume.rstrip("/") + "/"
              ):
                  if best is None or len(real_subvolume) > len(best[1]):
                      best = (name, real_subvolume)
          return best


      def read_snapshot_info(info_xml_path):
          """Legge data/descrizione da info.xml (il formato che scrive Snapper stesso)."""
          try:
              root = ET.parse(info_xml_path).getroot()
          except (OSError, ET.ParseError):
              return {}
          date_text = root.findtext("date")
          date_human = date_text
          if date_text:
              # Snapper scrive "YYYY-MM-DD HH:MM:SS" in UTC.
              try:
                  dt = datetime.datetime.strptime(date_text, "%Y-%m-%d %H:%M:%S")
                  date_human = dt.strftime("%d/%m/%Y %H:%M")
              except ValueError:
                  pass
          return {
              "date": date_human,
              "description": root.findtext("description") or "",
          }


      def list_snapshots_with_file(subvolume, rel_path):
          """Versioni precedenti di rel_path (dentro subvolume) diverse da quella
          attuale, più recenti prima. Ogni voce: number, path, date, description,
          size.
          """
          snapshots_root = os.path.join(subvolume, ".snapshots")
          if not os.path.isdir(snapshots_root):
              return []

          current_path = os.path.join(subvolume, rel_path)
          try:
              current_stat = os.stat(current_path)
          except OSError:
              current_stat = None

          results = []
          try:
              entries = sorted(
                  (e for e in os.listdir(snapshots_root) if e.isdigit()),
                  key=int,
                  reverse=True,
              )
          except OSError:
              return []

          for entry in entries:
              snap_file = os.path.join(snapshots_root, entry, "snapshot", rel_path)
              try:
                  st = os.stat(snap_file)
              except OSError:
                  continue
              if not os.path.isfile(snap_file):
                  continue
              if current_stat is not None and (
                  st.st_mtime == current_stat.st_mtime and st.st_size == current_stat.st_size
              ):
                  # Stessa dimensione e stesso mtime del file attuale: quasi
                  # certamente la stessa versione, non la mostriamo (altrimenti
                  # ogni file avrebbe decine di voci identiche, una per snapshot).
                  continue
              info = read_snapshot_info(os.path.join(snapshots_root, entry, "info.xml"))
              results.append(
                  {
                      "number": entry,
                      "path": snap_file,
                      "date": info.get("date") or "data sconosciuta",
                      "description": info.get("description") or "",
                      "size": st.st_size,
                  }
              )
          return results


      def human_size(n):
          n = float(n)
          for unit in ("B", "KiB", "MiB", "GiB"):
              if n < 1024 or unit == "GiB":
                  return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
              n /= 1024
          return f"{n:.1f} GiB"


      # --- Interfaccia GTK4 --------------------------------------------------------


      class SnapperViewerWindow(Gtk.ApplicationWindow):
          def __init__(self, app, target_path):
              super().__init__(application=app)
              self.target_path = target_path
              self.set_title(f"Versioni precedenti — {os.path.basename(target_path)}")
              self.set_default_size(640, 420)

              box = Gtk.Box(
                  orientation=Gtk.Orientation.VERTICAL,
                  spacing=8,
                  margin_top=12,
                  margin_bottom=12,
                  margin_start=12,
                  margin_end=12,
              )
              self.set_child(box)

              configs = find_snapper_configs()
              match = find_config_for_path(os.path.dirname(target_path), configs)

              if match is None:
                  box.append(
                      Gtk.Label(
                          label=(
                              "Questo file non si trova in un percorso gestito da "
                              "Snapper (nessuna config trovata per "
                              f"{target_path})."
                          ),
                          wrap=True,
                      )
                  )
                  return

              config_name, subvolume = match
              rel_path = os.path.relpath(os.path.realpath(target_path), subvolume)
              snapshots = list_snapshots_with_file(subvolume, rel_path)

              header = Gtk.Label(label=f"{target_path}  ·  config snapper: {config_name}")
              header.set_xalign(0)
              header.add_css_class("dim-label")
              header.set_wrap(True)
              box.append(header)

              if not snapshots:
                  box.append(
                      Gtk.Label(
                          label=(
                              "Nessuna versione precedente diversa da quella attuale "
                              "trovata negli snapshot disponibili."
                          ),
                          wrap=True,
                      )
                  )
                  return

              listbox = Gtk.ListBox()
              listbox.set_selection_mode(Gtk.SelectionMode.SINGLE)
              listbox.add_css_class("boxed-list")

              for snap in snapshots:
                  row = Gtk.ListBoxRow()
                  hbox = Gtk.Box(
                      orientation=Gtk.Orientation.HORIZONTAL,
                      spacing=12,
                      margin_top=6,
                      margin_bottom=6,
                      margin_start=6,
                      margin_end=6,
                  )
                  label_text = f"#{snap['number']} — {snap['date']}"
                  if snap["description"]:
                      label_text += f" — {snap['description']}"
                  label = Gtk.Label(label=label_text, xalign=0, hexpand=True)
                  size_label = Gtk.Label(label=human_size(snap["size"]))
                  size_label.add_css_class("dim-label")
                  hbox.append(label)
                  hbox.append(size_label)
                  row.set_child(hbox)
                  row.snapshot_data = snap
                  listbox.append(row)

              scroller = Gtk.ScrolledWindow()
              scroller.set_vexpand(True)
              scroller.set_child(listbox)
              box.append(scroller)
              self.listbox = listbox
              listbox.select_row(listbox.get_row_at_index(0))

              btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
              btn_box.set_halign(Gtk.Align.END)
              open_btn = Gtk.Button(label="Apri questa versione")
              restore_btn = Gtk.Button(label="Ripristina questa versione")
              restore_btn.add_css_class("destructive-action")
              btn_box.append(open_btn)
              btn_box.append(restore_btn)
              box.append(btn_box)

              open_btn.connect("clicked", self.on_open_clicked)
              restore_btn.connect("clicked", self.on_restore_clicked)

          def selected_snapshot(self):
              row = self.listbox.get_selected_row()
              return getattr(row, "snapshot_data", None) if row else None

          def on_open_clicked(self, _button):
              snap = self.selected_snapshot()
              if not snap:
                  return
              uri = GLib.filename_to_uri(snap["path"], None)
              Gio.AppInfo.launch_default_for_uri(uri, None)

          def on_restore_clicked(self, _button):
              snap = self.selected_snapshot()
              if not snap:
                  return
              dialog = Gtk.AlertDialog()
              dialog.set_message("Ripristinare questa versione?")
              dialog.set_detail(
                  f"Il file attuale verrà sovrascritto con la versione dello "
                  f"snapshot #{snap['number']} ({snap['date']}).\n"
                  "Prima di sovrascrivere viene creata una copia di sicurezza del "
                  "file attuale accanto ad esso (suffisso .bak-AAAAMMGG-HHMMSS)."
              )
              dialog.set_buttons(["Annulla", "Ripristina"])
              dialog.set_cancel_button(0)
              dialog.set_default_button(0)

              def on_response(d, result):
                  try:
                      choice = d.choose_finish(result)
                  except GLib.Error:
                      return
                  if choice == 1:
                      self.do_restore(snap)

              dialog.choose(self, None, on_response)

          def do_restore(self, snap):
              try:
                  if os.path.exists(self.target_path):
                      backup = (
                          f"{self.target_path}"
                          f".bak-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}"
                      )
                      shutil.copy2(self.target_path, backup)
                  shutil.copy2(snap["path"], self.target_path)
                  self._info_dialog("Fatto", f"Ripristinato dallo snapshot #{snap['number']}.")
              except OSError as e:
                  self._info_dialog("Errore durante il ripristino", str(e))

          def _info_dialog(self, title, detail):
              d = Gtk.AlertDialog()
              d.set_message(title)
              d.set_detail(detail)
              d.show(self)


      def main(argv):
          if len(argv) < 2:
              print("Uso: nautilus-snapper-viewer <percorso-file>", file=sys.stderr)
              return 1
          target_path = os.path.abspath(argv[1])

          app = Gtk.Application(application_id="it.antoniopicone.NautilusSnapperViewer")

          def on_activate(app):
              win = SnapperViewerWindow(app, target_path)
              win.present()

          app.connect("activate", on_activate)
          return app.run(None)


      if __name__ == "__main__":
          sys.exit(main(sys.argv))
      SNAPPERVIEWEREOF
      chmod 755 /usr/local/bin/nautilus-snapper-viewer

      git clone --depth=1 https://github.com/Antynea/grub-btrfs.git /tmp/grub-btrfs
      (cd /tmp/grub-btrfs && make install)
      rm -rf /tmp/grub-btrfs

      # NB: NON abilitiamo GRUB_BTRFS_ENABLE_CRYPTODISK (resta al suo
      # default "false"): serve solo quando /boot stesso vive dentro il
      # volume cifrato, e nel nostro layout /boot è volutamente fuori da
      # LUKS (vedi commento in testa al file) — GRUB non deve mai decifrare
      # nulla per trovare kernel/initrd, né per quelli di uno snapshot: la
      # decifratura la fa sempre l'initramfs via cryptsetup, cambia solo
      # il rootflags=subvol= nella riga di comando del kernel.

      # Il servizio installato di default monitora solo /.snapshots: con
      # un drop-in lo facciamo monitorare anche /home/.snapshots, così le
      # voci di boot-da-snapshot in GRUB coprono anche gli snapshot di
      # /home. Percorso del binario confermato dal Makefile upstream
      # (PREFIX=/usr, BIN_DIR=$PREFIX/bin): /usr/bin/grub-btrfsd, non
      # /usr/local/bin come in alcune guide in giro.
      mkdir -p /etc/systemd/system/grub-btrfsd.service.d
      cat > /etc/systemd/system/grub-btrfsd.service.d/override.conf <<'GRUBBTRFSDEOF'
      [Service]
      ExecStart=
      ExecStart=/usr/bin/grub-btrfsd --syslog /.snapshots /home/.snapshots
      GRUBBTRFSDEOF

      systemctl enable grub-btrfsd.service || echo "ATTENZIONE: impossibile abilitare grub-btrfsd.service, controllare a mano." >&2

      # GRUB: menu visibile con 5 secondi di timeout (invece del default
      # Ubuntu, che lo tiene nascosto/timeout 0 e richiede tenere premuto
      # Shift). Idempotente: sostituisce la riga se già presente
      # (commentata o no), altrimenti la aggiunge in fondo.
      sed -i -E 's/^#?GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
      sed -i -E 's/^#?GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
      grep -q '^GRUB_TIMEOUT=' /etc/default/grub || echo 'GRUB_TIMEOUT=5' >> /etc/default/grub
      grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub || echo 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub

      # Utility da riga di comando di base.
      apt-get install -y vim curl wget htop avahi-daemon git lm-sensors gnome-sushi

      # Font: "stile Windows/Office" + a larghezza fissa per il terminale.
      # I font "core" storici di Microsoft (Arial, Times New Roman, Courier
      # New, Georgia, Verdana, Comic Sans MS, Impact, Trebuchet MS, Andale
      # Mono, Webdings) sono liberamente ridistribuibili sotto l'EULA
      # storica "TrueType core fonts for the Web": ttf-mscorefonts-installer
      # (multiverse, già abilitato di default sulla ISO desktop) li scarica
      # da solo, accettando l'EULA in modo non interattivo via debconf
      # (equivalente a spuntare "Accetto" nella finestra che altrimenti
      # apparirebbe).
      echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | debconf-set-selections
      DEBIAN_FRONTEND=noninteractive apt-get install -y ttf-mscorefonts-installer
      # I font più recenti di Office (Calibri, Cambria, Candara, Consolas,
      # Constantia, Corbel) NON sono coperti da quella EULA: restano
      # proprietari, licenziati solo con Windows/Office, non
      # ridistribuibili liberamente. Carlito e Caladea (licenza OFL) sono
      # sostituti liberi metric-compatible di Calibri e Cambria (stessa
      # metrica carattere per carattere, usati da LibreOffice/Google Docs
      # proprio per questo): un documento impaginato con Calibri/Cambria
      # resta identico a video e in stampa.
      apt-get install -y fonts-crosextra-carlito fonts-crosextra-caladea
      # JetBrains Mono (licenza OFL, pacchettizzato ufficialmente su Ubuntu).
      apt-get install -y fonts-jetbrains-mono
      # Hack Nerd Font (Hack patchato con le icone Nerd Fonts — utile per
      # prompt come Pure/Starship/p10k e barre di stato tipo waybar): non è
      # in nessun repository Ubuntu, va preso dalla release ufficiale del
      # progetto nerd-fonts (licenza MIT). Installato a livello di sistema
      # (non nella home di un utente specifico) in
      # /usr/local/share/fonts/, il percorso standard per font di terze
      # parti validi per tutti gli utenti.
      apt-get install -y unzip
      curl -fsSL -o /tmp/HackNerdFont.zip "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Hack.zip"
      mkdir -p /usr/local/share/fonts/HackNerdFont
      unzip -oq /tmp/HackNerdFont.zip -d /usr/local/share/fonts/HackNerdFont '*.ttf'
      rm -f /tmp/HackNerdFont.zip
      fc-cache -f >/dev/null
      # SF Pro (macOS) NON viene installato qui: la licenza Apple
      # (Apple Font License Agreement, developer.apple.com/fonts/) limita
      # l'uso di San Francisco alla progettazione di interfacce PER
      # piattaforme Apple e ne vieta la ridistribuzione — niente mirror non
      # ufficiali nella ricetta. Su una macchina già installata puoi
      # scaricarlo tu da developer.apple.com/fonts/ (serve un Apple ID) e
      # installarlo con scripts/14-install-fonts.sh (vedi README).

      # OnlyOffice al posto di LibreOffice (preinstallato di default su
      # Ubuntu Desktop). Idempotente: rimuove solo se qualche pacchetto
      # libreoffice* risulta davvero installato, installa ONLYOFFICE solo
      # se non c'è già. Repository apt ufficiale (non snap, per coerenza
      # con la scelta già fatta per Brave/Ghostty/Tailscale: aggiornamenti
      # automatici via apt upgrade, nessun sandboxing snap).
      LIBREOFFICE_PKGS="$(dpkg-query -W -f='${Package}\n' 'libreoffice*' 2>/dev/null || true)"
      if [[ -n "${LIBREOFFICE_PKGS}" ]]; then
          apt-get purge -y ${LIBREOFFICE_PKGS}
          apt-get autoremove -y
      else
          echo "LibreOffice non risulta installato, salto la rimozione." >&2
      fi

      if dpkg -s onlyoffice-desktopeditors >/dev/null 2>&1; then
          echo "onlyoffice-desktopeditors già installato, salto." >&2
      else
          apt-get install -y gnupg dirmngr
          mkdir -p -m 700 /root/.gnupg
          gpg --no-default-keyring --keyring gnupg-ring:/tmp/onlyoffice.gpg \
              --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys CB2DE8E5
          chmod 644 /tmp/onlyoffice.gpg
          mv /tmp/onlyoffice.gpg /usr/share/keyrings/onlyoffice.gpg
          echo 'deb [signed-by=/usr/share/keyrings/onlyoffice.gpg] https://download.onlyoffice.com/repo/debian squeeze main' \
              > /etc/apt/sources.list.d/onlyoffice.list
          apt-get update
          apt-get install -y onlyoffice-desktopeditors
      fi

      # 3 .desktop separati per aprire direttamente un documento/foglio di
      # calcolo/presentazione vuoti, invece della sola schermata "Start" di
      # ONLYOFFICE: usano i flag --new:word/--new:cell/--new:slide del
      # binario, documentati da ONLYOFFICE stesso (non un trucco nostro).
      cat > /usr/share/applications/onlyoffice-new-document.desktop <<'DESKTOPEOF'
      [Desktop Entry]
      Type=Application
      Name=Nuovo documento ONLYOFFICE
      GenericName=Documento di testo
      Comment=Crea un nuovo documento di testo con ONLYOFFICE
      Exec=/usr/bin/desktopeditors --new:word
      Icon=x-office-document
      Terminal=false
      Categories=Office;WordProcessor;
      DESKTOPEOF

      cat > /usr/share/applications/onlyoffice-new-spreadsheet.desktop <<'DESKTOPEOF'
      [Desktop Entry]
      Type=Application
      Name=Nuovo foglio di calcolo ONLYOFFICE
      GenericName=Foglio di calcolo
      Comment=Crea un nuovo foglio di calcolo con ONLYOFFICE
      Exec=/usr/bin/desktopeditors --new:cell
      Icon=x-office-spreadsheet
      Terminal=false
      Categories=Office;Spreadsheet;
      DESKTOPEOF

      cat > /usr/share/applications/onlyoffice-new-presentation.desktop <<'DESKTOPEOF'
      [Desktop Entry]
      Type=Application
      Name=Nuova presentazione ONLYOFFICE
      GenericName=Presentazione
      Comment=Crea una nuova presentazione con ONLYOFFICE
      Exec=/usr/bin/desktopeditors --new:slide
      Icon=x-office-presentation
      Terminal=false
      Categories=Office;Presentation;
      DESKTOPEOF

      chmod 644 /usr/share/applications/onlyoffice-new-*.desktop
      update-desktop-database /usr/share/applications >/dev/null 2>&1 || true

      # Supporto APFS (SOLA LETTURA) via apfs-fuse: legge dischi/partizioni
      # formattati APFS (macOS, da High Sierra in poi) — utile per aprire
      # un disco esterno o un case USB proveniente da un Mac. Non esiste un
      # pacchetto apt per apfs-fuse su Ubuntu (verificato: nessun risultato
      # su packages.ubuntu.com), va compilato da sorgente — stesso schema
      # già usato sopra per grub-btrfs (git clone + make install), con la
      # differenza che qui c'è vero codice C++ da compilare (grub-btrfs
      # installa solo script bash, nessuna compilazione). Pacchetti di
      # build presi dal README ufficiale del progetto, con una correzione:
      # il README elenca "gcc-c++" tra i pacchetti Debian/Ubuntu, ma quel
      # nome è quello usato da Fedora/RHEL — su Ubuntu il pacchetto giusto
      # è "g++" (verificato: "gcc-c++" non esiste su packages.ubuntu.com).
      #
      # SOLA LETTURA per scelta dello stesso progetto upstream (non nostra):
      # niente scrittura, quindi nessun rischio di corrompere un disco Mac
      # collegato per errore. NON aggiungiamo il supporto in scrittura
      # (linux-apfs-rw, modulo kernel fuori-albero con scrittura
      # sperimentale): richiederebbe DKMS + firma del modulo per Secure
      # Boot, cioè un enrollment MOK interattivo al riavvio — impossibile
      # da automatizzare in un autoinstall unattended — e comunque lo
      # stesso progetto lo definisce sperimentale.
      apt-get install -y fuse3 libfuse3-dev bzip2 libbz2-dev cmake g++ libattr1-dev zlib1g-dev git

      git clone https://github.com/sgan81/apfs-fuse.git /tmp/apfs-fuse
      (cd /tmp/apfs-fuse && git submodule init && git submodule update)
      # ApfsLib/PList.h usa uint8_t/uint32_t senza includere <cstdint>:
      # con GCC più vecchi arrivava comunque per inclusione transitiva da
      # <memory>, ma con GCC 15 (quello di Ubuntu 26.04, libstdc++ più
      # rigorosa sugli include transitivi) la compilazione fallisce con
      # "'uint8_t' does not name a type" — errore reale riscontrato in VM,
      # lo stesso messaggio del compilatore suggerisce il fix.
      sed -i '1i #include <cstdint>' /tmp/apfs-fuse/ApfsLib/PList.h
      mkdir -p /tmp/apfs-fuse/build
      # -DCMAKE_POLICY_VERSION_MINIMUM=3.5: il CMakeLists.txt di apfs-fuse
      # (e/o del sottomodulo lzfse) dichiara "cmake_minimum_required" con
      # una versione troppo vecchia per il cmake moderno di Ubuntu 26.04
      # (>= 4.0 ha rimosso la compatibilità con < 3.5) — errore reale
      # riscontrato in VM ("CMake Error ... Compatibility with CMake < 3.5
      # has been removed"), risolto con il flag suggerito dallo stesso
      # messaggio d'errore di cmake.
      (cd /tmp/apfs-fuse/build && cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && make -j"$(nproc)" && make install)
      rm -rf /tmp/apfs-fuse
      # Installa in /usr/local/bin/{apfs-fuse,apfsutil} (CMAKE_INSTALL_BINDIR
      # di default): uso da terminale, `apfs-fuse <device> <mountpoint>` —
      # vedi README per il dettaglio.
      #
      # Integrazione con Nautilus/udisks2: da soli, Nautilus non sa cosa
      # farsene di apfs-fuse — quando riconosce una partizione APFS (via
      # blkid) prova ad automontarla con "mount -t apfs", che fallisce
      # perché non esiste alcun driver APFS nel kernel (errore reale
      # riscontrato in VM: "filesystem apfs non configurato nel kernel").
      # Stesso meccanismo con cui ntfs-3g/exfat-fuse si integrano con
      # mount(8) senza supporto kernel dedicato: un helper esterno
      # "/sbin/mount.apfs" che mount(8) (quindi anche udisks2/Nautilus)
      # esegue automaticamente al posto del driver kernel inesistente.
      # Sintassi imposta da mount(8) stesso (man mount, sezione "EXTERNAL
      # HELPERS"): /sbin/mount.<suffix> spec dir [-sfnv] [-N ns] [-o opts]
      # [-t type.subtype]. Le opzioni booleane e -N/-t vengono ignorate
      # (nessun equivalente sensato per un mount FUSE in sola lettura).
      # udisks2 passa nelle -o TUTTE le opzioni di mount, incluse quelle
      # specifiche sue (es. "uhelper=udisks2") o generiche del VFS
      # (nodev/nosuid/noexec/relatime/...) senza sapere che la
      # destinazione è un filesystem FUSE: libfuse (usata da apfs-fuse)
      # rifiuta con "fuse: unknown option(s)" qualsiasi opzione che non
      # riconosce — errore reale riscontrato in VM ("fuse: unknown
      # option(s): `-o uhelper=udisks2'"). Filtriamo quindi le opzioni,
      # passando a apfs-fuse solo quelle che libfuse/apfs-fuse capiscono
      # (ro, rw, uid=, gid=, nonempty) e scartando silenziosamente il
      # resto.
      #
      # "allow_other" è FORZATA sempre, indipendentemente da cosa passa
      # udisks2: udisks2 monta sempre come root (demone privilegiato), e
      # un filesystem FUSE montato da root è visibile di default solo a
      # root — senza "allow_other" l'utente normale ottiene "permessi
      # non sufficienti" aprendo il disco da Nautilus (errore reale
      # riscontrato). apfs non è tra i filesystem "noti" a udisks2 (a
      # differenza di NTFS/exFAT), quindi udisks2 non aggiunge da solo
      # le opzioni giuste — le forziamo qui. Nessuna modifica a
      # /etc/fuse.conf necessaria: "allow_other" è sempre permesso
      # quando chi monta è root (la restrizione "user_allow_other"
      # riguarda solo mount fatti da utenti non privilegiati).
      cat > /sbin/mount.apfs <<'MOUNTAPFSEOF'
      #!/bin/bash
      set -euo pipefail
      SPEC="$1"
      DIR="$2"
      shift 2
      OPTS=""
      while getopts ":sfnvN:o:t:" opt; do
          case "$opt" in
              o) OPTS="$OPTARG" ;;
              *) ;;
          esac
      done
      FILTERED="allow_other"
      IFS=',' read -ra OPT_ARR <<< "${OPTS}"
      for o in "${OPT_ARR[@]}"; do
          case "$o" in
              ro|rw|uid=*|gid=*|nonempty)
                  FILTERED="${FILTERED},${o}"
                  ;;
              *) ;;
          esac
      done
      exec /usr/local/bin/apfs-fuse -o "${FILTERED}" "${SPEC}" "${DIR}"
      MOUNTAPFSEOF
      chmod 755 /sbin/mount.apfs

      # USBGuard: controllo di accesso ai dispositivi USB (blocca di
      # default tutto ciò che non è esplicitamente permesso).
      apt-get install -y usbguard

      # Genera la policy iniziale sui dispositivi GIA' connessi in questo
      # momento. Funziona correttamente anche dentro curtin in-target
      # perché il chroot condivide /dev e /sys con l'ambiente live
      # dell'installer (stesso trucco già usato per il blocco disco): vede
      # quindi i device REALI della macchina, tastiera/trackpad interne
      # comprese — fondamentale, perché la policy di default di usbguard
      # blocca tutto il resto e un errore qui rischia di lasciare tastiera
      # e mouse inutilizzabili al primo avvio.
      usbguard generate-policy > /etc/usbguard/rules.conf
      chmod 0600 /etc/usbguard/rules.conf

      # Permette agli utenti del gruppo 'sudo' (il nostro utente ci è già,
      # creato così da Subiquity) di interrogare/gestire usbguard da riga
      # di comando e via il notificatore desktop sotto, invece di dover
      # editare a mano la policy da root ogni volta. Di default solo root
      # ha accesso IPC.
      sed -i '/^#\?IPCAllowedGroups=/d' /etc/usbguard/usbguard-daemon.conf
      echo 'IPCAllowedGroups=sudo' >> /etc/usbguard/usbguard-daemon.conf

      systemctl enable usbguard.service

      TARGET_USER="__USERNAME__"

      # usbguard-notifier (fork di Antonio, github.com/antoniopicone/
      # usbguard-notifier): notifiche desktop sugli eventi di USBGuard.
      # Non è pacchettizzato: si compila con autotools e si installa
      # nell'home dell'utente, come servizio systemd --user (non di
      # sistema) — coerente con come il progetto stesso documenta
      # l'installazione locale.
      # systemd-dev fornisce il file pkg-config systemd.pc: senza, "configure"
      # non riesce a determinare la systemd user unit dir e fallisce con
      # "Cannot detect the systemd system unit dir".
      apt-get install -y libusbguard-dev libnotify-dev librsvg2-dev asciidoc autoconf automake libtool pkg-config systemd-dev g++ git

      TARGET_USER_HOME="/home/${TARGET_USER}"
      git clone --depth=1 https://github.com/antoniopicone/usbguard-notifier.git /tmp/usbguard-notifier
      chown -R "${TARGET_USER}:${TARGET_USER}" /tmp/usbguard-notifier
      su - "${TARGET_USER}" -c "cd /tmp/usbguard-notifier && ./autogen.sh && ./configure --prefix=${TARGET_USER_HOME}/.local && make && make install SYSTEMD_UNIT_DIR=${TARGET_USER_HOME}/.config/systemd/user/" || echo "ATTENZIONE: build di usbguard-notifier fallita, controllare a mano dopo il primo avvio." >&2
      rm -rf /tmp/usbguard-notifier

      # NON usiamo "systemctl --user enable" qui: "dbus-run-session --
      # systemctl --user enable" dentro il chroot dell'autoinstall crea sì
      # un bus D-Bus di sessione, ma non un vero manager "systemd --user"
      # funzionante come quello di una sessione di login reale — l'enable
      # fallisce silenziosamente (l'unità resta "disabled") mentre il
      # comando esce comunque con successo, quindi il nostro precedente
      # "|| echo ATTENZIONE" non si accorgeva di nulla. Errore reale
      # riscontrato: al primo login il servizio risultava "loaded" (il
      # file .service era stato installato correttamente da
      # "make install") ma "disabled", e quindi mai avviato.
      # "systemctl --user enable" altro non fa che creare un symlink verso
      # l'unità dentro la directory ".wants" del target indicato da
      # "WantedBy=" nella sezione [Install] dell'unità stessa
      # (usbguard-notifier.service ha "WantedBy=default.target",
      # verificato leggendo usbguard-notifier.service.in nel repository
      # sorgente) — lo creiamo quindi direttamente, senza bisogno di un
      # manager systemd --user realmente attivo.
      mkdir -p "${TARGET_USER_HOME}/.config/systemd/user/default.target.wants"
      ln -sf "${TARGET_USER_HOME}/.config/systemd/user/usbguard-notifier.service" \
          "${TARGET_USER_HOME}/.config/systemd/user/default.target.wants/usbguard-notifier.service"
      chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_USER_HOME}/.config/systemd"

      # Per default GNOME (org.gnome.desktop.privacy usb-protection-level =
      # 'lockscreen') il componente gsd-usb-protection di gnome-settings-daemon
      # inserisce dinamicamente in /etc/usbguard/rules.conf una regola jolly
      # "allow id *:* label GNOME_SETTINGS_DAEMON_RULE" ogni volta che lo
      # schermo è sbloccato, vanificando di fatto il blocco di usbguard tranne
      # quando il PC è bloccato (protezione pensata contro un attacco tipo
      # "evil maid", non per l'uso quotidiano a schermo sbloccato). Impostiamo
      # comunque 'always' come rete di sicurezza, ma la vera difesa è il
      # mascheramento del servizio più sotto: con quello attivo il valore di
      # questa chiave non viene più letto da nessuno, perché il codice che la
      # legge (e che inserirebbe di nuovo la regola jolly se la si spegne con
      # usb-protection=false a plugin ancora vivo) non gira più.
      su - "${TARGET_USER}" -c 'dbus-run-session -- gsettings set org.gnome.desktop.privacy usb-protection-level always'

      # gsd-usb-protection mostra anche una sua notifica nativa ("Protezione
      # USB" / "Dispositivo USB bloccato") ad ogni device bloccato, in
      # sovrapposizione a quella del nostro usbguard-notifier — confermato
      # analizzando il sorgente di gnome-settings-daemon
      # (plugins/usb-protection/gsd-usb-protection-manager.c: show_notification
      # con urgenza CRITICAL, chiamata incondizionatamente in
      # usbguard_in_always_level). Non esiste una chiave gsettings per
      # disattivare solo la notifica lasciando attivo l'enforcement: il
      # plugin gira come servizio systemd utente D-Bus-attivato a sé stante
      # (org.gnome.SettingsDaemon.UsbProtection.service, vedi
      # plugins/meson.build upstream), separato dagli altri plugin di
      # gnome-settings-daemon (power, media-keys, ecc. restano intatti) e
      # separato dal demone usbguard di sistema (che continua a bloccare i
      # device sconosciuti per conto suo, via ImplicitPolicyTarget=block).
      # Lo mascheriamo creando direttamente il symlink verso /dev/null (in
      # questo chroot offline non c'è un'istanza reale di systemd --user su
      # cui girare "systemctl --user mask"), così l'unica notifica USB che
      # l'utente vede è quella del suo notificatore.
      #
      # Farlo FIN DALL'INSTALLAZIONE (invece che mascherarlo a posteriori su
      # un sistema già in uso) evita anche un secondo problema scoperto in
      # test: se gsd-usb-protection arriva a girare anche solo una volta con
      # usb-protection-level=always, imposta via IPC il parametro RUNTIME
      # del demone usbguard "InsertedDevicePolicy=block" (bloccare sempre,
      # ignorando le regole esistenti), invece del default di pacchetto
      # "apply-policy" (autorizza automaticamente se una regola combacia,
      # blocca solo gli sconosciuti). Quel parametro è tenuto in memoria dal
      # demone e resta "incastrato" a "block" finché usbguard.service non
      # viene riavviato — sintomo: anche un device con una regola "allow"
      # permanente viene ributtato lì ogni volta e richiede sempre una
      # nuova autorizzazione manuale dal notificatore, invece di essere
      # riconosciuto in automatico. Mascherando gsd-usb-protection PRIMA
      # che possa mai partire, questo scenario non si presenta su
      # un'installazione pulita: il demone usbguard resta sempre su
      # "apply-policy" e le regole permanenti scritte dal notificatore
      # (usbguard-notifier) funzionano correttamente fin dal primo utilizzo.
      mkdir -p "${TARGET_USER_HOME}/.config/systemd/user"
      ln -sf /dev/null "${TARGET_USER_HOME}/.config/systemd/user/org.gnome.SettingsDaemon.UsbProtection.service"
      chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_USER_HOME}/.config/systemd/user"

      # Howdy (boltgolt/howdy): sblocco/autenticazione via riconoscimento
      # facciale (PAM), per login/lock screen/sudo/su. Compilato da SORGENTE
      # invece che dalla PPA ufficiale (ppa:boltgolt/howdy): al momento in
      # cui questa ricetta è stata scritta la PPA non ha ancora una build
      # per 26.04 (issue upstream #1097, aperta da marzo 2026, senza
      # risposta del maintainer) — un utente ha riportato successo con una
      # PPA di terzi non ufficiale ("panda jims"), scartata qui per non
      # dipendere da un repository non verificabile in un chroot offline.
      # ATTENZIONE: la compilazione di dlib è lunga (l'upstream stesso
      # avverte "can hang on 100% for over a minute") — questo passo
      # allunga sensibilmente il tempo totale dell'autoinstall.
      apt-get install -y \
          python3 python3-pip python3-setuptools python3-wheel \
          cmake make build-essential meson ninja-build git \
          libpam0g-dev libinih-dev libevdev-dev python3-opencv \
          python3-dev libopencv-dev

      # BUG REALE trovato testando l'enrollment su hardware/VM ("sudo howdy
      # add" falliva con "No module named 'dlib'"): la build meson/ninja di
      # Howdy compila ed installa SOLO il codice di Howdy stesso —
      # verificato leggendo i meson.build upstream (root, howdy/,
      # howdy/src/): nessuno di questi installa il modulo Python "dlib" che
      # howdy/src/compare.py importa direttamente ("import dlib"). Non
      # esiste nemmeno un pacchetto apt "python3-dlib" su Ubuntu (solo
      # "libdlib-dev"/"libdlib19.1t64", la libreria C++, non i binding
      # Python) — va installato via pip, ed è proprio QUESTA la build lunga
      # di cui avverte il README upstream ("can hang on 100% for over a
      # minute"), non la compilazione meson/ninja più sotto.
      pip3 install --break-system-packages dlib

      git clone --depth=1 https://github.com/boltgolt/howdy.git /tmp/howdy
      cd /tmp/howdy
      # -Dconfig_dir esplicito: il default di meson.build è
      # "<prefix>/<sysconfdir>/howdy" e sysconfdir NON diventa /etc solo
      # perché prefix=/usr (bisognerebbe passare anche --sysconfdir=/etc a
      # parte, una nota gotcha di meson/GNU) — più sicuro fissarlo diretto.
      # -Dpython_path=/usr/bin/python3: il default upstream è
      # "/usr/bin/python", che su Ubuntu (Python 2 rimosso da anni) non
      # esiste affatto.
      # -Dinstall_pam_config=true: di default false, è quello che installa
      # il frammento /usr/share/pam-configs/howdy che pam-auth-update (il
      # meccanismo standard Debian/Ubuntu per registrare moduli PAM) sa
      # leggere — senza, "pam-auth-update --enable howdy" sotto non
      # troverebbe nulla da abilitare.
      meson setup build --prefix=/usr \
          -Dconfig_dir=/etc/howdy \
          -Dpython_path=/usr/bin/python3 \
          -Dinstall_pam_config=true
      meson compile -C build
      meson install -C build
      cd /
      rm -rf /tmp/howdy

      # Bug reale, ancora aperto upstream (issue #1104, nessuna risposta del
      # maintainer al momento in cui questa ricetta è stata scritta): su
      # Ubuntu 26.04/GNOME 50 il modulo PAM di Howdy manda in stallo (poi
      # in un dialog non più chiudibile) la richiesta di sblocco di
      # Impostazioni -> Utenti, perché quella finestra passa per il
      # servizio PAM "polkit-1", che eredita comunque il modulo Howdy
      # tramite l'inclusione di common-auth fatta da pam-auth-update. Fix
      # (tecnica standard PAM, non un'invenzione: vedi man pam_succeed_if,
      # sezione ESEMPI, che mostra esattamente questo pattern "salta il
      # modulo successivo per un dato service"): prima di abilitare il
      # profilo, inseriamo nel frammento stesso una riga pam_succeed_if.so
      # che, quando il service è "polkit-1", salta la riga di Howdy subito
      # dopo (success=1 la scavalca) — login, lock screen e sudo restano
      # protetti dal riconoscimento facciale come da progetto, solo
      # Impostazioni -> Utenti passa direttamente ai metodi successivi
      # (password) senza mai invocare Howdy. NON verificabile in questo
      # chroot offline (nessun vero polkit/gnome-control-center in
      # esecuzione): da confermare sull'hardware di Antonio prima di
      # fidarsene per la demo.
      sed -i \
          '/pam_howdy\.so/i\    [success=1 default=ignore]    pam_succeed_if.so quiet service = polkit-1' \
          /usr/share/pam-configs/howdy
      # A questo punto "@pamdir@" è già stato sostituito da meson con il
      # path reale (join_paths(prefix, libdir, 'security')): il sed sopra
      # cerca quindi la riga letterale con "pam_howdy.so", non il
      # placeholder — verificato leggendo il contenuto del frammento subito
      # dopo l'installazione.
      DEBIAN_FRONTEND=noninteractive pam-auth-update --enable howdy

      # L'enrollment del volto ("howdy add") richiede una webcam reale e
      # un'interazione visibile davanti alla persona: impossibile farlo qui
      # nel chroot offline. Stesso schema già usato per "wsf enable" più
      # sotto: una voce autostart che apre un terminale reale al primo
      # login e si autorimuove subito dopo, invece di provare a farlo
      # "silenziosamente" in un contesto D-Bus/sessione finti.
      cat > /usr/local/bin/ubuntu-ultimate-howdy-add.sh <<'HOWDYADDEOF'
      #!/bin/bash
      set -e
      echo "Ubuntu Ultimate: registrazione del volto per Howdy (sblocco facciale)."
      echo "Guarda la webcam quando richiesto. Premi Ctrl+C per saltare (potrai rieseguire 'sudo howdy add' più tardi da un terminale)."
      echo
      sudo howdy add || echo "Registrazione saltata o fallita: puoi rieseguire 'sudo howdy add' in qualunque momento."
      echo
      echo "Premi INVIO per chiudere..."
      read -r _
      rm -f "${HOME}/.config/autostart/ubuntu-ultimate-howdy-add.desktop"
      HOWDYADDEOF
      chmod +x /usr/local/bin/ubuntu-ultimate-howdy-add.sh

      mkdir -p "${TARGET_USER_HOME}/.config/autostart"
      cat > "${TARGET_USER_HOME}/.config/autostart/ubuntu-ultimate-howdy-add.desktop" <<'HOWDYDESKTOPEOF'
      [Desktop Entry]
      Type=Application
      Name=Ubuntu Ultimate - registra il volto per Howdy
      Exec=ghostty -e /usr/local/bin/ubuntu-ultimate-howdy-add.sh
      X-GNOME-Autostart-enabled=true
      NoDisplay=true
      HOWDYDESKTOPEOF
      chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_USER_HOME}/.config/autostart"

      # Promemoria di sicurezza (dallo stesso README upstream di Howdy, non
      # un'aggiunta nostra): "DO NOT USE HOWDY AS THE SOLE AUTHENTICATION
      # METHOD FOR YOUR SYSTEM" — pam-auth-update lo inserisce con
      # "[success=end default=ignore]", quindi in caso di volto non
      # riconosciuto/webcam assente si scende comunque al metodo successivo
      # (password), mai un blocco totale. La password resta sempre valida.

      # Podman (rootless) + wrapper CLI Docker + "docker compose" reale (v2),
      # SENZA installare il vero Docker Engine.
      #
      # podman-docker fornisce /usr/bin/docker come semplice wrapper
      # ("exec podman \"$@\""): ogni comando docker diventa un comando
      # podman. Va installato PRIMA di docker-compose-v2, altrimenti
      # succede questo (verificato): docker-compose-v2 "Recommends:
      # docker.io" (il vero Docker Engine, non lo vogliamo), e siccome
      # podman-docker "Conflicts: docker.io", se si lasciano installare i
      # recommends apt risolve il conflitto RIMUOVENDO podman-docker per
      # fare spazio al vero docker.io — silenziosamente, senza errori.
      # Fix: installare docker-compose-v2 con --no-install-recommends.
      #
      # docker-compose-v2 installa SOLO il plugin CLI
      # (/usr/libexec/docker/cli-plugins/docker-compose), non un binario
      # standalone "docker-compose": va invocato come "docker compose ..."
      # (o "podman compose ...", identico dato che docker=podman qui).
      # podman ha un comando nativo "compose" che fa da wrapper verso un
      # provider esterno (docker-compose o podman-compose, cerca in PATH
      # e nelle directory dei plugin CLI Docker) e configura da solo
      # l'ambiente per farlo parlare con il socket locale di podman —
      # verificato che trova ed esegue correttamente il plugin installato
      # da docker-compose-v2 senza bisogno di configurazione aggiuntiva.
      apt-get install -y podman podman-docker
      apt-get install -y --no-install-recommends docker-compose-v2

      # Il wrapper /usr/bin/docker di podman-docker stampa "Emulate Docker
      # CLI using podman..." su stderr ad ogni invocazione, a meno che non
      # esista /etc/containers/nodocker — è la sua stessa condizione
      # esplicita per zittirlo (visto nello script del wrapper), non un
      # hack nostro.
      mkdir -p /etc/containers
      touch /etc/containers/nodocker

      # Il pacchetto Ubuntu di podman spedisce /etc/containers/registries.conf
      # con "unqualified-search-registries" commentato (nessun registry di
      # default): un nome corto senza registry esplicito, tipo "docker pull
      # mermaid-js/mermaid-live-editor", fallisce con "short-name ... did
      # not resolve to an alias and no unqualified-search registries are
      # defined" a meno che non combaci con uno degli alias già pronti in
      # /etc/containers/registries.conf.d/shortnames.conf (che copre solo
      # immagini "note", tipo ubuntu/alpine/nginx). Un file di drop-in in
      # registries.conf.d (si somma al file principale, non lo sostituisce;
      # in ordine alfabetico) che imposta docker.io replica il comportamento
      # di default di Docker stesso, senza toccare il file principale del
      # pacchetto (che verrebbe sovrascritto ad un aggiornamento).
      mkdir -p /etc/containers/registries.conf.d
      cat > /etc/containers/registries.conf.d/10-unqualified-search.conf <<'REGISTRIESEOF'
      unqualified-search-registries = ["docker.io"]
      REGISTRIESEOF

      # Il comando "docker compose"/"podman compose" parla con
      # l'implementazione Docker-Engine-API di podman via socket Unix. In
      # modalità rootless (l'utente normale, non root) serve il socket
      # utente di podman, offerto dall'unit systemd utente "podman.socket"
      # (di serie nel pacchetto podman, /usr/lib/systemd/user/podman.socket).
      # Come per usbguard-notifier più sopra, lo abilitiamo creando
      # direttamente il symlink nella cartella "wants" (in questo chroot
      # offline non c'è un'istanza reale di systemd --user su cui usare
      # "systemctl --user enable"): partirà da solo, attivato dal socket,
      # al primo login reale — non serve "--now" né avviarlo ora.
      mkdir -p "${TARGET_USER_HOME}/.config/systemd/user/sockets.target.wants"
      ln -sf /usr/lib/systemd/user/podman.socket "${TARGET_USER_HOME}/.config/systemd/user/sockets.target.wants/podman.socket"
      chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_USER_HOME}/.config/systemd/user"

      su - "${TARGET_USER}" -c 'dbus-run-session -- gsettings set org.gnome.desktop.default-applications.terminal exec ghostty'
      su - "${TARGET_USER}" -c 'dbus-run-session -- gsettings set org.gnome.desktop.default-applications.terminal exec-arg -e'
      # org.gnome.desktop.default-applications.terminal è deprecato in GNOME
      # 49/50 ("DEPRECATED: This key is deprecated and ignored. The default
      # terminal is handled in GIO."): lo lasciamo per compatibilità con
      # eventuali app più vecchie, ma il percorso dconf che GIO legge
      # davvero ora è org/gnome/desktop/applications/terminal (confermato
      # da un test in VM: compare da solo con exec=ghostty già corretto,
      # dedotto da GIO leggendo l'alternativa x-terminal-emulator che
      # abbiamo impostato sopra) — lo scriviamo comunque esplicitamente,
      # senza affidarci al solo rilevamento automatico.
      su - "${TARGET_USER}" -c "dbus-run-session -- dconf write /org/gnome/desktop/applications/terminal/exec \"'ghostty'\""
      su - "${TARGET_USER}" -c "dbus-run-session -- dconf write /org/gnome/desktop/applications/terminal/exec-arg \"'-e'\""
      su - "${TARGET_USER}" -c 'dbus-run-session -- xdg-settings set default-web-browser brave-browser.desktop' || true

      # Touchpad: click a due/tre dita per il tasto destro/centrale invece
      # dell'area predefinita in basso a destra (più naturale sui touchpad
      # moderni), e tap-to-click esplicitamente attivo (di solito è già il
      # default, ma lo forziamo per non dipendere da quello che GNOME
      # decide caso per caso in base al modello di touchpad rilevato).
      su - "${TARGET_USER}" -c 'dbus-run-session -- gsettings set org.gnome.desktop.peripherals.touchpad click-method "fingers"'
      su - "${TARGET_USER}" -c 'dbus-run-session -- gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true'

      # Wayland Scroll Factor (wsf): GNOME su Wayland non espone NESSUNA
      # impostazione, né in Impostazioni né come chiave gsettings/dconf, per
      # regolare la velocità dello scroll a due dita sul touchpad (confermato:
      # a differenza del vecchio stack X11, dove bastava xinput, qui manca
      # completamente — è una lacuna nota di GNOME/Wayland, non un'omissione
      # di questa ricetta). wsf (github.com/daniel-g-carrasco/wayland-scroll-
      # factor) è il tool di terze parti più maturo per colmarla: per-utente,
      # reversibile, non tocca /etc/ld.so.preload — ma è distribuito solo
      # come pacchetto .deb su GitHub Releases, in nessun repository apt
      # ufficiale, quindi il download può fallire (rete, release rinominata):
      # in quel caso continuiamo l'installazione comunque, senza bloccarla
      # per un tool accessorio.
      WSF_VERSION="0.3.5"
      WSF_DEB="wayland-scroll-factor_${WSF_VERSION}-1_amd64.deb"
      if curl -fsSL -o "/tmp/${WSF_DEB}" \
          "https://github.com/daniel-g-carrasco/wayland-scroll-factor/releases/download/v${WSF_VERSION}/${WSF_DEB}"; then
          apt-get install -y "/tmp/${WSF_DEB}"
          rm -f "/tmp/${WSF_DEB}"

          # Configurazione utente: cambiamo solo lo scroll verticale rispetto
          # al default del tool (0.35 -> 0.20, più lento/prevedibile);
          # orizzontale e pinch restano ai valori di default. Li scriviamo
          # comunque per esteso perché il formato del file non è documentato
          # a sufficienza da sapere se wsf tolleri chiavi mancanti.
          mkdir -p "${TARGET_USER_HOME}/.config/wayland-scroll-factor"
          cat > "${TARGET_USER_HOME}/.config/wayland-scroll-factor/config" <<'WSFCONFIGEOF'
      scroll_vertical_factor=0.20
      scroll_horizontal_factor=0.35
      pinch_zoom_factor=1.00
      pinch_rotate_factor=1.00
      WSFCONFIGEOF
          chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_USER_HOME}/.config/wayland-scroll-factor"

          # "wsf enable" attiva il preload dentro gnome-shell e, per
          # documentazione del progetto, richiede un logout/login per avere
          # effetto. Non lo richiamiamo qui nel chroot con dbus-run-session
          # come i gsettings sopra: lì basta un bus D-Bus finto perché dconf
          # abbia dove scrivere, ma "enable" agisce sull'attivazione reale
          # dentro gnome-shell e non è documentato se funzioni senza una
          # sessione grafica Wayland vera. Più sicuro: lo lanciamo al primo
          # login reale con una voce autostart che si autorimuove subito
          # dopo, nelle stesse condizioni in cui lo lancerebbe a mano un
          # utente.
          cat > /usr/local/bin/ubuntu-ultimate-wsf-enable.sh <<'WSFENABLEEOF'
      #!/bin/bash
      set -e
      if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && command -v wsf >/dev/null 2>&1; then
          wsf enable || true
      fi
      rm -f "${HOME}/.config/autostart/wayland-scroll-factor-enable.desktop"
      WSFENABLEEOF
          chmod +x /usr/local/bin/ubuntu-ultimate-wsf-enable.sh

          mkdir -p "${TARGET_USER_HOME}/.config/autostart"
          cat > "${TARGET_USER_HOME}/.config/autostart/wayland-scroll-factor-enable.desktop" <<'WSFDESKTOPEOF'
      [Desktop Entry]
      Type=Application
      Name=Ubuntu Ultimate - attiva Wayland Scroll Factor
      Exec=/usr/local/bin/ubuntu-ultimate-wsf-enable.sh
      X-GNOME-Autostart-enabled=true
      NoDisplay=true
      WSFDESKTOPEOF
          chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_USER_HOME}/.config/autostart"
      else
          echo "ATTENZIONE: download di wayland-scroll-factor v${WSF_VERSION} fallito, scroll factor non configurato (vedi README)." >&2
      fi

      # zsh come shell di default + Oh My Zsh, per l'utente target.
      apt-get install -y zsh
      # zsh si registra da solo in /etc/shells durante l'installazione del
      # pacchetto (trigger dpkg via add-shell): controlliamo comunque, per
      # sicurezza, che ci sia davvero prima di impostarla come shell.
      ZSH_BIN="$(command -v zsh)"
      grep -qxF "${ZSH_BIN}" /etc/shells || echo "${ZSH_BIN}" >> /etc/shells
      # usermod invece di chsh: cambia direttamente /etc/passwd, senza
      # passare da PAM (chsh in un chroot offline, senza una sessione utente
      # reale, può comportarsi in modo imprevedibile o chiedere conferme).
      usermod --shell "${ZSH_BIN}" "${TARGET_USER}"

      # Installazione non interattiva di Oh My Zsh: --unattended equivale a
      # RUNZSH=no (non lanciare zsh a fine installazione, qui non avrebbe
      # senso comunque) + CHSH=no (la shell la impostiamo già noi sopra,
      # via usermod: chsh chiederebbe la password) + OVERWRITE_CONFIRMATION=no
      # (nessun .zshrc preesistente per un utente appena creato, ma per
      # sicurezza non deve comunque fermarsi a chiedere conferma).
      su - "${TARGET_USER}" -c 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended' \
          || echo "ATTENZIONE: installazione di Oh My Zsh fallita, controllare a mano dopo il primo avvio." >&2

      # Tema Pure per zsh: va clonato ED aggiunto a .zshrc DOPO l'installer
      # di Oh My Zsh sopra, perché quest'ultimo sovrascrive .zshrc da zero
      # (è il motivo per cui non è nel blocco Oh My Zsh: l'ordine conta).
      su - "${TARGET_USER}" -c 'mkdir -p "$HOME/.zsh" && git clone --depth=1 https://github.com/sindresorhus/pure.git "$HOME/.zsh/pure"' \
          || echo "ATTENZIONE: clone del tema Pure fallito, controllare a mano dopo il primo avvio." >&2
      su - "${TARGET_USER}" -c 'cat >> "$HOME/.zshrc" <<'"'"'PUREEOF'"'"'

      # Tema Pure (https://github.com/sindresorhus/pure)
      fpath+=($HOME/.zsh/pure)
      autoload -U promptinit; promptinit
      prompt pure
      PUREEOF'

      # Flatpak: supporto per installare app da Flathub, in aggiunta ai
      # .deb/snap già gestiti da questa ricetta. gnome-software-plugin-flatpak
      # fa comparire le app Flathub anche dentro "Software" (GNOME Software),
      # non solo da riga di comando ("flatpak install ...").
      apt-get install -y flatpak gnome-software-plugin-flatpak
      flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

      # Git: nome e email dell'utente, dalle risposte raccolte da
      # prepare-autoinstall.sh (lo stesso Nome e Cognome usato sopra per
      # identity.realname/GDM, per non chiederlo due volte).
      su - "${TARGET_USER}" -c 'git config --global user.name "__REALNAME__"'
      su - "${TARGET_USER}" -c 'git config --global user.email "__GIT_EMAIL__"'

      # eza (sostituto moderno di "ls", con icone): nessun pacchetto ufficiale
      # Ubuntu, si installa dal repository apt di terze parti di
      # eza-community — comandi presi da INSTALL.md del progetto upstream
      # (verificati prima di usarli, ancora corretti al momento di scrivere
      # questa ricetta).
      mkdir -p /etc/apt/keyrings
      wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc | gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
      echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" > /etc/apt/sources.list.d/gierens.list
      chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
      apt-get update
      apt-get install -y eza

      # Alias "ls" -> eza con le icone sempre attive, per la shell zsh
      # configurata sopra. Va aggiunto DOPO l'installer di Oh My Zsh e il
      # tema Pure (stesso motivo del tema Pure poco sopra: Oh My Zsh
      # sovrascrive .zshrc da zero se eseguito dopo).
      su - "${TARGET_USER}" -c 'cat >> "$HOME/.zshrc" <<'"'"'EZAALIASEOF'"'"'

      alias ls="eza --icons=always"
      EZAALIASEOF'

      # Ghostty: font Hack Nerd Font Mono (già installato più sopra in
      # questa stessa ricetta insieme agli altri font) e tema Catppuccin
      # Mocha (incluso nel binario di ghostty come tema builtin — dalla
      # versione 1.2.0 il nome è "Catppuccin Mocha" con spazio e maiuscole,
      # non più "catppuccin-mocha": verificato prima di scriverlo qui).
      # NOTA IMPORTANTE, per non confondersi in futuro: la chiave "language"
      # di ghostty NON è il layout di tastiera — è la lingua dei testi
      # dell'interfaccia grafica di ghostty stesso (richiede GTK e ghostty
      # 1.3+, disponibile su Ubuntu 26.04; verificato sulla documentazione
      # ufficiale). Il layout di tastiera vero e proprio è quello di sistema,
      # già impostato in cima a questo file con "keyboard: layout: it" —
      # ghostty lo eredita da lì automaticamente, non richiede nessuna
      # configurazione propria. Impostato "language = it" solo per coerenza
      # con locale/tastiera del resto della ricetta (entrambi italiani).
      mkdir -p "${TARGET_USER_HOME}/.config/ghostty"
      cat > "${TARGET_USER_HOME}/.config/ghostty/config" <<'GHOSTTYCONFIGEOF'
      font-family = Hack Nerd Font Mono
      font-size = 11
      language = it
      window-padding-x = 10
      theme = Catppuccin Mocha
      shell-integration-features = no-cursor
      cursor-style = underline
      bell-features = no-audio
      term = xterm-256color
      GHOSTTYCONFIGEOF
      chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_USER_HOME}/.config/ghostty"

      # Tailscale: script di installazione ufficiale (non interattivo di
      # suo, aggiunge da solo repo+chiave e installa il pacchetto, nessun
      # prompt). L'attivazione vera e propria ("tailscale up") NON può
      # avvenire qui: serve il demone tailscaled realmente in esecuzione
      # (rete, systemd attivo), che dentro questo chroot offline non c'è —
      # va fatta al primo avvio reale, vedi il servizio dedicato più sotto.
      curl -fsSL https://tailscale.com/install.sh | sh

      # Ordine della dash: Brave, File, Ghostty, Visualizzatore documenti.
      # I nomi esatti dei file .desktop possono cambiare da un pacchetto
      # all'altro (es. GNOME sta sostituendo Evince con Papers): per ogni
      # app proviamo una lista di candidati, in ordine di preferenza, e
      # usiamo il primo che risulta davvero installato in /usr/share/applications.
      add_favorite() {
          local candidate
          for candidate in "$@"; do
              if [[ -f "/usr/share/applications/${candidate}" ]]; then
                  echo "${candidate}"
                  return 0
              fi
          done
          echo "ATTENZIONE: nessuno dei candidati trovato per la dash: $*" >&2
          return 1
      }

      FAVORITES=()
      for spec in \
          "brave-browser.desktop" \
          "org.gnome.Nautilus.desktop nautilus.desktop" \
          "com.mitchellh.ghostty.desktop ghostty.desktop" \
          "org.gnome.Papers.desktop org.gnome.Evince.desktop evince.desktop"
      do
          if found="$(add_favorite ${spec})"; then
              FAVORITES+=("${found}")
          fi
      done

      FAVORITES_GVARIANT="["
      for f in "${FAVORITES[@]}"; do
          FAVORITES_GVARIANT+="'${f}', "
      done
      FAVORITES_GVARIANT="${FAVORITES_GVARIANT%, }]"

      su - "${TARGET_USER}" -c "dbus-run-session -- gsettings set org.gnome.shell favorite-apps \"${FAVORITES_GVARIANT}\""

      # Estensioni GNOME Shell: le 7 scelte esplicitamente da Antonio (delle
      # 8 originali abilitate su badrobot), più Tailscale for GNOME
      # (tailscale-gnome@diskmth.fr, https://github.com/Disk-MTH/Tailscale-Gnome,
      # su extensions.gnome.org come "Tailscale" — indicatore in Quick
      # Settings per il pacchetto Tailscale installato sopra; richiede solo
      # la CLI tailscale già presente e pkexec, già di serie su Ubuntu).
      # dash-to-dock@micxgx.gmail.com
      # NON la installiamo più: un test in VM ha mostrato che Ubuntu 26.04
      # porta già di suo 'ubuntu-dock@ubuntu.com' (un fork di dash-to-dock,
      # STESSO schema dconf org/gnome/shell/extensions/dash-to-dock) preso
      # automaticamente al primo avvio reale insieme ad altre due estensioni
      # di default ('ding@rastersoft.com' Desktop Icons NG e
      # 'tiling-assistant@ubuntu.com'), che GNOME Shell disabilita comunque
      # in automatico per conflitto con ubuntu-dock — installarla è quindi
      # solo un download sprecato che finisce disabilitato. Le NOSTRE
      # impostazioni per quello schema (sotto) restano comunque valide e si
      # applicano a ubuntu-dock, dato che condivide lo stesso schema.
      # Ognuna delle estensioni sotto viene scaricata da extensions.gnome.org
      # nella build compatibile con la versione di GNOME Shell effettiva;
      # se una non ha ancora una build per questa versione viene saltata
      # con un avviso, senza far fallire l'installazione (GNOME Shell 50 è
      # molto recente, non è garantito che tutte le estensioni di terze
      # parti l'abbiano già certificata).
      apt-get install -y python3

      GNOME_SHELL_VERSION="$(gnome-shell --version | grep -oP '[0-9]+\.[0-9]+' | head -1)"

      EXTENSION_UUIDS=(
          "display-color-correct@antoniopicone.it"
          "Rounded_Corners@lennart-k"
          "kiwi@kemma"
          "kiwimenu@kemma"
          "caffeine@patapon.info"
          "Vitals@CoreCoding.com"
          "auto-theme-switcher@amritashan.github.io"
          "tailscale-gnome@diskmth.fr"
      )

      INSTALLED_UUIDS=()
      for uuid in "${EXTENSION_UUIDS[@]}"; do
          info_json="$(curl -fsSL "https://extensions.gnome.org/extension-info/?uuid=${uuid}&shell_version=${GNOME_SHELL_VERSION}" || true)"
          download_path="$(printf '%s' "${info_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("download_url",""))' 2>/dev/null || true)"
          if [[ -z "${download_path}" ]]; then
              echo "ATTENZIONE: nessuna build di ${uuid} compatibile con GNOME Shell ${GNOME_SHELL_VERSION}, salto." >&2
              continue
          fi
          zip_path="/tmp/${uuid}.zip"
          if curl -fsSL "https://extensions.gnome.org${download_path}" -o "${zip_path}"; then
              chmod 644 "${zip_path}"
              if su - "${TARGET_USER}" -c "dbus-run-session -- gnome-extensions install --force '${zip_path}'"; then
                  INSTALLED_UUIDS+=("${uuid}")
              else
                  echo "ATTENZIONE: installazione fallita per ${uuid}, salto." >&2
              fi
          else
              echo "ATTENZIONE: download fallito per ${uuid}, salto." >&2
          fi
      done

      if [[ ${#INSTALLED_UUIDS[@]} -gt 0 ]]; then
          ENABLED_GVARIANT="["
          for u in "${INSTALLED_UUIDS[@]}"; do
              ENABLED_GVARIANT+="'${u}', "
          done
          ENABLED_GVARIANT="${ENABLED_GVARIANT%, }]"
          su - "${TARGET_USER}" -c "dbus-run-session -- gsettings set org.gnome.shell enabled-extensions \"${ENABLED_GVARIANT}\""
      fi

      # Impostazioni specifiche delle estensioni sopra, estratte dal dconf
      # dump di badrobot e poi allineate a un dump preso dalla VM di test
      # dopo un'installazione riuscita (solo le sezioni pertinenti: i dump
      # originali contenevano anche impostazioni di altre app e dati non
      # pertinenti). NB: alcuni valori sono legati all'hardware di badrobot
      # (nome del connettore monitor 'eDP-1', sensore ventola
      # 'sensor:_fan_asus_cpu_fan_'): su hardware diverso (VM inclusa)
      # quelle singole chiavi semplicemente non troveranno riscontro o
      # verranno sovrascritte dall'estensione stessa con il valore reale,
      # senza causare errori.
      su - "${TARGET_USER}" -c "dbus-run-session -- dconf load /" <<'DCONFEOF'
      [org/gnome/shell/extensions/auto-theme-switcher]
      dark-theme='adw-gtk3-dark'
      data-version=1
      light-theme='Adwaita'
      location-name='Napoli, Campania, Italia'
      manual-latitude='40.8522'
      manual-longitude='14.2681'
      manual-mode-active=true
      manual-mode-is-dark=false
      migration-notification-pending=''
      monitors='[{"id":"builtin","name":"Built-in Display","type":"brightnessctl","enabled":false,"initialized":true,"lightBrightness":48,"darkBrightness":48,"increaseDuration":7200,"decreaseDuration":7200,"lastSeen":1787815961872}]'
      monitors-last-detection=int64 1787815961873
      night-light-mode='sync-with-theme'
      show-notifications=false

      [org/gnome/shell/extensions/caffeine]
      cli-toggle=false
      indicator-position-max=2
      user-enabled=true

      [org/gnome/shell/extensions/dash-to-dock]
      apply-custom-theme=false
      background-color='rgb(24,12,12)'
      background-opacity=0.46000000000000002
      custom-background-color=true
      custom-theme-shrink=true
      dash-max-icon-size=48
      disable-overview-on-startup=true
      dock-fixed=false
      dock-position='BOTTOM'
      extend-height=false
      height-fraction=0.90000000000000002
      multi-monitor=true
      preferred-monitor=-2
      preferred-monitor-by-connector='eDP-1'
      running-indicator-style='DOT'
      show-apps-always-in-the-edge=true
      show-show-apps-button=false
      transparency-mode='FIXED'

      [org/gnome/shell/extensions/display-color-correct]
      blue-saturation=0.93000000000000005
      green-saturation=0.90000000000000002
      monitor-overrides='{"eDP-1":{"rSat":0.73,"gSat":0.9,"bSat":0.93},"DP-1":{"b":1,"rSat":1,"gSat":1,"bSat":1}}'
      per-monitor-enabled=true
      red-saturation=0.72999999999999998

      [org/gnome/shell/extensions/kiwi]
      add-username-to-quick-menu=false
      dock-blur=false
      enable-app-window-buttons=false
      enable-launchpad-app=false
      hide-activities-button=true
      keyboard-indicator=false
      lock-icon=false
      move-window-to-new-workspace=false
      overview-wallpaper-background=false
      panel-blur=false
      panel-color-inherit=true
      panel-hover-fullscreen=true
      panel-transparency=true
      panel-transparency-level=75
      show-window-controls=false
      show-window-title=false
      transparent-move=false

      [org/gnome/shell/extensions/ding]
      check-x11wayland=true
      show-home=false

      [org/gnome/shell/extensions/kiwimenu]
      activity-menu-visibility=false
      custom-menu-enabled=false
      icon=8

      [org/gnome/shell/extensions/lennart-k/rounded_corners]
      corner-radius=6

      [org/gnome/shell/extensions/vitals]
      alphabetize=false
      battery-colors=@as []
      fan-colors=['2500 0.8784313797950745 0.10588235408067703 0.1411764770746231 sensor:_fan_asus_cpu_fan_']
      fixed-widths=false
      gpu-colors=@as []
      hot-sensors=['__temperature_avg__']
      icon-style=1
      memory-colors=@as []
      network-public-ip-show-flag=false
      network-speed-unit=2
      processor-colors=@as []
      show-memory=true
      use-higher-precision=true
      DCONFEOF

      # --- Limine come bootloader SECONDARIO ---------------------------------
      # GRUB resta il bootloader installato da Subiquity/curtin e la voce EFI
      # di riferimento: se qualcosa qui sotto va storto, il sistema resta
      # avviabile scegliendo "ubuntu" dal menu del firmware. Aggiungiamo
      # Limine come voce EFI AGGIUNTIVA (messa per prima nell'ordine di
      # avvio), non lo installiamo al posto di GRUB.
      #
      # Nessun pacchetto apt "limine" su Ubuntu/Debian (verificato: nessun
      # risultato su packages.ubuntu.com/packages.debian.org) — si compila
      # dal sorgente ufficiale, solo la porta UEFI x86-64 (Secure Boot è
      # disattivo per questa installazione: nessun binario Limine firmato
      # da Microsoft/Canonical esiste, servirebbe un enrollment MOK
      # interattivo al riavvio, fuori scopo qui).
      #
      # LUKS2: Limine non ha bisogno di alcun supporto nativo alla
      # cifratura — lo sblocco lo fa sempre l'initramfs (hook cryptsetup di
      # initramfs-tools), esattamente come con GRUB. Il bootloader si
      # limita a caricare kernel/initrd dalla partizione /boot (non
      # cifrata, fuori dal container LUKS2 in questo layout) e passare la
      # cmdline giusta.
      #
      # Se questo blocco fallisce per qualunque motivo, l'installazione nel
      # suo complesso NON deve fallire: è tutto racchiuso in un secondo
      # script esterno a parte (ubuntu-ultimate-limine-setup.sh), col suo
      # "|| echo ATTENZIONE" sulla chiamata più sotto — GRUB resta comunque
      # installato e funzionante.
      #
      # NOTA sui percorsi: questo intero blocco (da "cat > /root/..." qui
      # sotto fino a "SETUPEOF" più in basso) fa parte dello script
      # ubuntu-ultimate-software-setup.sh, che viene eseguito con "curtin
      # in-target" — quindi gira GIÀ dentro il chroot del sistema di
      # destinazione. Qui dentro "/" è già quello che altrove chiamiamo
      # "/target": niente prefisso "/target/" nei percorsi, e niente una
      # seconda chiamata annidata a "curtin in-target" (non avrebbe senso:
      # "/target" non esiste in questo chroot, e curtin stesso potrebbe non
      # essere disponibile qui dentro).
      cat > /root/ubuntu-ultimate-limine-setup.sh <<'LIMINESETUPEOF'
      #!/bin/bash
      set -uo pipefail

      ESP_MOUNT="/boot/efi"
      BOOT_MOUNT="/boot"

      if ! mountpoint -q "${ESP_MOUNT}" || ! mountpoint -q "${BOOT_MOUNT}"; then
          echo "ATTENZIONE: layout ESP/${BOOT_MOUNT} inatteso, salto l'installazione di Limine." >&2
          exit 0
      fi

      ESP_DEV="$(findmnt -no SOURCE "${ESP_MOUNT}")"
      BOOT_DEV="$(findmnt -no SOURCE "${BOOT_MOUNT}")"
      BOOT_UUID="$(blkid -s UUID -o value "${BOOT_DEV}")"
      ESP_DISK="$(lsblk -no PKNAME "${ESP_DEV}")"
      ESP_PART_NUM="$(lsblk -no PARTN "${ESP_DEV}")"
      if [[ -z "${BOOT_UUID}" || -z "${ESP_DISK}" || -z "${ESP_PART_NUM}" ]]; then
          echo "ATTENZIONE: non riesco a determinare UUID/disco/partizione per Limine, salto." >&2
          exit 0
      fi
      ESP_DISK="/dev/${ESP_DISK}"

      CRYPTTAB_LINE="$(grep -vE '^\s*#|^\s*$' /etc/crypttab | head -n1)"
      if [[ -z "${CRYPTTAB_LINE}" ]]; then
          echo "ATTENZIONE: /etc/crypttab vuoto, salto l'installazione di Limine." >&2
          exit 0
      fi
      CRYPT_NAME="$(awk '{print $1}' <<< "${CRYPTTAB_LINE}")"
      CRYPT_SOURCE="$(awk '{print $2}' <<< "${CRYPTTAB_LINE}")"

      ROOT_SUBVOL="$(findmnt -no OPTIONS / | tr ',' '\n' | grep '^subvol=' | cut -d= -f2)"
      ROOT_SUBVOL="${ROOT_SUBVOL#/}"

      if [[ ! -e "${BOOT_MOUNT}/vmlinuz" || ! -e "${BOOT_MOUNT}/initrd.img" ]]; then
          echo "ATTENZIONE: vmlinuz/initrd.img non trovati in ${BOOT_MOUNT}, salto Limine." >&2
          exit 0
      fi
      KERNEL_FILE="$(basename "$(readlink -f "${BOOT_MOUNT}/vmlinuz")")"
      INITRD_FILE="$(basename "$(readlink -f "${BOOT_MOUNT}/initrd.img")")"

      # Limine compila il proprio binario target con clang+ld.lld di default
      # (configure.ac: senza TOOLCHAIN_FOR_TARGET esplicito, CC_FOR_TARGET=clang
      # e LD_FOR_TARGET=ld.lld a prescindere dal gcc dell'host) — servono clang+lld
      # veri, altrimenti "./configure" fallisce con "checking for clang... no /
      # configure: error: clang invalid, set CC_FOR_TARGET to a valid program".
      apt-get install -y build-essential git clang lld llvm nasm inotify-tools efibootmgr

      BUILD_DIR="$(mktemp -d)"
      git clone https://github.com/limine-bootloader/limine.git --branch=v12.x --depth=1 "${BUILD_DIR}/limine"
      (
          cd "${BUILD_DIR}/limine"
          ./bootstrap 2>/dev/null || true
          ./configure --enable-uefi-x86-64 --disable-bios --disable-bios-cd --disable-uefi-cd --disable-bios-pxe
          make
          make install
      )
      rm -rf "${BUILD_DIR}"

      LIMINE_EFI_DIR="${ESP_MOUNT}/EFI/limine"
      mkdir -p "${LIMINE_EFI_DIR}"
      LIMINE_EFI_SRC=""
      for candidate in /usr/local/share/limine/BOOTX64.EFI /usr/share/limine/BOOTX64.EFI; do
          [[ -f "${candidate}" ]] && LIMINE_EFI_SRC="${candidate}" && break
      done
      if [[ -z "${LIMINE_EFI_SRC}" ]]; then
          echo "ATTENZIONE: build di Limine fallita (BOOTX64.EFI non trovato), salto." >&2
          exit 0
      fi
      cp "${LIMINE_EFI_SRC}" "${LIMINE_EFI_DIR}/BOOTX64.EFI"

      # IMPORTANTE — scoperto testando su hardware reale (PANIC "linux:
      # Failed to open kernel with path"): Limine supporta SOLO FAT12/16/32
      # e ISO9660 (suo README ufficiale, "Supported filesystems") — NESSUN
      # driver ext2/ext3/ext4. Il nostro /boot è ext4: "uuid(...)" verso
      # quella partizione non funziona mai. Riformattare /boot in FAT32 non
      # va bene: FAT32 non supporta i symlink POSIX e il pacchetto del
      # kernel Ubuntu crea "/boot/vmlinuz" come symlink a ogni aggiornamento
      # (default dal 20.04) — romperebbe ogni "apt upgrade" futuro (bug
      # Ubuntu #1318951). Soluzione: /boot resta ext4, copiamo kernel/initrd
      # sull'ESP (che Limine legge) e puntiamo lì con "boot():/..." (la
      # partizione che contiene limine.conf stesso — CONFIG.md, "Paths").
      # Il mantenimento nel tempo è affidato a limine-kernel-sync più sotto.
      KERNELS_DIR="${ESP_MOUNT}/limine-kernels"
      mkdir -p "${KERNELS_DIR}"
      cp -f "${BOOT_MOUNT}/${KERNEL_FILE}" "${KERNELS_DIR}/${KERNEL_FILE}"
      cp -f "${BOOT_MOUNT}/${INITRD_FILE}" "${KERNELS_DIR}/${INITRD_FILE}"

      # "rd.luks.uuid=" (sintassi dracut) accanto a "cryptdevice=" (sintassi
      # initramfs-tools): innocuo finché si usa initramfs-tools, utile se in
      # futuro si passa a dracut per lo sblocco TPM2 (vedi
      # scripts/19-tpm2-autounlock.sh).
      CRYPT_UUID="${CRYPT_SOURCE#UUID=}"
      CMDLINE="root=/dev/mapper/${CRYPT_NAME} rootflags=subvol=${ROOT_SUBVOL} rootfstype=btrfs cryptdevice=${CRYPT_SOURCE}:${CRYPT_NAME} rd.luks.uuid=${CRYPT_UUID} rw quiet splash"
      cat > "${LIMINE_EFI_DIR}/limine.conf" <<CONFEOF
      timeout: 5
      interface_branding: Ubuntu Ultimate
      interface_branding_colour: E95420
      term_palette: 262626;E95420;3A9D5D;C7A317;4A90D9;9B6BC7;3A9D9D;C4C4C4
      term_palette_bright: 5C5C5C;FF6E3A;5BC787;E8C547;6BA9EA;B98CE0;5BC7C7;FFFFFF
      term_background: 00171717
      term_foreground: C4C4C4

      /Ubuntu Ultimate
          protocol: linux
          kernel_path: boot():/limine-kernels/${KERNEL_FILE}
          module_path: boot():/limine-kernels/${INITRD_FILE}
          kernel_cmdline: ${CMDLINE}

      #### LIMINE-SNAPSHOT-SYNC:BEGIN (generato automaticamente da limine-snapshot-sync, non modificare a mano)
      #### LIMINE-SNAPSHOT-SYNC:END
      CONFEOF

      # --- Hook di sincronizzazione: kernel/initrd sull'ESP sempre aggiornati
      cat > /usr/local/bin/limine-kernel-sync <<'KSYNCEOF'
      #!/usr/bin/env bash
      # Rigenera la copia su ESP di kernel/initrd correnti e le righe
      # kernel_path/module_path di limine.conf (tutte le entry, incluse le
      # eventuali voci snapshot: usano lo stesso kernel/initrd corrente).
      # Installato dall'autoinstall, agganciato a /etc/kernel/postinst.d e
      # postrm.d — non modificarlo a mano.
      set -euo pipefail

      ESP_MOUNT="/boot/efi"
      BOOT_MOUNT="/boot"
      LIMINE_CONF="${ESP_MOUNT}/EFI/limine/limine.conf"
      KERNELS_DIR="${ESP_MOUNT}/limine-kernels"

      [[ -f "${LIMINE_CONF}" ]] || exit 0
      [[ -e "${BOOT_MOUNT}/vmlinuz" && -e "${BOOT_MOUNT}/initrd.img" ]] || exit 0

      mkdir -p "${KERNELS_DIR}"

      KERNEL_FILE="$(basename "$(readlink -f "${BOOT_MOUNT}/vmlinuz")")"
      INITRD_FILE="$(basename "$(readlink -f "${BOOT_MOUNT}/initrd.img")")"

      cp -f "${BOOT_MOUNT}/${KERNEL_FILE}" "${KERNELS_DIR}/${KERNEL_FILE}"
      cp -f "${BOOT_MOUNT}/${INITRD_FILE}" "${KERNELS_DIR}/${INITRD_FILE}"

      for f in "${KERNELS_DIR}"/vmlinuz-* "${KERNELS_DIR}"/initrd.img-*; do
          [[ -e "${f}" ]] || continue
          base="$(basename "${f}")"
          [[ -e "${BOOT_MOUNT}/${base}" ]] || rm -f "${f}"
      done

      sed -i \
          -e "s#^\(\s*kernel_path:\s*\)boot():/limine-kernels/.*#\1boot():/limine-kernels/${KERNEL_FILE}#" \
          -e "s#^\(\s*module_path:\s*\)boot():/limine-kernels/.*#\1boot():/limine-kernels/${INITRD_FILE}#" \
          "${LIMINE_CONF}"
      KSYNCEOF
      chmod 755 /usr/local/bin/limine-kernel-sync

      cat > /etc/kernel/postinst.d/zz-limine-kernel-sync <<'HOOKEOF'
      #!/bin/sh
      /usr/local/bin/limine-kernel-sync || true
      HOOKEOF
      chmod 755 /etc/kernel/postinst.d/zz-limine-kernel-sync

      cat > /etc/kernel/postrm.d/zz-limine-kernel-sync <<'HOOKEOF'
      #!/bin/sh
      /usr/local/bin/limine-kernel-sync || true
      HOOKEOF
      chmod 755 /etc/kernel/postrm.d/zz-limine-kernel-sync

      EXISTING_LIMINE_BOOTNUM="$(efibootmgr -v | awk -F'[ *]+' '/Limine/ {sub(/^Boot/,"",$1); print $1; exit}')"
      if [[ -n "${EXISTING_LIMINE_BOOTNUM}" ]]; then
          efibootmgr --bootnum "${EXISTING_LIMINE_BOOTNUM}" --delete-bootnum >/dev/null
      fi
      efibootmgr --create --disk "${ESP_DISK}" --part "${ESP_PART_NUM}" \
          --loader '\EFI\limine\BOOTX64.EFI' --label "Limine" >/dev/null
      NEW_LIMINE_BOOTNUM="$(efibootmgr -v | awk -F'[ *]+' '/Limine/ {sub(/^Boot/,"",$1); print $1; exit}')"
      CURRENT_ORDER="$(efibootmgr | awk -F': ' '/^BootOrder/ {print $2}')"
      REST_ORDER="$(tr ',' '\n' <<< "${CURRENT_ORDER}" | grep -v "^${NEW_LIMINE_BOOTNUM}$" | paste -sd, -)"
      if [[ -n "${REST_ORDER}" ]]; then
          efibootmgr --bootorder "${NEW_LIMINE_BOOTNUM},${REST_ORDER}" >/dev/null
      else
          efibootmgr --bootorder "${NEW_LIMINE_BOOTNUM}" >/dev/null
      fi

      # --- limine-snapshot-sync: voci di boot per gli snapshot BTRFS/snapper --
      # NON è un porting del progetto "limine-snapper-sync" (Java/GraalVM,
      # dipendenze Arch-specifiche: portarlo davvero richiederebbe una
      # toolchain gradle+GraalVM e la riscrittura degli hook per
      # initramfs-tools/apt) — è una nostra reimplementazione leggera in
      # bash dello stesso risultato per l'utente, con lo stesso meccanismo
      # (demone + watch via inotify) già usato da grub-btrfs/grub-btrfsd in
      # questa stessa ricetta per GRUB.
      cat > /usr/local/bin/limine-snapshot-sync <<'SYNCEOF'
      #!/usr/bin/env bash
      set -euo pipefail
      LIMINE_CONF="/boot/efi/EFI/limine/limine.conf"
      BOOT_MOUNT="/boot"
      SNAPSHOTS_DIR="/.snapshots"
      [[ -f "${LIMINE_CONF}" ]] || exit 0
      grep -q '^#### LIMINE-SNAPSHOT-SYNC:BEGIN' "${LIMINE_CONF}" || exit 0
      command -v limine-kernel-sync >/dev/null 2>&1 && limine-kernel-sync || true
      CRYPTTAB_LINE="$(grep -vE '^\s*#|^\s*$' /etc/crypttab | head -n1)"
      CRYPT_NAME="$(awk '{print $1}' <<< "${CRYPTTAB_LINE}")"
      CRYPT_SOURCE="$(awk '{print $2}' <<< "${CRYPTTAB_LINE}")"
      KERNEL_FILE="$(basename "$(readlink -f "${BOOT_MOUNT}/vmlinuz")")"
      INITRD_FILE="$(basename "$(readlink -f "${BOOT_MOUNT}/initrd.img")")"
      BLOCK="$(mktemp)"
      trap 'rm -f "${BLOCK}"' EXIT
      NUM_SNAPSHOTS=0
      if [[ -d "${SNAPSHOTS_DIR}" ]]; then
          for n in $(find "${SNAPSHOTS_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E '^[0-9]+$' | sort -rn); do
              n_dir="${SNAPSHOTS_DIR}/${n}"
              [[ -d "${n_dir}/snapshot" ]] || continue
              if [[ "${NUM_SNAPSHOTS}" -eq 0 ]]; then
                  {
                      echo ""
                      echo "/+Snapshots"
                      echo "    comment: Avvia un'istantanea BTRFS/Snapper precedente della root."
                      echo ""
                  } >> "${BLOCK}"
              fi
              NUM_SNAPSHOTS=$((NUM_SNAPSHOTS + 1))
              desc=""
              if [[ -f "${n_dir}/info.xml" ]]; then
                  desc="$(sed -n 's/.*<description>\(.*\)<\/description>.*/\1/p' "${n_dir}/info.xml" | head -n1)"
              fi
              label="Snapshot #${n}"
              [[ -n "${desc}" ]] && label="Snapshot #${n} — ${desc}"
              {
                  echo "    //${label}"
                  echo "        protocol: linux"
                  echo "        kernel_path: boot():/limine-kernels/${KERNEL_FILE}"
                  echo "        module_path: boot():/limine-kernels/${INITRD_FILE}"
                  echo "        kernel_cmdline: root=/dev/mapper/${CRYPT_NAME} rootflags=subvol=@snapshots/${n}/snapshot rootfstype=btrfs cryptdevice=${CRYPT_SOURCE}:${CRYPT_NAME} rw"
                  echo ""
              } >> "${BLOCK}"
          done
      fi
      awk -v blockfile="${BLOCK}" '
          /^#### LIMINE-SNAPSHOT-SYNC:BEGIN/ { print; while ((getline line < blockfile) > 0) print line; skip=1; next }
          /^#### LIMINE-SNAPSHOT-SYNC:END/ { skip=0 }
          skip { next }
          { print }
      ' "${LIMINE_CONF}" > "${LIMINE_CONF}.new"
      mv "${LIMINE_CONF}.new" "${LIMINE_CONF}"
      SYNCEOF
      chmod 755 /usr/local/bin/limine-snapshot-sync

      cat > /usr/local/bin/limine-snapshot-sync-watch <<'WATCHEOF'
      #!/usr/bin/env bash
      set -euo pipefail
      /usr/local/bin/limine-snapshot-sync
      exec inotifywait -m -e create -e delete -e moved_to -e moved_from -r /.snapshots 2>/dev/null | \
      while read -r _; do
          /usr/local/bin/limine-snapshot-sync || true
      done
      WATCHEOF
      chmod 755 /usr/local/bin/limine-snapshot-sync-watch

      cat > /etc/systemd/system/limine-snapshot-sync.service <<'UNITEOF'
      [Unit]
      Description=Rigenera le voci snapshot di Limine da /.snapshots (equivalente locale di grub-btrfsd, per Limine)
      After=local-fs.target

      [Service]
      Type=simple
      ExecStart=/usr/local/bin/limine-snapshot-sync-watch
      Restart=on-failure

      [Install]
      WantedBy=multi-user.target
      UNITEOF
      systemctl enable limine-snapshot-sync.service
      LIMINESETUPEOF
      chmod +x /root/ubuntu-ultimate-limine-setup.sh

      # efibootmgr ha bisogno di /sys/firmware/efi/efivars montato. In
      # teoria il bind mount di "/sys" fatto da curtin per questo chroot
      # non è ricorsivo, quindi l'efivarfs annidato dell'host non
      # dovrebbe arrivare qui dentro — MA VERIFICATO IN VM che, a questo
      # punto della fase late-commands, efivarfs risulta GIÀ montato
      # (montato da Subiquity/curtin stesso durante una "curtin in-target"
      # precedente, es. update-grub più sopra, e rimasto attivo per tutta
      # la fase): un secondo "mount -t efivarfs" su un mountpoint già
      # occupato fallisce con "already mounted" e, con lo "set -eux" di
      # questo script, si porta dietro l'intera installazione. Idempotente:
      # monta solo se non è già montato, e smonta solo se l'abbiamo
      # montato noi (mai smontare un mount che non abbiamo creato — potrebbe
      # servire ad altri passaggi).
      EFIVARS_MOUNTED_BY_US=0
      if mountpoint -q /sys/firmware/efi/efivars; then
          EFIVARS_MOUNTED_BY_US=0
      else
          mkdir -p /sys/firmware/efi/efivars
          mount -t efivarfs efivarfs /sys/firmware/efi/efivars
          EFIVARS_MOUNTED_BY_US=1
      fi
      bash /root/ubuntu-ultimate-limine-setup.sh \
          || echo "ATTENZIONE: installazione di Limine fallita, il sistema resta avviabile con GRUB (vedi sopra per l'errore)." >&2
      if [[ "${EFIVARS_MOUNTED_BY_US}" -eq 1 ]]; then
          umount /sys/firmware/efi/efivars
      fi
      rm -f /root/ubuntu-ultimate-limine-setup.sh

      # Rigenera grub.cfg: serve perché grub-btrfs ha appena aggiunto
      # /etc/grub.d/41_snapshots-btrfs (nessuno snapshot esiste ancora a
      # questo punto, ma lo script dev'esserci già pronto per quando
      # snapper ne creerà il primo).
      update-grub
      SETUPEOF
      chmod +x /target/root/ubuntu-ultimate-software-setup.sh
      curtin in-target --target=/target -- /root/ubuntu-ultimate-software-setup.sh
      rm -f /target/root/ubuntu-ultimate-software-setup.sh

    # -----------------------------------------------------------------
    # Terzo blocco: rimozione Firefox via servizio systemd al PRIMO AVVIO
    # REALE (non in chroot). Si autodisabilita dopo essere girato una
    # volta, quindi non fa nulla ai riavvii successivi.
    - |
      set -eux

      cat > /target/etc/systemd/system/ubuntu-ultimate-firstboot.service <<'UNITEOF'
      [Unit]
      Description=Ubuntu Ultimate - rimozione Firefox al primo avvio
      After=snapd.service network-online.target
      Wants=snapd.service network-online.target
      ConditionPathExists=!/var/lib/ubuntu-ultimate/firstboot-done

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/ubuntu-ultimate-firstboot.sh
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
      UNITEOF

      cat > /target/usr/local/sbin/ubuntu-ultimate-firstboot.sh <<'SCRIPTEOF'
      #!/bin/bash
      set -eux

      snap wait system seed.loaded || true

      if snap list firefox >/dev/null 2>&1; then
          snap remove --purge firefox
      fi
      if dpkg -s firefox >/dev/null 2>&1; then
          apt-get purge -y firefox
      fi
      apt-mark hold firefox || true

      mkdir -p /var/lib/ubuntu-ultimate
      touch /var/lib/ubuntu-ultimate/firstboot-done
      systemctl disable ubuntu-ultimate-firstboot.service
      SCRIPTEOF
      chmod +x /target/usr/local/sbin/ubuntu-ultimate-firstboot.sh

      curtin in-target --target=/target -- systemctl enable ubuntu-ultimate-firstboot.service

      # Servizio SEPARATO (non lo stesso di Firefox: nome/scopo diversi,
      # un fallimento nell'uno non deve bloccare/confondersi con l'altro)
      # per attivare Tailscale al primo avvio reale, quando tailscaled è
      # davvero in esecuzione. Si autodisabilita dopo essere girato una
      # volta, comunque sia andata (successo o auth key mancante).
      cat > /target/etc/systemd/system/ubuntu-ultimate-tailscale-up.service <<'TSUNITEOF'
      [Unit]
      Description=Ubuntu Ultimate - attivazione Tailscale al primo avvio
      After=network-online.target tailscaled.service
      Wants=network-online.target
      Requires=tailscaled.service
      ConditionPathExists=!/var/lib/ubuntu-ultimate/tailscale-up-done

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/ubuntu-ultimate-tailscale-up.sh
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
      TSUNITEOF

      cat > /target/usr/local/sbin/ubuntu-ultimate-tailscale-up.sh <<'TSSCRIPTEOF'
      #!/bin/bash
      set -eux

      # Segnaposto sostituito da prepare-autoinstall.sh: se lasciato vuoto
      # (chiave non fornita, invio per saltare), il pacchetto resta
      # installato ma non attivato — nessun errore, solo un avviso.
      AUTH_KEY="__TAILSCALE_AUTHKEY__"

      if [[ -n "${AUTH_KEY}" ]]; then
          tailscale up --auth-key="${AUTH_KEY}" \
              || echo "ATTENZIONE: 'tailscale up' fallito, controllare a mano (sudo tailscale up, sudo tailscale status)." >&2
      else
          echo "Nessuna auth key Tailscale fornita in prepare-autoinstall.sh: pacchetto installato ma non attivato. Esegui 'sudo tailscale up' a mano quando vuoi collegarlo." >&2
      fi

      mkdir -p /var/lib/ubuntu-ultimate
      touch /var/lib/ubuntu-ultimate/tailscale-up-done
      systemctl disable ubuntu-ultimate-tailscale-up.service
      TSSCRIPTEOF
      chmod +x /target/usr/local/sbin/ubuntu-ultimate-tailscale-up.sh

      curtin in-target --target=/target -- systemctl enable ubuntu-ultimate-tailscale-up.service

  user-data:
    disable_root: true
