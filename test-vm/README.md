# Test VM — validare il layout disco prima dell'hardware reale

Questa cartella non fa parte della ricetta finale: è la nostra officina per
validare `disk-setup/autoinstall.yaml` dentro una VM KVM/QEMU locale, prima
di fidarcene su una macchina vera per la demo del 17 settembre.

## Flusso

```
1. ./00-enable-virtualization.sh        # una tantum sull'host di test
   (logout/login per rendere effettivi i gruppi kvm/libvirt)

2. ../disk-setup/prepare-autoinstall.sh # genera disk-setup/autoinstall.yaml

3. ./create-test-vm.sh                  # scarica l'ISO, crea la VM, avvia
                                          # l'installazione unattended

4. virt-viewer ubuntu-ultimate-test     # segui l'installazione a video;
                                          # al riavvio finale ti verrà
                                          # chiesta la passphrase LUKS2

5. ./verify-test-vm.sh ubuntu-ultimate-test <username>
                                          # controlla via SSH che il layout
                                          # (@ / @home / @var / @snapshots)
                                          # sia esattamente quello atteso
```

## Cosa fa ogni script

- **`00-enable-virtualization.sh`** — installa `qemu-kvm`, `libvirt`,
  `virt-manager`, `virtinst`, `virt-viewer`, il firmware `ovmf` (serve per l'avvio UEFI,
  visto che la ricetta usa una ESP/GPT) e `cloud-image-utils` (per
  `cloud-localds`, con cui costruiamo la ISO "seed" di autoinstall). Verifica
  anche che la CPU supporti la virtualizzazione hardware (VT-x/AMD-V).

- **`create-test-vm.sh`** — scarica (con verifica SHA256) l'ISO ufficiale
  `ubuntu-26.04.1-desktop-amd64.iso` dal mirror GARR (rete della ricerca
  italiana, molto più veloce di releases.ubuntu.com da qui), con `aria2c`
  a più connessioni se disponibile (lo installa da solo se manca) — puoi
  forzare un altro mirror con `ISO_MIRROR=https://... ./create-test-vm.sh`.
  Il checksum viene comunque verificato contro releases.ubuntu.com, la
  fonte ufficiale, indipendentemente da quale mirror hai usato per
  scaricare. Poi impacchetta `autoinstall.yaml` e
  `meta-data` in una piccola ISO NoCloud con `cloud-localds` (stesso
  meccanismo del metodo "USB" descritto in `disk-setup/README.md`, solo che
  qui è un secondo CD-ROM virtuale invece di una chiavetta), e lancia
  `virt-install` con firmware UEFI, disco da 30GB e le due ISO montate. La
  VM riparte da sola a fine installazione.

- **`verify-test-vm.sh`** — una volta che la VM è tornata su e hai sbloccato
  LUKS dalla console, si collega via SSH (l'autoinstall abilita
  `ssh.install-server`) e stampa `findmnt`, `btrfs subvolume list`,
  `/etc/crypttab`, `lsblk -f` e la cmdline del kernel, così puoi confrontarli
  a colpo d'occhio con quanto atteso.

## Note

- La passphrase LUKS va sempre digitata a mano dalla console grafica
  (`virt-viewer`) o testuale (`virsh console`): non è mai passata via SSH,
  di proposito.
- Puoi rilanciare `create-test-vm.sh` quante volte vuoi: cancella da sola
  un'eventuale VM di prova precedente con lo stesso nome prima di ricrearla.
- L'ISO di Ubuntu (~6GB) viene scaricata una sola volta in `isos/` e
  riutilizzata nelle run successive.
- Se vuoi ripartire da zero anche con l'ISO seed: basta rilanciare
  `create-test-vm.sh`, viene sempre ricostruita da `autoinstall.yaml`
  aggiornato.

## Problema noto: onlyoffice-desktopeditors blocca "apt upgrade"

Su badrobot `onlyoffice-desktopeditors` risulta installato con dipendenze
non soddisfatte (`libxss1`, `libxkbcommon-x11-0`, `fonts-dejavu`,
`fonts-crosextra-carlito` mancanti) — probabilmente un .deb installato a
mano da una versione precedente di Ubuntu, con nomi di pacchetto non più
allineati a quelli disponibili in 26.04. Per questo `00-enable-virtualization.sh`
**non** fa più un `apt upgrade` generale: usa solo `apt install` con
l'elenco esplicito di pacchetti, che non tocca onlyoffice.

Se vuoi comunque sistemarlo (non è richiesto per la ricetta), prima di
lanciare `apt --fix-broken install` conviene capire cosa succederebbe:

```bash
apt-cache policy libxss1 libxkbcommon-x11-0 fonts-dejavu fonts-crosextra-carlito
sudo apt install -y libxss1 libxkbcommon-x11-0 fonts-dejavu fonts-crosextra-carlito
```

Se questi pacchetti risultano disponibili nei repository ma semplicemente
non installati, questo basta. Se invece `apt-cache policy` non trova
candidati per uno di essi, vuol dire che è stato rinominato/sostituito in
26.04 e va cercato il pacchetto sostitutivo prima di toccare altro — in tal
caso fermati e chiedi, non lanciare `apt --fix-broken install` alla cieca:
potrebbe proporre di *rimuovere* onlyoffice-desktopeditors per risolvere.
