#!/usr/bin/env bash
#
# 21-icloud-nautilus-status.sh
#
# RISCRITTO in questa sessione: prima faceva solo l'estensione Nautilus di
# stato (emblema + etichetta segnalibro + placeholder anti-"cartella vuota").
# Ora fa anche il lavoro più grosso: patcha icloud-linux (driver.py) per
# passare da un crawl ricorsivo completo all'avvio a un'elencazione ON-DEMAND
# per cartella, innescata dai veri readdir()/getattr() del filesystem FUSE —
# lo stesso comportamento di Finder/Files.app su macOS con iCloud Drive:
#   - `ls ~/iCloud`            -> elenca SOLO i figli diretti della radice
#   - `cd ~/iCloud/documenti`  -> elenca SOLO i figli diretti di quella cartella
#   - aprire un file           -> lo scarica solo in quel momento (già così
#                                 prima, con warmup_mode: lazy)
#
# Con questo cambiamento la lunga attesa "cartella vuota per minuti/ore"
# prima del mount sparisce nella pratica: il mount avviene quasi subito,
# perché non c'è più nessun crawl ricorsivo bloccante prima di fs.main().
# Per questo l'estensione Nautilus (di cui questo script si occupava già)
# è stata semplificata di conseguenza: non serve più il meccanismo pesante
# di placeholder pre-mount, basta riflettere in tempo reale quale cartella
# sta venendo elencata e quale file sta venendo scaricato.
#
# Idempotente, rieseguibile: confronta (checksum) driver.py già patchato,
# ora EMBEDDATO in questo stesso script (prima era un file a parte,
# icloud-linux-driver-patched/driver.py, consolidato qui su richiesta di
# Antonio per non dover portare in giro due file separati), con quello
# presente su disco e lo installa solo se diverso, con backup della
# versione precedente e verifica di compilazione post-copia (ripristina il
# backup se qualcosa non compila). Stessa logica per la chiave di config e
# per l'estensione Nautilus.
#
# NON VERIFICATO su hardware reale in questa sessione (nessun gnome-shell,
# Nautilus, mutter, né un vero account iCloud disponibili in questo sandbox):
# la logica di list_directory() è stata testata con un DriveService finto
# (vedi nota "TEST ESEGUITO" più sotto), ma l'integrazione end-to-end con
# Nautilus/GNOME va confermata su hardware.
#
# AGGIUNTO in questa sessione: lo script ora installa anche icloud-linux
# stesso (dipendenze apt, clone del repo, `icloudctl quickstart`) se non è
# già presente, invece di limitarsi ad avvisare e saltare il patching.
# L'estensione Nautilus viene installata solo dopo aver confermato che
# icloud.service è effettivamente attivo (altrimenti lo script esce con
# errore), così non finisce per estendere Nautilus per un mount che non c'è.
#
# DUE BUG REALI trovati verificando end-to-end su hardware vero (Antonio
# lamentava "~/iCloud resta vuota"):
#   1. list_directory() (elencazione on-demand) riusava _materialize_
#      remote_entry()/_refresh_clean_entry() così com'erano scritte per il
#      crawl completo storico, che avviano SEMPRE uno scaricamento in
#      background per ogni file non ancora scaricato — quindi bastava
#      aprire una cartella per far scaricare il contenuto di TUTTI i file
#      al suo interno, non solo elencarli. Fix: nuovo parametro
#      `schedule_download` (default True per compatibilità col percorso di
#      crawl_mode: full), passato a False dalle due chiamate dentro
#      list_directory().
#   2. Causa MOLTO più impattante, specifica dell'ambiente desktop reale
#      (non riproducibile nel sandbox senza GNOME): org.freedesktop.
#      Tracker3.Miner.Files ("localsearch"), l'indicizzatore di ricerca di
#      GNOME, indicizza $HOME in modo ricorsivo per default — e ~/iCloud ci
#      sta sotto. L'indicizzatore cammina da solo l'intero albero e apre il
#      contenuto di ogni file per indicizzarlo, esattamente come un utente
#      che apra ogni cartella e ogni file: per il filesystem FUSE i due
#      accessi sono indistinguibili. Risultato osservato: pochi secondi
#      dopo il mount, l'intero iCloud Drive (15000+ elementi) veniva
#      scaricato in background, vanificando l'elencazione on-demand. Fix:
#      lo script crea un file marker vuoto ".trackerignore" nella cartella
#      "mirror" che fa da backend locale al mount (rispettato di default da
#      Tracker/localsearch tramite ignored-directories-with-content) e
#      riavvia l'indicizzatore se già in esecuzione.

set -euo pipefail

ICLOUD_LINUX_DIR="${ICLOUD_LINUX_DIR:-$HOME/icloud-linux}"
DRIVER_PY="$ICLOUD_LINUX_DIR/driver.py"
CONFIG_YAML="$HOME/.config/icloud-linux/config.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_normal_user

# driver.py già patchato (elencazione on-demand), embeddato qui sotto invece
# di essere un file a parte accanto allo script (vedi header). Scritto in un
# file temporaneo così il resto della logica sotto (confronto checksum,
# backup, verifica py_compile) resta identica a prima.
PATCHED_DRIVER_PY="$(mktemp)"
trap 'rm -f "${PATCHED_DRIVER_PY}"' EXIT
cat > "${PATCHED_DRIVER_PY}" <<'DRIVERPYEOF'
#!/usr/bin/env python3

import atexit
import datetime
import errno
import hashlib
import json
import logging
import os
import signal
import shutil
import sqlite3
import stat
import sys
import tempfile
import threading
import time
from contextlib import closing
from collections import deque
from concurrent.futures import ThreadPoolExecutor

import fuse
import yaml
from fuse import Fuse
from pyicloud import PyiCloudService
from pyicloud.exceptions import (
    PyiCloud2FARequiredException,
    PyiCloud2SARequiredException,
    PyiCloudAPIResponseException,
    PyiCloudAuthRequiredException,
    PyiCloudFailedLoginException,
)
from pyicloud.services.drive import DriveNode


if not hasattr(fuse, "__version__"):
    fuse.__version__ = "0.2"

fuse.fuse_python_api = (0, 2)


ROOT_DRIVEWSID = "FOLDER::com.apple.CloudDocs::root"
DIRECTORY_NODE_TYPES = {"folder", "app_library"}
IO_CHUNK_SIZE = 1024 * 1024


def normalize_icloud_path(path):
    """Return an absolute, normalized iCloud Drive path."""
    normalized = os.path.normpath("/" + path.lstrip("/"))
    return "/" if normalized == "." else normalized


def normalize_icloud_paths(paths):
    """Normalize configured path prefixes, preserving an empty allow-list."""
    if not paths:
        return []
    return [normalize_icloud_path(path) for path in paths]


def path_allowed(path, sync_paths, exclude_paths):
    """Return whether a path is within the configured synchronization boundary."""
    path = normalize_icloud_path(path)

    for prefix in exclude_paths:
        if prefix == "/" or path == prefix or path.startswith(prefix + "/"):
            return False

    if sync_paths is None:
        return True
    return any(
        prefix == "/" or path == prefix or path.startswith(prefix + "/")
        for prefix in sync_paths
    )


class Stat(fuse.Stat):
    def __init__(self):
        self.st_mode = 0
        self.st_ino = 0
        self.st_dev = 0
        self.st_nlink = 0
        self.st_uid = 0
        self.st_gid = 0
        self.st_size = 0
        self.st_atime = 0
        self.st_mtime = 0
        self.st_ctime = 0


class IgnoreIcdrsWarning(logging.Filter):
    def filter(self, record):
        return "ICDRS is not disabled; requestWebAccessState=" not in record.getMessage()


def parse_remote_time(value):
    if not value:
        return int(time.time())
    try:
        parsed = datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return int(time.time())
    return int(calendar_timegm(parsed.timetuple()))


def calendar_timegm(timetuple):
    return int(datetime.datetime(*timetuple[:6], tzinfo=datetime.timezone.utc).timestamp())


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def row_to_dict(row):
    return dict(row) if row is not None else None


class NamedFileStream:
    def __init__(self, handle, name):
        self._handle = handle
        self.name = name

    # Defined explicitly (not via __getattr__) so the object satisfies
    # requests' `isinstance(fp, _SupportsRead)` check. That check is a
    # runtime_checkable Protocol, which on Python 3.12+ inspects the class
    # rather than __getattr__; without a real method requests treats the
    # stream as raw data and the upload fails with "a bytes-like object is
    # required, not 'NamedFileStream'".
    def read(self, *args, **kwargs):
        return self._handle.read(*args, **kwargs)

    def __getattr__(self, attr):
        return getattr(self._handle, attr)


class SyncState:
    def __init__(self, db_path):
        self.db_path = db_path
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        self.lock = threading.RLock()
        self.conn = sqlite3.connect(db_path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self._init_db()

    def _init_db(self):
        with self.lock:
            self.conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS entries (
                    path TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    parent_path TEXT NOT NULL,
                    remote_drivewsid TEXT,
                    remote_docwsid TEXT,
                    remote_etag TEXT,
                    remote_zone TEXT,
                    remote_shareid TEXT,
                    size INTEGER NOT NULL DEFAULT 0,
                    mtime INTEGER NOT NULL DEFAULT 0,
                    hydrated INTEGER NOT NULL DEFAULT 0,
                    dirty INTEGER NOT NULL DEFAULT 0,
                    tombstone INTEGER NOT NULL DEFAULT 0,
                    local_sha256 TEXT,
                    last_synced_at INTEGER,
                    synced_path TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_entries_remote_drivewsid
                    ON entries(remote_drivewsid);
                CREATE INDEX IF NOT EXISTS idx_entries_dirty
                    ON entries(dirty, tombstone);
                CREATE TABLE IF NOT EXISTS pending_ops (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    op TEXT NOT NULL,
                    path TEXT NOT NULL,
                    target_path TEXT,
                    queued_at INTEGER NOT NULL,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT
                );
                CREATE TABLE IF NOT EXISTS folder_listings (
                    path TEXT PRIMARY KEY,
                    remote_drivewsid TEXT,
                    listed_at INTEGER NOT NULL
                );
                """
            )
            columns = {
                row["name"]
                for row in self.conn.execute("PRAGMA table_info(entries)").fetchall()
            }
            if "remote_shareid" not in columns:
                self.conn.execute("ALTER TABLE entries ADD COLUMN remote_shareid TEXT")
            self.conn.commit()

    # --- Elencazione on-demand (crawl_mode: lazy) -------------------------
    # folder_listings traccia, per ciascuna cartella già sfogliata dall'utente,
    # quando è stata interrogata l'ultima volta da remoto. Tabella separata da
    # `entries` (invece di aggiungere colonne lì) perché la radice "/" non è
    # mai essa stessa una riga di `entries` (è gestita a parte in getattr/
    # readdir), quindi qui può avere una entry propria senza casi speciali.

    def get_folder_listing(self, path):
        with self.lock:
            row = self.conn.execute(
                "SELECT * FROM folder_listings WHERE path = ?",
                (path,),
            ).fetchone()
            return row_to_dict(row)

    def mark_folder_listed(self, path, remote_drivewsid=None):
        with self.lock:
            self.conn.execute(
                """
                INSERT INTO folder_listings (path, remote_drivewsid, listed_at)
                VALUES (?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    remote_drivewsid = excluded.remote_drivewsid,
                    listed_at = excluded.listed_at
                """,
                (path, remote_drivewsid, int(time.time())),
            )
            self.conn.commit()

    def list_children(self, parent_path):
        with self.lock:
            rows = self.conn.execute(
                "SELECT * FROM entries WHERE parent_path = ? ORDER BY path",
                (parent_path,),
            ).fetchall()
            return [self._decode_entry(dict(row)) for row in rows]

    def list_stale_folder_listings(self, ttl_seconds):
        cutoff = int(time.time()) - int(ttl_seconds)
        with self.lock:
            rows = self.conn.execute(
                "SELECT path FROM folder_listings WHERE listed_at < ? ORDER BY listed_at ASC",
                (cutoff,),
            ).fetchall()
            return [row["path"] for row in rows]

    def upsert_entry(self, entry):
        payload = {
            "path": entry["path"],
            "type": entry["type"],
            "parent_path": entry["parent_path"],
            "remote_drivewsid": entry.get("remote_drivewsid"),
            "remote_docwsid": entry.get("remote_docwsid"),
            "remote_etag": entry.get("remote_etag"),
            "remote_zone": entry.get("remote_zone"),
            "remote_shareid": self._encode_shareid(entry.get("remote_shareid")),
            "size": int(entry.get("size", 0) or 0),
            "mtime": int(entry.get("mtime", 0) or 0),
            "hydrated": int(bool(entry.get("hydrated", False))),
            "dirty": int(bool(entry.get("dirty", False))),
            "tombstone": int(bool(entry.get("tombstone", False))),
            "local_sha256": entry.get("local_sha256"),
            "last_synced_at": entry.get("last_synced_at"),
            "synced_path": entry.get("synced_path", entry["path"]),
        }
        with self.lock:
            self.conn.execute(
                """
                INSERT INTO entries (
                    path, type, parent_path, remote_drivewsid, remote_docwsid, remote_etag,
                    remote_zone, remote_shareid, size, mtime, hydrated, dirty, tombstone, local_sha256,
                    last_synced_at, synced_path
                ) VALUES (
                    :path, :type, :parent_path, :remote_drivewsid, :remote_docwsid, :remote_etag,
                    :remote_zone, :remote_shareid, :size, :mtime, :hydrated, :dirty, :tombstone, :local_sha256,
                    :last_synced_at, :synced_path
                )
                ON CONFLICT(path) DO UPDATE SET
                    type = excluded.type,
                    parent_path = excluded.parent_path,
                    remote_drivewsid = excluded.remote_drivewsid,
                    remote_docwsid = excluded.remote_docwsid,
                    remote_etag = excluded.remote_etag,
                    remote_zone = excluded.remote_zone,
                    remote_shareid = excluded.remote_shareid,
                    size = excluded.size,
                    mtime = excluded.mtime,
                    hydrated = excluded.hydrated,
                    dirty = excluded.dirty,
                    tombstone = excluded.tombstone,
                    local_sha256 = excluded.local_sha256,
                    last_synced_at = excluded.last_synced_at,
                    synced_path = excluded.synced_path
                """,
                payload,
            )
            self.conn.commit()

    def get_entry(self, path):
        with self.lock:
            row = self.conn.execute(
                "SELECT * FROM entries WHERE path = ?",
                (path,),
            ).fetchone()
        return self._decode_entry(row_to_dict(row))

    def get_entry_by_remote_id(self, remote_drivewsid):
        with self.lock:
            row = self.conn.execute(
                "SELECT * FROM entries WHERE remote_drivewsid = ?",
                (remote_drivewsid,),
            ).fetchone()
        return self._decode_entry(row_to_dict(row))

    def list_entries(self):
        with self.lock:
            rows = self.conn.execute("SELECT * FROM entries ORDER BY path").fetchall()
        return [self._decode_entry(dict(row)) for row in rows]

    def count_entries(self):
        with self.lock:
            row = self.conn.execute("SELECT COUNT(*) AS count FROM entries").fetchone()
        return int(row["count"])

    def list_unhydrated_paths(self):
        with self.lock:
            rows = self.conn.execute(
                """
                SELECT path FROM entries
                WHERE type = 'file' AND tombstone = 0 AND hydrated = 0
                ORDER BY path
                """
            ).fetchall()
        return [row["path"] for row in rows]

    def list_dirty_entries(self):
        with self.lock:
            rows = self.conn.execute(
                """
                SELECT * FROM entries
                WHERE dirty = 1 OR tombstone = 1
                ORDER BY path
                """
            ).fetchall()
        return [self._decode_entry(dict(row)) for row in rows]

    def mark_hydrated(self, path, local_sha256=None, size=None, mtime=None):
        with self.lock:
            self.conn.execute(
                """
                UPDATE entries
                SET hydrated = 1,
                    local_sha256 = COALESCE(?, local_sha256),
                    size = COALESCE(?, size),
                    mtime = COALESCE(?, mtime)
                WHERE path = ?
                """,
                (local_sha256, size, mtime, path),
            )
            self.conn.commit()

    def mark_dirty(self, path, size=None, mtime=None, hydrated=None, local_sha256=None):
        with self.lock:
            self.conn.execute(
                """
                UPDATE entries
                SET dirty = 1,
                    tombstone = 0,
                    size = COALESCE(?, size),
                    mtime = COALESCE(?, mtime),
                    hydrated = COALESCE(?, hydrated),
                    local_sha256 = COALESCE(?, local_sha256)
                WHERE path = ?
                """,
                (size, mtime, hydrated, local_sha256, path),
            )
            self.conn.commit()

    def mark_tombstone(self, path):
        with self.lock:
            self.conn.execute(
                """
                UPDATE entries
                SET tombstone = 1,
                    dirty = 1
                WHERE path = ?
                """,
                (path,),
            )
            self.conn.commit()

    def mark_clean(self, path, remote_meta=None, local_sha256=None):
        remote_meta = remote_meta or {}
        with self.lock:
            self.conn.execute(
                """
                UPDATE entries
                SET dirty = 0,
                    tombstone = 0,
                    hydrated = CASE
                        WHEN type = 'file' THEN hydrated
                        ELSE 1
                    END,
                    remote_drivewsid = COALESCE(?, remote_drivewsid),
                    remote_docwsid = COALESCE(?, remote_docwsid),
                    remote_etag = COALESCE(?, remote_etag),
                    remote_zone = COALESCE(?, remote_zone),
                    size = COALESCE(?, size),
                    mtime = COALESCE(?, mtime),
                    local_sha256 = COALESCE(?, local_sha256),
                    last_synced_at = ?,
                    synced_path = path
                WHERE path = ?
                """,
                (
                    remote_meta.get("remote_drivewsid"),
                    remote_meta.get("remote_docwsid"),
                    remote_meta.get("remote_etag"),
                    remote_meta.get("remote_zone"),
                    remote_meta.get("size"),
                    remote_meta.get("mtime"),
                    local_sha256,
                    int(time.time()),
                    path,
                ),
            )
            self.conn.execute(
                "DELETE FROM pending_ops WHERE path = ? OR target_path = ?",
                (path, path),
            )
            self.conn.commit()

    def remove_entry(self, path):
        with self.lock:
            self.conn.execute("DELETE FROM entries WHERE path = ?", (path,))
            self.conn.execute(
                "DELETE FROM pending_ops WHERE path = ? OR target_path = ?",
                (path, path),
            )
            self.conn.commit()

    def remove_subtree(self, path):
        prefix = path.rstrip("/") + "/"
        with self.lock:
            self.conn.execute(
                "DELETE FROM entries WHERE path = ? OR path LIKE ?",
                (path, prefix + "%"),
            )
            self.conn.execute(
                "DELETE FROM pending_ops WHERE path = ? OR path LIKE ? OR target_path = ? OR target_path LIKE ?",
                (path, prefix + "%", path, prefix + "%"),
            )
            self.conn.commit()

    def rename_tree(self, oldpath, newpath, root_dirty=True, update_synced=False):
        entries = self._fetch_subtree(oldpath)
        if not entries:
            return
        prefix = oldpath.rstrip("/") + "/"
        with self.lock:
            for entry in entries:
                current = entry["path"]
                suffix = "" if current == oldpath else current[len(prefix) :]
                updated = newpath if not suffix else newpath.rstrip("/") + "/" + suffix
                updated_parent = os.path.dirname(updated) or "/"
                dirty = 1 if (root_dirty and current == oldpath) else entry["dirty"]
                self.conn.execute(
                    """
                    UPDATE entries
                    SET path = ?,
                        parent_path = ?,
                        dirty = ?,
                        synced_path = CASE
                            WHEN ? = 1 AND synced_path = ? THEN ?
                            WHEN ? = 1 AND synced_path LIKE ? THEN ? || substr(synced_path, ?)
                            ELSE synced_path
                        END
                    WHERE path = ?
                    """,
                    (
                        updated,
                        updated_parent,
                        dirty,
                        int(update_synced),
                        oldpath,
                        newpath,
                        int(update_synced),
                        prefix + "%",
                        newpath.rstrip("/") + "/",
                        len(prefix) + 1,
                        current,
                    ),
                )
            self.conn.execute(
                """
                UPDATE pending_ops
                SET path = CASE
                    WHEN path = ? THEN ?
                    WHEN path LIKE ? THEN ? || substr(path, ?)
                    ELSE path
                END,
                target_path = CASE
                    WHEN target_path = ? THEN ?
                    WHEN target_path LIKE ? THEN ? || substr(target_path, ?)
                    ELSE target_path
                END
                """,
                (
                    oldpath,
                    newpath,
                    prefix + "%",
                    newpath.rstrip("/") + "/",
                    len(prefix) + 1,
                    oldpath,
                    newpath,
                    prefix + "%",
                    newpath.rstrip("/") + "/",
                    len(prefix) + 1,
                ),
            )
            self.conn.commit()

    def mark_synced_subtree(self, path):
        prefix = path.rstrip("/") + "/"
        with self.lock:
            self.conn.execute(
                """
                UPDATE entries
                SET synced_path = path,
                    dirty = CASE
                        WHEN path = ? THEN 0
                        ELSE dirty
                    END,
                    tombstone = CASE
                        WHEN path = ? THEN 0
                        ELSE tombstone
                    END,
                    last_synced_at = ?
                WHERE path = ? OR path LIKE ?
                """,
                (path, path, int(time.time()), path, prefix + "%"),
            )
            self.conn.commit()

    def detach_subtree_as_conflict(self, oldpath, newpath):
        entries = self._fetch_subtree(oldpath)
        if not entries:
            return
        prefix = oldpath.rstrip("/") + "/"
        with self.lock:
            for entry in entries:
                current = entry["path"]
                suffix = "" if current == oldpath else current[len(prefix) :]
                updated = newpath if not suffix else newpath.rstrip("/") + "/" + suffix
                updated_parent = os.path.dirname(updated) or "/"
                self.conn.execute(
                    """
                    UPDATE entries
                    SET path = ?,
                        parent_path = ?,
                        remote_drivewsid = NULL,
                        remote_docwsid = NULL,
                        remote_etag = NULL,
                        remote_zone = NULL,
                        remote_shareid = NULL,
                        synced_path = NULL,
                        dirty = 1,
                        tombstone = 0
                    WHERE path = ?
                    """,
                    (updated, updated_parent, current),
                )
            self.conn.commit()

    def clear_remote_identity(self, path):
        with self.lock:
            self.conn.execute(
                """
                UPDATE entries
                SET remote_drivewsid = NULL,
                    remote_docwsid = NULL,
                    remote_etag = NULL,
                    remote_zone = NULL,
                    remote_shareid = NULL,
                    synced_path = NULL,
                    dirty = 1,
                    tombstone = 0
                WHERE path = ?
                """,
                (path,),
            )
            self.conn.commit()

    def queue_op(self, op, path, target_path=None):
        now = int(time.time())
        with self.lock:
            if op == "delete":
                existing_create = self.conn.execute(
                    "SELECT id FROM pending_ops WHERE path = ? AND op IN ('create', 'mkdir')",
                    (path,),
                ).fetchone()
                if existing_create:
                    self.conn.execute("DELETE FROM pending_ops WHERE path = ?", (path,))
                    self.conn.commit()
                    return
            self.conn.execute(
                """
                INSERT INTO pending_ops (op, path, target_path, queued_at)
                VALUES (?, ?, ?, ?)
                """,
                (op, path, target_path, now),
            )
            self.conn.commit()

    def _fetch_subtree(self, path):
        prefix = path.rstrip("/") + "/"
        with self.lock:
            rows = self.conn.execute(
                """
                SELECT * FROM entries
                WHERE path = ? OR path LIKE ?
                ORDER BY LENGTH(path) ASC, path ASC
                """,
                (path, prefix + "%"),
            ).fetchall()
        return [self._decode_entry(dict(row)) for row in rows]

    def _encode_shareid(self, shareid):
        if not shareid:
            return None
        return json.dumps(shareid, sort_keys=True)

    def _decode_entry(self, entry):
        if entry is None:
            return None
        shareid = entry.get("remote_shareid")
        if isinstance(shareid, str) and shareid:
            try:
                entry["remote_shareid"] = json.loads(shareid)
            except json.JSONDecodeError:
                entry["remote_shareid"] = None
        return entry


class LocalMirror:
    def __init__(self, cache_dir):
        self.cache_dir = cache_dir
        self.root = os.path.join(cache_dir, "mirror")
        self.tmp_dir = os.path.join(cache_dir, "tmp")
        os.makedirs(self.root, exist_ok=True)
        os.makedirs(self.tmp_dir, exist_ok=True)

    def local_path(self, path):
        normalized = os.path.normpath(path)
        if normalized == ".":
            normalized = "/"
        if not normalized.startswith("/"):
            normalized = "/" + normalized
        relative = normalized.lstrip("/")
        local = os.path.abspath(os.path.join(self.root, relative))
        if local != self.root and not local.startswith(self.root + os.sep):
            raise ValueError(f"Path escapes mirror root: {path}")
        return local

    def ensure_dir(self, path):
        local = self.local_path(path)
        if os.path.exists(local) and not os.path.isdir(local):
            os.unlink(local)
        os.makedirs(local, exist_ok=True)

    def ensure_parent(self, path):
        parent = os.path.dirname(path) or "/"
        os.makedirs(self.local_path(parent), exist_ok=True)

    def materialize_placeholder(self, path, size, mtime):
        local = self.local_path(path)
        self.ensure_parent(path)
        if os.path.isdir(local):
            shutil.rmtree(local)
        with open(local, "wb") as handle:
            handle.truncate(int(size or 0))
        os.utime(local, (mtime, mtime))

    def write_atomic_bytes(self, path, content, mtime=None):
        self.ensure_parent(path)
        local = self.local_path(path)
        fd, tmp_path = tempfile.mkstemp(dir=self.tmp_dir)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(content)
            os.replace(tmp_path, local)
            if mtime is not None:
                os.utime(local, (mtime, mtime))
        finally:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)

    def write_atomic_stream(self, path, source, mtime=None, chunk_size=IO_CHUNK_SIZE):
        self.ensure_parent(path)
        local = self.local_path(path)
        fd, tmp_path = tempfile.mkstemp(dir=self.tmp_dir)
        try:
            with os.fdopen(fd, "wb") as handle:
                shutil.copyfileobj(source, handle, length=chunk_size)
            os.replace(tmp_path, local)
            if mtime is not None:
                os.utime(local, (mtime, mtime))
        finally:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)

    def read(self, path, size, offset):
        local = self.local_path(path)
        with open(local, "rb") as handle:
            handle.seek(offset)
            return handle.read(size)

    def write(self, path, buf, offset):
        self.ensure_parent(path)
        local = self.local_path(path)
        mode = "r+b" if os.path.exists(local) else "w+b"
        with open(local, mode) as handle:
            handle.seek(offset)
            handle.write(buf)
            handle.flush()
        return len(buf)

    def truncate(self, path, length):
        self.ensure_parent(path)
        local = self.local_path(path)
        mode = "r+b" if os.path.exists(local) else "w+b"
        with open(local, mode) as handle:
            handle.truncate(length)

    def create_file(self, path):
        self.ensure_parent(path)
        local = self.local_path(path)
        with open(local, "ab"):
            pass

    def listdir(self, path):
        return os.listdir(self.local_path(path))

    def exists(self, path):
        return os.path.exists(self.local_path(path))

    def is_dir(self, path):
        return os.path.isdir(self.local_path(path))

    def remove_file(self, path):
        os.unlink(self.local_path(path))

    def remove_dir(self, path):
        os.rmdir(self.local_path(path))

    def remove_tree(self, path):
        local = self.local_path(path)
        if os.path.isdir(local):
            shutil.rmtree(local)
        elif os.path.exists(local):
            os.unlink(local)

    def rename_path(self, oldpath, newpath):
        self.ensure_parent(newpath)
        os.replace(self.local_path(oldpath), self.local_path(newpath))

    def stat_local(self, path):
        return os.lstat(self.local_path(path))

    def statvfs(self):
        return os.statvfs(self.root)

    def set_mtime(self, path, mtime):
        local = self.local_path(path)
        os.utime(local, (mtime, mtime))

    def file_sha256(self, path):
        return sha256_file(self.local_path(path))


class ICloudSyncEngine:
    def __init__(
        self,
        api,
        mirror,
        state,
        logger,
        warmup_mode="background",
        conflict_mode="copy",
        upload_interval_seconds=30,
        remote_refresh_interval_seconds=300,
        warmup_workers=1,
        sync_paths=None,
        exclude_paths=None,
        auto_sync=True,
        crawl_mode="lazy",
    ):
        self.api = api
        self.mirror = mirror
        # "lazy": nessun crawl ricorsivo all'avvio; ogni cartella si elenca da
        #   remoto solo al primo readdir() (stile Finder/Files.app su macOS).
        # "full": comportamento storico, crawl ricorsivo completo all'avvio
        #   e ad ogni refresh periodico — mantenuto per compatibilità.
        self.crawl_mode = crawl_mode if crawl_mode in {"lazy", "full"} else "lazy"
        self.state = state
        self.logger = logger
        self.warmup_mode = warmup_mode if warmup_mode in {"background", "lazy"} else "background"
        self.conflict_mode = conflict_mode if conflict_mode in {"copy"} else "copy"
        self.upload_interval_seconds = upload_interval_seconds
        self.remote_refresh_interval_seconds = remote_refresh_interval_seconds
        self.warmup_workers = max(1, int(warmup_workers))
        self.auto_sync = bool(auto_sync)
        # An empty sync_paths value preserves unrestricted syncing.
        self.sync_paths = normalize_icloud_paths(sync_paths) or None
        self.exclude_paths = normalize_icloud_paths(exclude_paths)
        self.executor = ThreadPoolExecutor(max_workers=self.warmup_workers, thread_name_prefix="warmup")
        self.stop_event = threading.Event()
        self.refresh_now_event = threading.Event()
        self.path_locks = {}
        self.path_locks_lock = threading.Lock()
        self.scheduled_downloads = set()
        self.downloads_lock = threading.Lock()
        self.download_retry_attempts = {}
        self.download_retry_timers = {}
        self.threads = []
        self.hydration_total = 0
        self.hydration_completed = 0
        self.hydration_progress_lock = threading.Lock()
        # Reentrant: shutdown() runs on the main thread from three places (the
        # finally: after fs.main(), the atexit hook, and the SIGTERM/SIGINT
        # handler). Python runs signal handlers on the main thread, so a signal
        # arriving while shutdown() is already in progress re-enters it. With a
        # plain Lock that self-deadlocks against a frame that can never resume.
        self.shutdown_lock = threading.RLock()
        self.is_shutdown = False
        # PyiCloud downloads appear sensitive to concurrent use of one session.
        self.download_semaphore = threading.Semaphore(1)

    def _log_sync(self, event, level=logging.INFO, **fields):
        details = " ".join(f"{key}={value!r}" for key, value in fields.items() if value is not None)
        if details:
            self.logger.log(level, "sync %s %s", event, details)
            return
        self.logger.log(level, "sync %s", event)

    def start(self):
        if self.has_persistent_cache():
            self.logger.info("Using persistent local cache from %s", self.mirror.root)
            self._reconcile_persistent_cache()
            if self.crawl_mode == "full" and self.warmup_mode == "background":
                self._schedule_all_unhydrated()
        elif self.crawl_mode == "full":
            self.logger.info("Persistent cache not initialized yet; performing first remote crawl")
            self.initial_scan()
            if self.warmup_mode == "background":
                self._schedule_all_unhydrated()
        else:
            # crawl_mode == "lazy": nessuna scansione remota all'avvio.
            # Basta che la radice esista come cartella reale sul mirror perché
            # il mount FUSE abbia un punto di attacco valido; il suo contenuto
            # verrà elencato da remoto al primo readdir("/") (vedi
            # list_directory()), non qui.
            self.mirror.ensure_dir("/")
            self.logger.info(
                "crawl_mode=lazy: nessun crawl ricorsivo all'avvio; le cartelle si "
                "elencano da remoto al primo accesso via Nautilus/ls"
            )
        if self.auto_sync:
            self._start_background_threads()
        else:
            self.logger.info(
                "auto_sync disabled — background upload/refresh threads not started. "
                "Use 'icloudctl sync' to trigger a one-shot refresh on demand."
            )

    def _start_background_threads(self):
        upload_thread = threading.Thread(target=self._upload_loop, name="icloud-upload", daemon=True)
        refresh_thread = threading.Thread(target=self._refresh_loop, name="icloud-refresh", daemon=True)
        upload_thread.start()
        refresh_thread.start()
        self.threads.extend([upload_thread, refresh_thread])

    def shutdown(self):
        with self.shutdown_lock:
            if self.is_shutdown:
                return
            self.is_shutdown = True
            self.stop_event.set()
            self.refresh_now_event.set()
            with self.downloads_lock:
                timers = list(self.download_retry_timers.values())
                self.download_retry_timers.clear()
                self.scheduled_downloads.clear()
            for timer in timers:
                timer.cancel()
            try:
                self.executor.shutdown(wait=False, cancel_futures=True)
            except TypeError:
                self.executor.shutdown(wait=False)
            for thread in list(self.threads):
                thread.join(timeout=1)

    def has_persistent_cache(self):
        return self.state.count_entries() > 0 and os.path.isdir(self.mirror.root)

    def initial_scan(self):
        crawl_started_at = int(time.time())
        snapshot = self._crawl_remote_snapshot()
        self._apply_remote_snapshot(snapshot, crawl_started_at=crawl_started_at)

    def _reconcile_persistent_cache(self):
        entries = self.state.list_entries()
        missing_files = 0
        recreated_dirs = 0

        for entry in entries:
            path = entry["path"]
            if entry["tombstone"]:
                continue
            if self._is_directory_type(entry["type"]):
                if not self.mirror.is_dir(path):
                    self.mirror.ensure_dir(path)
                    recreated_dirs += 1
                continue

            if self.mirror.exists(path):
                stats = self.mirror.stat_local(path)
                checksum = entry.get("local_sha256")
                hydrated = bool(entry["hydrated"])
                if entry["type"] == "file" and (hydrated or not entry["remote_drivewsid"]):
                    hydrated = True
                    # Only recompute the SHA256 if size or mtime changed since
                    # the last recorded sync — reading every file on startup is
                    # the cause of the 4-minute / 11 GB memory blowup at boot.
                    size_changed = stats.st_size != int(entry.get("size") or 0)
                    mtime_changed = int(stats.st_mtime) != int(entry.get("mtime") or 0)
                    if size_changed or mtime_changed or not checksum:
                        checksum = self.mirror.file_sha256(path)
                self.state.upsert_entry(
                    {
                        **entry,
                        "size": stats.st_size,
                        "mtime": int(stats.st_mtime),
                        "hydrated": hydrated,
                        "local_sha256": checksum,
                    }
                )
                continue

            missing_files += 1
            if entry["remote_drivewsid"]:
                self.mirror.materialize_placeholder(path, entry["size"], entry["mtime"])
                self.state.upsert_entry({**entry, "hydrated": entry["size"] == 0})
            else:
                self.mirror.create_file(path)
                stats = self.mirror.stat_local(path)
                checksum = self.mirror.file_sha256(path)
                self.state.upsert_entry(
                    {
                        **entry,
                        "size": stats.st_size,
                        "mtime": int(stats.st_mtime),
                        "hydrated": True,
                        "local_sha256": checksum,
                    }
                )

        self.logger.info(
            "Persistent cache ready: %s entries, %s directories recreated, %s files queued for hydration",
            len(entries),
            recreated_dirs,
            missing_files,
        )

    def _is_directory_type(self, node_type):
        return (node_type or "").lower() in DIRECTORY_NODE_TYPES

    def ensure_local_file(self, path):
        if not self._path_allowed(path):
            return
        entry = self.state.get_entry(path)
        if not entry or entry["type"] != "file" or entry["tombstone"]:
            return
        if entry["hydrated"] and self.mirror.exists(path):
            return

        lock = self._path_lock(path)
        with lock:
            entry = self.state.get_entry(path)
            if not entry or entry["type"] != "file" or entry["tombstone"]:
                return
            if entry["hydrated"] and self.mirror.exists(path):
                return
            if not entry["remote_drivewsid"]:
                self._log_sync("hydrate-local", level=logging.DEBUG, path=path)
                if not self.mirror.exists(path):
                    self.mirror.create_file(path)
                checksum = self.mirror.file_sha256(path)
                stats = self.mirror.stat_local(path)
                self.state.mark_hydrated(path, checksum, stats.st_size, int(stats.st_mtime))
                self._log_sync(
                    "hydrate-complete",
                    level=logging.INFO,
                    path=path,
                    source="local",
                    size=stats.st_size,
                )
                return

            self._log_sync(
                "hydrate-start",
                level=logging.INFO,
                path=path,
                drivewsid=entry.get("remote_drivewsid"),
                size=entry.get("size"),
            )
            self.logger.debug("Hydrating %s", path)
            with self.download_semaphore:
                self.logger.debug(
                    "Hydrating file path=%s drivewsid=%s docwsid=%s zone=%s size=%s",
                    path,
                    entry.get("remote_drivewsid"),
                    entry.get("remote_docwsid"),
                    entry.get("remote_zone"),
                    entry.get("size"),
                )
                node = self._node_from_entry(entry)
                with closing(node.open(stream=True)) as response:
                    self.mirror.write_atomic_stream(path, response.raw, entry["mtime"])
            stats = self.mirror.stat_local(path)
            checksum = self.mirror.file_sha256(path)
            self.state.mark_hydrated(path, checksum, stats.st_size, int(stats.st_mtime))
            self._log_sync("hydrate-complete", level=logging.INFO, path=path, source="remote", size=stats.st_size)

    def _crawl_remote_snapshot(self):
        self.logger.info("Starting remote metadata crawl")
        snapshot = {}
        queue = deque()
        root = self.api.drive.root
        queue.append((root, "/"))
        started_at = time.time()
        last_progress_log = started_at
        scanned_folders = 0
        _crawl_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="icloud-crawl")
        FOLDER_TIMEOUT = 60  # seconds per folder before giving up

        while queue:
            node, path = queue.popleft()
            scanned_folders += 1
            try:
                future = _crawl_executor.submit(node.get_children, True)
                children = future.result(timeout=FOLDER_TIMEOUT)
            except TimeoutError:
                self.logger.warning(
                    "Timed out enumerating %s after %ss — skipping folder", path, FOLDER_TIMEOUT
                )
                continue
            except Exception as exc:
                self.logger.error("Failed to enumerate %s: %s", path, exc)
                continue

            for child in children:
                child_path = "/" + child.name if path == "/" else path.rstrip("/") + "/" + child.name
                meta = self._node_to_meta(child, child_path)
                snapshot[meta["remote_drivewsid"]] = meta
                if self._is_directory_type(meta["type"]):
                    # If sync_paths is set, only recurse into directories that are
                    # on the path to or inside a sync_path. This avoids crawling
                    # the entire iCloud Drive when only /Downloads is needed.
                    if self.sync_paths is not None:
                        should_recurse = False
                        for sp in self.sync_paths:
                            sp = sp.rstrip("/")
                            cp = child_path.rstrip("/")
                            # Recurse if child is a prefix of sync_path (ancestor)
                            # or if child is inside sync_path (descendant)
                            if sp.startswith(cp + "/") or sp == cp or cp.startswith(sp + "/"):
                                should_recurse = True
                                break
                        if not should_recurse:
                            continue
                    queue.append((child, child_path))

            now = time.time()
            if scanned_folders == 1 or scanned_folders % 25 == 0 or now - last_progress_log >= 5:
                self.logger.info(
                    "Remote metadata crawl progress: %s folders scanned, %s entries discovered, %s folders queued",
                    scanned_folders,
                    len(snapshot),
                    len(queue),
                )
                last_progress_log = now

        self.logger.info(
            "Remote metadata crawl complete: %s entries across %s folders in %.1fs",
            len(snapshot),
            scanned_folders,
            time.time() - started_at,
        )
        return snapshot

    def _apply_remote_snapshot(self, snapshot, crawl_started_at=None):
        remote_ids = set(snapshot.keys())

        for meta in snapshot.values():
            existing = self.state.get_entry_by_remote_id(meta["remote_drivewsid"])
            if existing and existing["dirty"] and self._entry_conflicts(existing, meta):
                self._resolve_conflict(existing)
                existing = None

            if existing is None:
                path_entry = self.state.get_entry(meta["path"])
                if path_entry and path_entry["dirty"]:
                    self._resolve_conflict(path_entry)
                self._materialize_remote_entry(meta)
                continue

            if existing["dirty"]:
                continue

            self._refresh_clean_entry(existing, meta)

        for entry in self.state.list_entries():
            remote_id = entry["remote_drivewsid"]
            if not remote_id or remote_id in remote_ids:
                continue
            if entry["dirty"]:
                self.logger.warning("Remote deleted dirty path %s; keeping local copy for upload", entry["path"])
                self.state.clear_remote_identity(entry["path"])
                continue
            synced_at = entry.get("last_synced_at")
            if (
                crawl_started_at is not None
                and synced_at is not None
                and synced_at >= crawl_started_at
            ):
                self.logger.info(
                    "Keeping %s because it synced during the remote crawl",
                    entry["path"],
                )
                continue
            self.logger.info("Removing clean path deleted remotely: %s", entry["path"])
            self.mirror.remove_tree(entry["path"])
            self.state.remove_subtree(entry["path"])

    def _materialize_remote_entry(self, meta, schedule_download=True):
        local_path = meta["path"]
        self._log_sync(
            "remote-materialize",
            path=local_path,
            entry_type=meta["type"],
            drivewsid=meta.get("remote_drivewsid"),
            size=meta.get("size"),
        )
        if self._is_directory_type(meta["type"]):
            self.mirror.ensure_dir(local_path)
            hydrated = True
        else:
            self.mirror.materialize_placeholder(local_path, meta["size"], meta["mtime"])
            hydrated = meta["size"] == 0
        self.state.upsert_entry(
            {
                **meta,
                "hydrated": hydrated,
                "dirty": False,
                "tombstone": False,
                "synced_path": local_path,
            }
        )
        # schedule_download=False per le chiamate da list_directory() (elencazione
        # on-demand): l'utente ha solo aperto la cartella, non il file — deve
        # restare un placeholder (icona + dimensione corretta) finché non lo
        # apre davvero (vedi open()/ensure_local_file()). schedule_download=True
        # resta il default per il percorso storico di crawl_mode: full, dove il
        # warmup in background di TUTTI i file è il comportamento voluto.
        if meta["type"] == "file" and not hydrated and schedule_download:
            self._schedule_download(local_path)

    def _refresh_clean_entry(self, entry, meta, schedule_download=True):
        oldpath = entry["path"]
        newpath = meta["path"]
        if oldpath != newpath and self.mirror.exists(oldpath):
            self._log_sync("remote-rename", path=oldpath, target_path=newpath, entry_type=meta["type"])
            self.mirror.rename_path(oldpath, newpath)
            self.state.rename_tree(oldpath, newpath, root_dirty=False, update_synced=True)
            entry = self.state.get_entry(newpath)
        elif oldpath != newpath:
            self._log_sync("remote-rename", path=oldpath, target_path=newpath, entry_type=meta["type"])
            self.state.rename_tree(oldpath, newpath, root_dirty=False, update_synced=True)
            entry = self.state.get_entry(newpath)

        if self._is_directory_type(meta["type"]):
            self.mirror.ensure_dir(newpath)
            self.state.upsert_entry(
                {
                    **meta,
                    "hydrated": True,
                    "dirty": False,
                    "tombstone": False,
                    "local_sha256": entry.get("local_sha256") if entry else None,
                    "last_synced_at": entry.get("last_synced_at") if entry else None,
                    "synced_path": newpath,
                }
            )
            return

        should_replace = (
            entry is None
            or entry["remote_etag"] != meta["remote_etag"]
            or entry["size"] != meta["size"]
            or entry["mtime"] != meta["mtime"]
        )
        hydrated = bool(entry and entry["hydrated"] and not should_replace)
        if should_replace:
            self._log_sync(
                "remote-update",
                path=newpath,
                old_etag=entry.get("remote_etag") if entry else None,
                new_etag=meta.get("remote_etag"),
                size=meta.get("size"),
            )
            self.mirror.materialize_placeholder(newpath, meta["size"], meta["mtime"])
            hydrated = meta["size"] == 0
        self.state.upsert_entry(
            {
                **meta,
                "hydrated": hydrated,
                "dirty": False,
                "tombstone": False,
                "local_sha256": entry.get("local_sha256") if hydrated and entry else None,
                "last_synced_at": entry.get("last_synced_at") if entry else None,
                "synced_path": newpath,
            }
        )
        if not hydrated and schedule_download:
            self._schedule_download(newpath)

    def _resolve_conflict(self, entry):
        if self.conflict_mode != "copy":
            self.logger.warning("Unsupported conflict mode %s; falling back to copy", self.conflict_mode)
        conflict_path = self._conflict_path(entry["path"])
        self.logger.warning("Conflict on %s; preserving local version as %s", entry["path"], conflict_path)
        if self.mirror.exists(entry["path"]):
            self.mirror.rename_path(entry["path"], conflict_path)
        self.state.detach_subtree_as_conflict(entry["path"], conflict_path)
        subtree = self.state._fetch_subtree(conflict_path)
        for child in subtree:
            self.state.queue_op("conflict-copy", child["path"])

    def _schedule_all_unhydrated(self):
        paths = self.state.list_unhydrated_paths()
        total = len(paths)
        with self.hydration_progress_lock:
            self.hydration_total = total
            self.hydration_completed = 0
        if total:
            self.logger.info("Background cache warmup scheduled for %s files", total)
        else:
            self.logger.info("Background cache warmup skipped; all files already hydrated")
        for path in paths:
            self._schedule_download(path)

    def _schedule_download(self, path):
        self._schedule_download_with_delay(path, 0)

    def _schedule_download_with_delay(self, path, delay_seconds):
        if not self._path_allowed(path):
            return
        if self.stop_event.is_set() or self.is_shutdown:
            return

        with self.downloads_lock:
            if path in self.scheduled_downloads:
                return
            self.scheduled_downloads.add(path)

        self._log_sync(
            "download-scheduled",
            level=logging.DEBUG if delay_seconds <= 0 else logging.INFO,
            path=path,
            delay_seconds=delay_seconds,
        )

        if delay_seconds <= 0:
            try:
                self.executor.submit(self._download_job, path)
            except RuntimeError:
                with self.downloads_lock:
                    self.scheduled_downloads.discard(path)
            return

        timer = threading.Timer(delay_seconds, self._submit_retry_download, args=(path,))
        timer.daemon = True
        with self.downloads_lock:
            self.download_retry_timers[path] = timer
        timer.start()

    def _submit_retry_download(self, path):
        with self.downloads_lock:
            self.download_retry_timers.pop(path, None)
        if self.stop_event.is_set() or self.is_shutdown:
            with self.downloads_lock:
                self.scheduled_downloads.discard(path)
            return
        try:
            self.executor.submit(self._download_job, path)
        except RuntimeError:
            with self.downloads_lock:
                self.scheduled_downloads.discard(path)

    def _retry_delay_for_attempt(self, attempt):
        return min(300, 5 * (2 ** max(0, attempt - 1)))

    def _is_auth_error(self, exc):
        if isinstance(
            exc,
            (
                PyiCloud2FARequiredException,
                PyiCloud2SARequiredException,
                PyiCloudAuthRequiredException,
                PyiCloudFailedLoginException,
            ),
        ):
            return True
        return False

    def _download_job(self, path):
        retry_delay = None
        try:
            self.ensure_local_file(path)
            with self.downloads_lock:
                self.download_retry_attempts.pop(path, None)
            self._log_sync("download-complete", level=logging.INFO, path=path)
            with self.hydration_progress_lock:
                self.hydration_completed += 1
                completed = self.hydration_completed
                total = self.hydration_total
            if total and (completed == 1 or completed == total or completed % 25 == 0):
                self.logger.info(
                    "Background cache warmup progress: %s/%s files hydrated",
                    completed,
                    total,
                )
        except Exception as exc:
            if self._is_auth_error(exc):
                self.logger.error(
                    "Warmup download blocked by expired iCloud authentication for %s: %s. "
                    "Run './icloudctl auth' and then './icloudctl restart'.",
                    path,
                    exc,
                )
                with self.downloads_lock:
                    self.download_retry_attempts.pop(path, None)
                return
            with self.downloads_lock:
                attempt = self.download_retry_attempts.get(path, 0) + 1
                self.download_retry_attempts[path] = attempt
            retry_delay = self._retry_delay_for_attempt(attempt)
            self.logger.error(
                "Warmup download failed for %s (attempt %s): %s; retrying in %ss",
                path,
                attempt,
                exc,
                retry_delay,
            )
        finally:
            with self.downloads_lock:
                self.scheduled_downloads.discard(path)
                self.download_retry_timers.pop(path, None)
            if retry_delay is not None:
                self._schedule_download_with_delay(path, retry_delay)

    def _upload_loop(self):
        while not self.stop_event.wait(self.upload_interval_seconds):
            try:
                self.sync_dirty_entries()
            except Exception as exc:
                self.logger.error("Upload loop failed: %s", exc)

    def request_remote_refresh(self):
        self._log_sync("refresh-requested")
        self.refresh_now_event.set()

    def _run_remote_refresh(self, reason):
        try:
            self._log_sync("refresh-start", reason=reason)
            crawl_started_at = int(time.time())
            snapshot = self._crawl_remote_snapshot()
            self._apply_remote_snapshot(snapshot, crawl_started_at=crawl_started_at)
            self._log_sync("refresh-complete", reason=reason)
        except Exception as exc:
            self.logger.error("Remote refresh failed (%s): %s", reason, exc)

    def _run_lazy_refresh(self, reason):
        # In modalità lazy non esiste un "tutto l'albero" da riscandire: si
        # ri-elencano solo le cartelle che l'utente ha già sfogliato almeno
        # una volta e la cui voce in folder_listings è scaduta (stessa soglia
        # remote_refresh_interval_seconds usata storicamente per il refresh
        # globale). Ogni voce scaduta è una sola chiamata di rete mirata,
        # tramite lo stesso list_directory() usato da readdir().
        stale_paths = self.state.list_stale_folder_listings(self.remote_refresh_interval_seconds)
        if not stale_paths:
            self._log_sync("lazy-refresh-nothing-stale", reason=reason)
            return
        self._log_sync("lazy-refresh-start", reason=reason, stale_count=len(stale_paths))
        for path in stale_paths:
            if self.stop_event.is_set():
                break
            try:
                self.list_directory(path, force=True)
            except Exception as exc:
                self.logger.error("Lazy refresh fallito per %s: %s", path, exc)
        self._log_sync("lazy-refresh-complete", reason=reason)

    def _refresh_loop(self):
        if self.crawl_mode == "full":
            immediate = self.has_persistent_cache()
            if immediate:
                self.logger.info("Starting background remote refresh from persistent cache")
                self._run_remote_refresh("startup")
            while not self.stop_event.is_set():
                manual = self.refresh_now_event.wait(self.remote_refresh_interval_seconds)
                self.refresh_now_event.clear()
                if self.stop_event.is_set():
                    break
                self._run_remote_refresh("manual" if manual else "scheduled")
            return

        # crawl_mode == "lazy": stesso ritmo/eventi (SIGUSR1/timer), ma il
        # refresh tocca solo le cartelle già scoperte, mai l'intero albero.
        while not self.stop_event.is_set():
            manual = self.refresh_now_event.wait(self.remote_refresh_interval_seconds)
            self.refresh_now_event.clear()
            if self.stop_event.is_set():
                break
            self._run_lazy_refresh("manual" if manual else "scheduled")

    def list_directory(self, path, force=False):
        """Elenca (o ri-elenca se scaduta/forzata) i figli DIRETTI di `path`
        interrogando remoto una sola volta per questa cartella — mai in modo
        ricorsivo. Pensato per essere chiamato da readdir() del filesystem
        FUSE al momento in cui l'utente (Nautilus, ls, ecc.) apre davvero
        quella cartella, non in anticipo. Se la chiamata di rete fallisce,
        non solleva: readdir() mostrerà comunque quello che è già presente
        nel mirror locale."""
        lock = self._path_lock(path)
        with lock:
            listing = self.state.get_folder_listing(path)
            now = int(time.time())
            if (
                not force
                and listing
                and now - listing["listed_at"] < self.remote_refresh_interval_seconds
            ):
                return  # ancora fresca: nessuna chiamata di rete necessaria

            if path == "/":
                node = self.api.drive.root
                drivewsid = None
            else:
                entry = self.state.get_entry(path)
                if not entry or not entry.get("remote_drivewsid"):
                    # Cartella creata solo localmente (mai sincronizzata verso
                    # iCloud) o non ancora nota: nulla da elencare da remoto.
                    self.state.mark_folder_listed(path)
                    return
                drivewsid = entry["remote_drivewsid"]
                # DriveNode richiede la connessione DriveService (api.drive),
                # non l'oggetto PyiCloudService: verificato nel sorgente di
                # pyicloud (drive.py, DriveNode.__init__/get_children), che
                # con solo {"drivewsid": ...} nei dati rifà da sé una singola
                # chiamata retrieveItemDetailsInFolders per questo id — non
                # serve alcuna camminata dalla radice.
                node = DriveNode(self.api.drive, {"drivewsid": drivewsid})

            self._log_sync("list-directory-start", path=path)
            try:
                children = node.get_children(force=True)
            except Exception as exc:
                self.logger.error("Impossibile elencare %s da remoto: %s", path, exc)
                return

            seen_ids = set()
            for child in children:
                child_path = ("/" + child.name) if path == "/" else (path.rstrip("/") + "/" + child.name)
                meta = self._node_to_meta(child, child_path)
                seen_ids.add(meta["remote_drivewsid"])
                existing = self.state.get_entry_by_remote_id(meta["remote_drivewsid"])
                if existing and existing["dirty"] and self._entry_conflicts(existing, meta):
                    self._resolve_conflict(existing)
                    existing = None
                if existing is None:
                    path_entry = self.state.get_entry(meta["path"])
                    if path_entry and path_entry["dirty"]:
                        self._resolve_conflict(path_entry)
                    self._materialize_remote_entry(meta, schedule_download=False)
                elif not existing["dirty"]:
                    self._refresh_clean_entry(existing, meta, schedule_download=False)

            # Sweep locale limitato ai soli figli DIRETTI di questa cartella:
            # a differenza dello sweep di _apply_remote_snapshot (che opera
            # sull'intero albero ed è quindi sicuro solo a crawl completo
            # finito), qui il confronto è ristretto a state.list_children(path)
            # — non rischia mai di scambiare un ramo non ancora visitato per
            # "cancellato da remoto", perché semplicemente non lo tocca.
            for child_entry in self.state.list_children(path):
                remote_id = child_entry["remote_drivewsid"]
                if not remote_id or remote_id in seen_ids or child_entry["dirty"]:
                    continue
                self.logger.info("Rimuovo voce sparita da remoto: %s", child_entry["path"])
                self.mirror.remove_tree(child_entry["path"])
                self.state.remove_subtree(child_entry["path"])

            self.state.mark_folder_listed(path, drivewsid)
            self._log_sync("list-directory-complete", path=path, entries=len(children))

    def sync_dirty_entries(self):
        dirty_entries = [
            entry for entry in self.state.list_dirty_entries()
            if self._entry_allowed_to_sync(entry)
        ]
        if not dirty_entries:
            return

        self._log_sync("dirty-scan", dirty_count=len(dirty_entries))

        tombstones = sorted(
            [entry for entry in dirty_entries if entry["tombstone"]],
            key=lambda entry: (entry["path"].count("/"), entry["path"]),
            reverse=True,
        )
        regular = sorted(
            [entry for entry in dirty_entries if not entry["tombstone"]],
            key=lambda entry: (entry["type"] != "folder", entry["path"].count("/"), entry["path"]),
        )

        for entry in tombstones:
            self._sync_tombstone(entry)

        for entry in regular:
            fresh = self.state.get_entry(entry["path"])
            if fresh is None or fresh["tombstone"] or not fresh["dirty"]:
                continue
            if fresh["type"] == "folder":
                self._sync_directory(fresh)
            else:
                self._sync_file(fresh)

    def _sync_tombstone(self, entry):
        self._log_sync("delete-start", path=entry["path"], remote=bool(entry["remote_drivewsid"]))
        if entry["remote_drivewsid"]:
            try:
                node = self._node_from_entry(entry)
                node.delete()
            except Exception as exc:
                self.logger.error("Failed deleting remote path %s: %s", entry["path"], exc)
                return
        self.state.remove_subtree(entry["path"])
        self._log_sync("delete-complete", path=entry["path"])

    def _sync_directory(self, entry):
        parent_node = self._ensure_remote_parent(entry["path"])
        if parent_node is None:
            return

        try:
            self._log_sync(
                "directory-sync-start",
                path=entry["path"],
                remote_exists=bool(entry["remote_drivewsid"]),
                synced_path=entry.get("synced_path"),
            )
            if not entry["remote_drivewsid"]:
                parent_node.mkdir(os.path.basename(entry["path"]))
                meta = self._refresh_child_meta(os.path.dirname(entry["path"]) or "/", os.path.basename(entry["path"]))
                self.state.mark_clean(entry["path"], meta)
                self._log_sync("directory-create-complete", path=entry["path"])
                return

            if entry["synced_path"] and entry["synced_path"] != entry["path"]:
                self._sync_move_or_rename(entry)
            self.state.mark_synced_subtree(entry["path"])
            self._log_sync("directory-sync-complete", path=entry["path"])
        except Exception as exc:
            self.logger.error("Failed syncing directory %s: %s", entry["path"], exc)

    def _sync_file(self, entry):
        parent_node = self._ensure_remote_parent(entry["path"])
        if parent_node is None:
            return

        try:
            self._log_sync(
                "file-sync-start",
                path=entry["path"],
                remote_exists=bool(entry["remote_drivewsid"]),
                synced_path=entry.get("synced_path"),
            )
            if not self.mirror.exists(entry["path"]):
                self.state.mark_tombstone(entry["path"])
                self._log_sync("file-missing-marked-tombstone", path=entry["path"])
                return

            self.ensure_local_file(entry["path"])

            if entry["remote_drivewsid"] and entry["synced_path"] and entry["synced_path"] != entry["path"]:
                self._sync_move_or_rename(entry)
                entry = self.state.get_entry(entry["path"])

            if entry["remote_drivewsid"]:
                try:
                    self._node_from_entry(entry).delete()
                except Exception:
                    pass

            with open(self.mirror.local_path(entry["path"]), "rb") as handle:
                parent_node.upload(
                    NamedFileStream(handle, os.path.basename(entry["path"]))
                )

            meta = self._refresh_child_meta(os.path.dirname(entry["path"]) or "/", os.path.basename(entry["path"]))
            checksum = self.mirror.file_sha256(entry["path"])
            self.state.mark_clean(entry["path"], meta, checksum)
            self._log_sync("file-sync-complete", path=entry["path"], size=meta.get("size"))
        except Exception as exc:
            self.logger.error("Failed syncing file %s: %s", entry["path"], exc)

    def _sync_move_or_rename(self, entry):
        synced_path = entry["synced_path"]
        if not synced_path:
            return
        old_parent = os.path.dirname(synced_path) or "/"
        new_parent = os.path.dirname(entry["path"]) or "/"
        old_name = os.path.basename(synced_path)
        new_name = os.path.basename(entry["path"])

        self._log_sync("move-start", path=synced_path, target_path=entry["path"])
        node = self._node_from_entry(entry)
        if old_parent != new_parent:
            destination = self._remote_node_for_path(new_parent)
            if destination is None:
                raise RuntimeError(f"Remote parent not available for {new_parent}")
            self.api.drive.move_nodes_to_node([node], destination)
            node = self._refresh_node_by_id(
                entry["remote_drivewsid"],
                entry.get("remote_shareid"),
            )
        if old_name != new_name:
            node.rename(new_name)
        self._log_sync("move-complete", path=synced_path, target_path=entry["path"])

    def _entry_allowed_to_sync(self, entry):
        paths = [entry["path"]]
        synced_path = entry.get("synced_path")
        if synced_path and synced_path != entry["path"]:
            paths.append(synced_path)

        if all(self._path_allowed(path) for path in paths):
            return True

        self._log_sync(
            "dirty-skip-disallowed",
            level=logging.WARNING,
            path=entry["path"],
            synced_path=synced_path,
        )
        return False

    def _ensure_remote_parent(self, path):
        parent_path = os.path.dirname(path) or "/"
        if parent_path == "/":
            return self.api.drive.root
        parent_entry = self.state.get_entry(parent_path)
        if not parent_entry:
            return None
        if parent_entry["dirty"]:
            self._sync_directory(parent_entry)
            parent_entry = self.state.get_entry(parent_path)
        if not parent_entry or not parent_entry["remote_drivewsid"]:
            return None
        return self._node_from_entry(parent_entry)

    def _refresh_child_meta(self, parent_path, child_name):
        parent = self._remote_node_for_path(parent_path)
        if parent is None:
            raise RuntimeError(f"Missing remote parent: {parent_path}")
        for child in parent.get_children(force=True):
            if child.name == child_name:
                return self._node_to_meta(
                    child,
                    "/" + child.name if parent_path == "/" else parent_path.rstrip("/") + "/" + child.name,
                )
        raise KeyError(f"Missing child {child_name} under {parent_path}")

    def _remote_node_for_path(self, path):
        if path == "/" or path == "":
            return self.api.drive.root
        entry = self.state.get_entry(path)
        if not entry or not entry["remote_drivewsid"]:
            return None
        return self._node_from_entry(entry)

    def _refresh_node_by_id(self, remote_drivewsid, remote_shareid=None):
        data = self.api.drive.get_node_data(remote_drivewsid, remote_shareid)
        return DriveNode(self.api.drive, data)

    def _node_from_entry(self, entry):
        data = {
            "drivewsid": entry["remote_drivewsid"],
            "docwsid": entry.get("remote_docwsid"),
            "etag": entry.get("remote_etag"),
            "zone": entry.get("remote_zone"),
            "shareID": entry.get("remote_shareid"),
            "size": int(entry.get("size", 0) or 0),
            "type": entry.get("type", "file").upper(),
            "name": os.path.basename(entry["path"].rstrip("/")) or "root",
        }
        return DriveNode(self.api.drive, data)

    def _node_to_meta(self, node, path):
        data = node.data
        node_type = data.get("type", "FILE").lower()
        if self._is_directory_type(node_type):
            size = 0
        else:
            size = int(data.get("size", 0) or 0)
        return {
            "path": path,
            "type": node_type,
            "parent_path": os.path.dirname(path) or "/",
            "remote_drivewsid": data.get("drivewsid"),
            "remote_docwsid": data.get("docwsid"),
            "remote_etag": data.get("etag"),
            "remote_zone": data.get("zone"),
            "remote_shareid": data.get("shareID"),
            "size": size,
            "mtime": parse_remote_time(data.get("dateModified")),
        }

    def _entry_conflicts(self, entry, meta):
        return (
            (entry.get("synced_path") and entry["synced_path"] != meta["path"])
            or (entry.get("remote_etag") and entry["remote_etag"] != meta["remote_etag"])
        )

    def _conflict_path(self, path):
        dirname = os.path.dirname(path) or "/"
        basename = os.path.basename(path)
        stamp = datetime.datetime.utcnow().strftime("%Y%m%d%H%M%S")
        return (
            "/" + f"{basename}.local-conflict-{stamp}"
            if dirname == "/"
            else dirname.rstrip("/") + "/" + f"{basename}.local-conflict-{stamp}"
        )

    def _path_allowed(self, path):
        """Return True when a path may be hydrated or synchronized."""
        return path_allowed(path, self.sync_paths, self.exclude_paths)

    def _path_lock(self, path):
        with self.path_locks_lock:
            lock = self.path_locks.get(path)
            if lock is None:
                lock = threading.Lock()
                self.path_locks[path] = lock
            return lock


class ICloudFS(Fuse):
    def __init__(self, *args, **kw):
        super(ICloudFS, self).__init__(*args, **kw)
        self.logger = logging.getLogger("icloud")
        self.username = None
        self.password = None
        self.cache_dir = None
        self.api = None
        self.mirror = None
        self.state = None
        self.sync_engine = None

    def _log_file_op(self, op, path=None, level=logging.INFO, **fields):
        payload = {}
        if path is not None:
            payload["path"] = path
        payload.update(fields)
        details = " ".join(f"{key}={value!r}" for key, value in payload.items() if value is not None)
        if details:
            self.logger.log(level, "file-op %s %s", op, details)
            return
        self.logger.log(level, "file-op %s", op)

    def _mutation_allowed(self, operation, *paths):
        if self.sync_engine is None:
            self._log_file_op(
                operation,
                level=logging.WARNING,
                reason="sync-engine-unavailable",
            )
            return False

        if all(self.sync_engine._path_allowed(path) for path in paths):
            return True

        self._log_file_op(
            operation,
            paths=", ".join(paths),
            level=logging.WARNING,
            reason="path-policy",
        )
        return False

    def shutdown(self):
        if self.sync_engine is not None:
            self.sync_engine.shutdown()

    def request_remote_refresh(self):
        if self.sync_engine is None:
            self.logger.warning("Remote refresh requested before sync engine was initialized")
            return
        self.sync_engine.request_remote_refresh()

    def init_icloud(self, username, password, cache_dir, cookie_dir=None, require_session=True):
        """Initialise iCloud API connection.

        If *require_session* is False (the default when called from the systemd
        service path), an auth failure sets self.api = None and logs a clear
        error rather than crashing the process.  The FUSE layer will return
        EACCES for all operations until a session is restored via
        './icloudctl auth' followed by './icloudctl restart'.
        """
        self.username = username
        self.password = password
        self.cache_dir = cache_dir
        os.makedirs(self.cache_dir, exist_ok=True)
        if cookie_dir:
            os.makedirs(cookie_dir, exist_ok=True)

        try:
            # Resolve Apple account partition (fixes 421 redirect for non-default shards)
            import requests as _req
            _r = _req.post("https://setup.icloud.com/setup/ws/1/validate", json={}, timeout=10)
            _partition = _r.headers.get("x-apple-user-partition")

            self.api = PyiCloudService(username, password,
                                       cookie_directory=cookie_dir,
                                       authenticate=False)
            if _partition:
                self.api._setup_endpoint = (
                    f"https://p{_partition}-setup.icloud.com/setup/ws/1"
                )
            self.api.authenticate()
            if self.api.requires_2fa:
                if sys.stdin.isatty():
                    print("Two-factor authentication required.")
                    code = input("Enter the verification code: ").strip()
                    result = self.api.validate_2fa_code(code)
                    print("Result: %s" % result)
                    if result and not self.api.is_trusted_session:
                        self.api.trust_session()
                else:
                    raise RuntimeError(
                        "2FA required, but no interactive terminal is available. "
                        "Run './icloudctl auth' first to establish a trusted session."
                    )

            if self.api.requires_2sa:
                if sys.stdin.isatty():
                    print("Two-step authentication required.")
                    devices = self.api.trusted_devices
                    for index, device in enumerate(devices):
                        label = device.get("deviceName") or f"SMS to {device.get('phoneNumber', 'unknown')}"
                        print(f"{index}: {label}")
                    selected = int(input("Select device index: ").strip() or "0")
                    device = devices[selected]
                    self.api.send_verification_code(device)
                    code = input("Enter the verification code: ").strip()
                    if not self.api.validate_verification_code(device, code):
                        raise RuntimeError("Failed to verify 2SA code")
                else:
                    raise RuntimeError(
                        "2SA required, but no interactive terminal is available. "
                        "Run './icloudctl auth' first to establish a trusted session."
                    )

            if self.api.requires_2fa or self.api.requires_2sa:
                raise RuntimeError("Additional authentication still required after code verification.")

        except Exception as exc:
            self.logger.error("Failed to connect to iCloud: %s", exc)
            if require_session:
                raise
            # Non-fatal path: park in unauthenticated state.  The FUSE layer
            # will return EACCES for all operations; the service stays up and
            # won't trigger Apple's lockout by crash-looping.
            self.logger.error(
                "Service starting in UNAUTHENTICATED mode.  "
                "Run './icloudctl auth' then './icloudctl restart' to restore access."
            )
            self.api = None

    def _is_authenticated(self):
        """Return True if a live iCloud session is available."""
        return self.api is not None

    def _is_directory_type(self, entry_type):
        """Return True for directory-like entry types, even in offline mode."""
        return entry_type in DIRECTORY_NODE_TYPES

    def init_local_cache(
        self,
        cache_dir,
        warmup_mode,
        conflict_mode,
        upload_interval_seconds,
        remote_refresh_interval_seconds,
        warmup_workers,
        sync_paths=None,
        exclude_paths=None,
        auto_sync=True,
        crawl_mode="lazy",
    ):
        self.mirror = LocalMirror(cache_dir)
        state_path = os.path.join(cache_dir, "state.sqlite3")
        self.state = SyncState(state_path)
        if not self._is_authenticated():
            self.logger.warning(
                "Skipping sync engine start — no iCloud session.  "
                "FUSE will serve cached data read-only until re-authenticated."
            )
            return
        self.sync_engine = ICloudSyncEngine(
            self.api,
            self.mirror,
            self.state,
            self.logger,
            warmup_mode=warmup_mode,
            conflict_mode=conflict_mode,
            upload_interval_seconds=upload_interval_seconds,
            remote_refresh_interval_seconds=remote_refresh_interval_seconds,
            warmup_workers=warmup_workers,
            sync_paths=sync_paths,
            exclude_paths=exclude_paths,
            auto_sync=auto_sync,
            crawl_mode=crawl_mode,
        )
        self.sync_engine.start()

    def getattr(self, path):
        now = int(time.time())
        entry = self.state.get_entry(path) if self.state else None
        attrs = Stat()

        if path == "/":
            try:
                stats = self.mirror.stat_local(path)
                self._apply_os_stat(attrs, stats)
            except Exception:
                attrs.st_mode = stat.S_IFDIR | 0o755
                attrs.st_nlink = 2
                attrs.st_size = 0
                attrs.st_ctime = now
                attrs.st_mtime = now
                attrs.st_atime = now
                attrs.st_uid = os.getuid()
                attrs.st_gid = os.getgid()
            return attrs

        if self.mirror and self.mirror.exists(path):
            stats = self.mirror.stat_local(path)
            self._apply_os_stat(attrs, stats)
            if entry and entry["type"] == "file" and not entry["hydrated"]:
                attrs.st_size = entry["size"]
                attrs.st_mtime = entry["mtime"]
                attrs.st_ctime = entry["mtime"]
            return attrs

        if entry and not entry["tombstone"]:
            is_directory = self._is_directory_type(entry["type"])
            attrs.st_mode = (stat.S_IFDIR | 0o755) if is_directory else (stat.S_IFREG | 0o644)
            attrs.st_nlink = 2 if is_directory else 1
            attrs.st_size = entry["size"]
            attrs.st_ctime = entry["mtime"] or now
            attrs.st_mtime = entry["mtime"] or now
            attrs.st_atime = now
            attrs.st_uid = os.getuid()
            attrs.st_gid = os.getgid()
            return attrs

        # Path sconosciuto localmente. In modalità lazy questo può capitare
        # per accesso diretto (es. apertura di un file senza un `ls` prima
        # della sua cartella — Nautilus stesso normalmente non lo fa, ma
        # altri programmi/`xdg-open`/percorsi digitati a mano sì): proviamo
        # un list_directory una tantum sulla cartella padre prima di
        # arrenderci, così anche un accesso "diretto" funziona come se la
        # cartella fosse già stata sfogliata.
        if (
            self.sync_engine is not None
            and self.sync_engine.crawl_mode == "lazy"
            and self._is_authenticated()
        ):
            parent = os.path.dirname(path) or "/"
            try:
                self.sync_engine.list_directory(parent)
            except Exception as exc:
                self.logger.error("list_directory (fallback getattr) fallita per %s: %s", parent, exc)
            else:
                entry = self.state.get_entry(path)
                if self.mirror.exists(path):
                    stats = self.mirror.stat_local(path)
                    self._apply_os_stat(attrs, stats)
                    if entry and entry["type"] == "file" and not entry["hydrated"]:
                        attrs.st_size = entry["size"]
                        attrs.st_mtime = entry["mtime"]
                        attrs.st_ctime = entry["mtime"]
                    return attrs

        return -errno.ENOENT

    def readdir(self, path, offset):
        if (
            self.sync_engine is not None
            and self.sync_engine.crawl_mode == "lazy"
            and self._is_authenticated()
        ):
            try:
                self.sync_engine.list_directory(path)
            except Exception as exc:
                # Non blocchiamo mai la ls per un errore di rete: si mostra
                # comunque quello che è già presente nel mirror locale.
                self.logger.error("list_directory fallita per %s: %s", path, exc)

        if not self.mirror.exists(path) or not self.mirror.is_dir(path):
            return -errno.ENOENT

        self._log_file_op("readdir", path, level=logging.DEBUG)
        entries = [".", ".."] + sorted(self.mirror.listdir(path))
        for entry in entries:
            yield fuse.Direntry(entry)

    def open(self, path, flags):
        self._log_file_op("open", path, level=logging.DEBUG, flags=flags)
        if flags & (os.O_CREAT | os.O_WRONLY | os.O_RDWR | os.O_APPEND | os.O_TRUNC):
            if not self._is_authenticated() or not self._mutation_allowed("open", path):
                return -errno.EACCES
        if not self.state.get_entry(path):
            if flags & (os.O_CREAT | os.O_WRONLY | os.O_RDWR | os.O_APPEND | os.O_TRUNC):
                return self.create(path, 0o644, flags)
            return -errno.ENOENT

        entry = self.state.get_entry(path)
        if entry and entry["type"] == "file" and not entry["hydrated"] and not entry["dirty"]:
            if not self._is_authenticated() or self.sync_engine is None:
                # No session: serve what we have locally; remote files return EIO
                if not self.mirror.exists(path):
                    self.logger.warning(
                        "Cannot hydrate %s: no iCloud session. Run './icloudctl auth' then restart.", path
                    )
                    return -errno.EIO
                return 0
            try:
                self.sync_engine.ensure_local_file(path)
            except Exception as exc:
                self.logger.error("Failed hydrating on open for %s: %s", path, exc)
                return -errno.EIO
        return 0

    def create(self, path, mode, flags=None):
        if not self._is_authenticated():
            return -errno.EACCES
        if not self._mutation_allowed("create", path):
            return -errno.EACCES
        try:
            self.mirror.create_file(path)
            stats = self.mirror.stat_local(path)
            self.state.upsert_entry(
                {
                    "path": path,
                    "type": "file",
                    "parent_path": os.path.dirname(path) or "/",
                    "size": 0,
                    "mtime": int(stats.st_mtime),
                    "hydrated": True,
                    "dirty": True,
                    "tombstone": False,
                    "synced_path": None,
                }
            )
            self.state.queue_op("create", path)
            self._log_file_op("create", path, mode=oct(mode), flags=flags)
            return 0
        except Exception as exc:
            self.logger.error("Error creating file %s: %s", path, exc)
            return -errno.EIO

    def read(self, path, size, offset):
        entry = self.state.get_entry(path)
        if not entry or entry["type"] != "file" or entry["tombstone"]:
            return -errno.ENOENT

        try:
            if not entry["hydrated"] and not entry["dirty"]:
                if self.sync_engine is None:
                    # No session — cannot hydrate; if placeholder exists it has no data
                    self.logger.warning(
                        "Cannot hydrate %s: no iCloud session. Run './icloudctl auth' then restart.", path
                    )
                    return -errno.EIO
                self.sync_engine.ensure_local_file(path)
            self._log_file_op("read", path, level=logging.DEBUG, size=size, offset=offset)
            return self.mirror.read(path, size, offset)
        except Exception as exc:
            self.logger.error("Error reading %s: %s", path, exc)
            return -errno.EIO

    def write(self, path, buf, offset):
        if not self._is_authenticated():
            return -errno.EACCES
        if not self._mutation_allowed("write", path):
            return -errno.EACCES
        entry = self.state.get_entry(path)
        if entry and not entry["hydrated"] and entry["remote_drivewsid"]:
            try:
                self.sync_engine.ensure_local_file(path)
            except Exception as exc:
                self.logger.error("Failed hydrating before write %s: %s", path, exc)
                return -errno.EIO

        try:
            written = self.mirror.write(path, buf, offset)
            stats = self.mirror.stat_local(path)
            checksum = self.mirror.file_sha256(path)
            if not entry:
                self.state.upsert_entry(
                    {
                        "path": path,
                        "type": "file",
                        "parent_path": os.path.dirname(path) or "/",
                        "size": stats.st_size,
                        "mtime": int(stats.st_mtime),
                        "hydrated": True,
                        "dirty": True,
                        "tombstone": False,
                        "local_sha256": checksum,
                        "synced_path": None,
                    }
                )
            else:
                self.state.mark_dirty(path, stats.st_size, int(stats.st_mtime), 1, checksum)
            self.state.queue_op("update", path)
            self._log_file_op("write", path, size=len(buf), offset=offset, written=written)
            return written
        except Exception as exc:
            self.logger.error("Error writing %s: %s", path, exc)
            return -errno.EIO

    def flush(self, path):
        return 0

    def release(self, path, flags):
        return 0

    def mkdir(self, path, mode):
        if not self._is_authenticated():
            return -errno.EACCES
        if not self._mutation_allowed("mkdir", path):
            return -errno.EACCES
        try:
            self.mirror.ensure_dir(path)
            stats = self.mirror.stat_local(path)
            self.state.upsert_entry(
                {
                    "path": path,
                    "type": "folder",
                    "parent_path": os.path.dirname(path) or "/",
                    "size": 0,
                    "mtime": int(stats.st_mtime),
                    "hydrated": True,
                    "dirty": True,
                    "tombstone": False,
                    "synced_path": None,
                }
            )
            self.state.queue_op("mkdir", path)
            self._log_file_op("mkdir", path, mode=oct(mode))
            return 0
        except Exception as exc:
            self.logger.error("Error creating directory %s: %s", path, exc)
            return -errno.EIO

    def rmdir(self, path):
        if not self._is_authenticated():
            return -errno.EACCES
        if not self._mutation_allowed("rmdir", path):
            return -errno.EACCES
        entry = self.state.get_entry(path)
        if not entry:
            return -errno.ENOENT

        try:
            self.mirror.remove_dir(path)
            if entry["remote_drivewsid"]:
                self.state.mark_tombstone(path)
                self.state.queue_op("delete", path)
            else:
                self.state.remove_subtree(path)
            self._log_file_op("rmdir", path)
            return 0
        except OSError as exc:
            if exc.errno:
                return -exc.errno
            self.logger.error("Error removing directory %s: %s", path, exc)
            return -errno.EIO

    def unlink(self, path):
        if not self._is_authenticated():
            return -errno.EACCES
        if not self._mutation_allowed("unlink", path):
            return -errno.EACCES
        entry = self.state.get_entry(path)
        if not entry:
            return -errno.ENOENT

        try:
            if self.mirror.exists(path):
                self.mirror.remove_file(path)
            if entry["remote_drivewsid"]:
                self.state.mark_tombstone(path)
                self.state.queue_op("delete", path)
            else:
                self.state.remove_entry(path)
            self._log_file_op("unlink", path)
            return 0
        except OSError as exc:
            if exc.errno:
                return -exc.errno
            self.logger.error("Error unlinking %s: %s", path, exc)
            return -errno.EIO

    def rename(self, oldpath, newpath):
        if not self._is_authenticated():
            return -errno.EACCES
        if not self._mutation_allowed("rename", oldpath, newpath):
            return -errno.EACCES
        sync_engine = self.sync_engine
        state = self.state
        if sync_engine is None or state is None:
            return -errno.EACCES
        entry = state.get_entry(oldpath)
        if not entry:
            return -errno.ENOENT

        if sync_engine._is_directory_type(entry["type"]):
            old_root = normalize_icloud_path(oldpath)
            new_root = normalize_icloud_path(newpath)
            for descendant in state._fetch_subtree(old_root):
                source_path = normalize_icloud_path(descendant["path"])
                suffix = source_path[len(old_root) :]
                target_path = normalize_icloud_path(new_root + suffix)
                if not self._mutation_allowed("rename", source_path, target_path):
                    return -errno.EACCES

        try:
            if self.mirror.exists(newpath):
                self.mirror.remove_tree(newpath)
                existing = self.state.get_entry(newpath)
                if existing:
                    if existing["remote_drivewsid"]:
                        self.state.mark_tombstone(newpath)
                    else:
                        self.state.remove_subtree(newpath)
            self.mirror.rename_path(oldpath, newpath)
            self.state.rename_tree(oldpath, newpath, root_dirty=True)
            self.state.queue_op("rename", oldpath, newpath)
            self._log_file_op("rename", oldpath, target_path=newpath)
            return 0
        except Exception as exc:
            self.logger.error("Error renaming %s to %s: %s", oldpath, newpath, exc)
            return -errno.EIO

    def truncate(self, path, length):
        if not self._is_authenticated():
            return -errno.EACCES
        if not self._mutation_allowed("truncate", path):
            return -errno.EACCES
        entry = self.state.get_entry(path)
        if entry and not entry["hydrated"] and entry["remote_drivewsid"]:
            try:
                self.sync_engine.ensure_local_file(path)
            except Exception as exc:
                self.logger.error("Failed hydrating before truncate %s: %s", path, exc)
                return -errno.EIO

        try:
            self.mirror.truncate(path, length)
            stats = self.mirror.stat_local(path)
            checksum = self.mirror.file_sha256(path)
            if not entry:
                self.state.upsert_entry(
                    {
                        "path": path,
                        "type": "file",
                        "parent_path": os.path.dirname(path) or "/",
                        "size": stats.st_size,
                        "mtime": int(stats.st_mtime),
                        "hydrated": True,
                        "dirty": True,
                        "tombstone": False,
                        "local_sha256": checksum,
                        "synced_path": None,
                    }
                )
            else:
                self.state.mark_dirty(path, stats.st_size, int(stats.st_mtime), 1, checksum)
            self.state.queue_op("update", path)
            self._log_file_op("truncate", path, length=length)
            return 0
        except Exception as exc:
            self.logger.error("Error truncating %s: %s", path, exc)
            return -errno.EIO

    def mknod(self, path, mode, dev):
        if not stat.S_ISREG(mode):
            return -errno.ENOSYS
        return self.create(path, mode)

    def utime(self, path, times):
        if not self._is_authenticated():
            return -errno.EACCES
        if not self._mutation_allowed("utime", path):
            return -errno.EACCES
        try:
            if not self.mirror.exists(path):
                return -errno.ENOENT
            atime, mtime = times if times else (time.time(), time.time())
            self.mirror.set_mtime(path, int(mtime))
            stats = self.mirror.stat_local(path)
            if self.state.get_entry(path):
                self.state.mark_dirty(path, stats.st_size, int(stats.st_mtime))
            self._log_file_op("utime", path, atime=int(atime), mtime=int(mtime))
            return 0
        except Exception as exc:
            self.logger.error("Error setting utime for %s: %s", path, exc)
            return -errno.EIO

    def chmod(self, path, mode):
        """Accept Unix mode updates that iCloud Drive cannot persist."""
        if self.state is None or self.state.get_entry(path) is None:
            return -errno.ENOENT
        self._log_file_op("chmod", path, mode=oct(mode), ignored=True)
        return 0

    def chown(self, path, uid, gid):
        """Accept Unix ownership updates that iCloud Drive cannot persist."""
        if self.state is None or self.state.get_entry(path) is None:
            return -errno.ENOENT
        self._log_file_op("chown", path, uid=uid, gid=gid, ignored=True)
        return 0

    def statfs(self):
        stats = self.mirror.statvfs()
        return {
            "f_bsize": stats.f_bsize,
            "f_frsize": stats.f_frsize,
            "f_blocks": stats.f_blocks,
            "f_bfree": stats.f_bfree,
            "f_bavail": stats.f_bavail,
            "f_files": stats.f_files,
            "f_ffree": stats.f_ffree,
            "f_namelen": stats.f_namemax,
        }

    def _apply_os_stat(self, attrs, stats):
        attrs.st_mode = stats.st_mode
        attrs.st_ino = stats.st_ino
        attrs.st_dev = stats.st_dev
        attrs.st_nlink = stats.st_nlink
        attrs.st_uid = stats.st_uid
        attrs.st_gid = stats.st_gid
        attrs.st_size = stats.st_size
        attrs.st_atime = int(stats.st_atime)
        attrs.st_mtime = int(stats.st_mtime)
        attrs.st_ctime = int(stats.st_ctime)


def parse_config(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as handle:
            config = yaml.safe_load(handle) or {}
        return config
    except Exception as exc:
        print(f"Error parsing config file: {exc}")
        sys.exit(1)


def main():
    usage = """
iCloud Linux: Mount iCloud Drive as a FUSE filesystem

%prog [options] mountpoint
"""
    fs = ICloudFS(version="%prog " + fuse.__version__, usage=usage, dash_s_do="setsingle")
    fs.parser.add_option(
        "-c",
        "--config",
        dest="config",
        default=os.path.expanduser("~/.config/icloud-linux/config.yaml"),
        help="Path to config file (default: ~/.config/icloud-linux/config.yaml)",
    )
    fs.parser.add_option("-v", "--debug", dest="debug", action="store_true", help="Enable debug logging")
    fs.parse(errex=1)
    args = fs.cmdline[0]

    log_level = logging.DEBUG if args.debug else logging.INFO
    log_path = os.environ.get("ICLOUD_LOG_PATH", os.path.expanduser("~/.local/state/icloud-linux/icloud.log"))
    os.makedirs(os.path.dirname(log_path), exist_ok=True)

    logging.basicConfig(
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        level=log_level,
        handlers=[logging.StreamHandler(), logging.FileHandler(log_path)],
    )
    logger = logging.getLogger("icloud")
    logging.getLogger("pyicloud.base").addFilter(IgnoreIcdrsWarning())

    config = parse_config(args.config)
    username = config.get("username")
    password = config.get("password")
    if not username or not password:
        logger.error("Username or password not provided in config file")
        sys.exit(1)

    cache_dir = os.path.expanduser(config.get("cache_dir", "~/.cache/icloud-linux"))
    cookie_dir = os.path.expanduser(config.get("cookie_dir", "~/.config/icloud-linux/cookies"))
    warmup_mode = config.get("warmup_mode", "background")
    conflict_mode = config.get("conflict_mode", "copy")
    upload_interval_seconds = int(config.get("upload_interval_seconds", 30))
    remote_refresh_interval_seconds = int(config.get("remote_refresh_interval_seconds", 300))
    warmup_workers = int(config.get("warmup_workers", 1))
    sync_paths = config.get("sync_paths", None)      # list of iCloud paths to hydrate, None=all
    exclude_paths = config.get("exclude_paths", None) # deny-list applied before sync_paths
    auto_sync = bool(config.get("auto_sync", True))   # False = manual sync only via icloudctl sync
    # "lazy" (default): niente crawl ricorsivo, ogni cartella si elenca da
    #   remoto al primo accesso (stile Finder/Files.app su macOS con iCloud
    #   Drive). "full": comportamento storico, crawl completo all'avvio e ad
    #   ogni refresh periodico.
    crawl_mode = config.get("crawl_mode", "lazy")

    # When running under systemd (no TTY) we never want a failed auth to crash
    # the process — that would trigger Restart=on-failure and hammer Apple's
    # lockout threshold.  require_session=True is still the right default for
    # interactive invocations (e.g. debugging from a terminal with -f).
    interactive = sys.stdin.isatty()

    # Register signal handlers BEFORE init_local_cache() so they are live
    # during the reconcile pass (~75s).  Without this, SIGUSR1 arriving during
    # reconcile uses Python's default handler which kills the process.
    atexit.register(fs.shutdown)

    def handle_shutdown(signum, frame):
        logger.info("Received signal %s, shutting down background sync", signum)
        fs.shutdown()
        raise SystemExit(0)

    # SIGUSR1 — on-demand sync/refresh trigger (used by 'icloudctl sync' and 'icloudctl refresh').
    # Queues a one-shot remote crawl in a background thread so the signal
    # handler returns immediately and FUSE keeps serving requests.
    # If sync_engine is not ready yet (still reconciling), queues it to run
    # once the engine is available.
    def handle_sigusr1(signum, frame):
        def _one_shot():
            # Wait up to 120s for the sync engine to be ready after startup
            deadline = time.time() + 120
            while fs.sync_engine is None and time.time() < deadline:
                time.sleep(1)
            if fs.sync_engine is None:
                logger.warning("SIGUSR1: sync engine not available (unauthenticated or startup failed)")
                return
            logger.info("SIGUSR1: starting on-demand remote metadata crawl")
            try:
                fs.sync_engine.initial_scan()
                logger.info("SIGUSR1: on-demand remote metadata crawl complete")
            except Exception as exc:
                logger.error("SIGUSR1: on-demand remote metadata crawl failed: %s", exc)
            finally:
                # Write completion marker so icloudctl sync can detect done.
                state_dir = os.path.expanduser("~/.local/state/icloud-linux")
                os.makedirs(state_dir, exist_ok=True)
                marker = os.path.join(state_dir, "sync_done")
                with open(marker, "w") as fh:
                    fh.write(str(time.time()))

        threading.Thread(target=_one_shot, name="icloud-on-demand-sync", daemon=True).start()

    signal.signal(signal.SIGTERM, handle_shutdown)
    signal.signal(signal.SIGINT, handle_shutdown)
    if hasattr(signal, "SIGUSR1"):
        signal.signal(signal.SIGUSR1, handle_sigusr1)

    fs.init_icloud(username, password, cache_dir, cookie_dir, require_session=interactive)
    fs.init_local_cache(
        cache_dir,
        warmup_mode,
        conflict_mode,
        upload_interval_seconds,
        remote_refresh_interval_seconds,
        warmup_workers,
        sync_paths=sync_paths,
        exclude_paths=exclude_paths,
        auto_sync=auto_sync,
        crawl_mode=crawl_mode,
    )

    try:
        fs.main()
    finally:
        fs.shutdown()


if __name__ == "__main__":
    main()
DRIVERPYEOF

# ---------------------------------------------------------------------
# 0. Installa icloud-linux (https://github.com/IsmaeelAkram/icloud-linux)
#    se non è già clonato, e assicura che icloud.service sia attivo
#    (via `icloudctl quickstart`, che gestisce l'autenticazione e avvia
#    il servizio) PRIMA di procedere con il patching di driver.py e
#    l'installazione dell'estensione di stato Nautilus — quest'ultima non
#    avrebbe nulla da riflettere se il mount iCloud non è ancora su.
# ---------------------------------------------------------------------
ICLOUD_MOUNT_DIR="$HOME/iCloud"

install_icloud_linux() {
    local pkgs=(git fuse libfuse-dev pkg-config python3-venv)
    local missing=()
    local pkg
    for pkg in "${pkgs[@]}"; do
        is_installed "$pkg" || missing+=("$pkg")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        log_info "Installo le dipendenze di icloud-linux: ${missing[*]}..."
        apt_update_once
        sudo apt-get install -y "${missing[@]}"
    else
        log_info "Dipendenze di icloud-linux già installate."
    fi

    if [ -d "$ICLOUD_LINUX_DIR" ]; then
        log_warn "ATTENZIONE: $ICLOUD_LINUX_DIR esiste già ma non contiene driver.py;" \
            "lo lascio invariato invece di clonarci sopra. Verifica manualmente il" \
            "contenuto della cartella, oppure imposta ICLOUD_LINUX_DIR su un altro percorso."
        return 1
    fi

    log_info "Clono icloud-linux in $ICLOUD_LINUX_DIR..."
    git clone https://github.com/IsmaeelAkram/icloud-linux.git "$ICLOUD_LINUX_DIR"
}

if [ ! -f "$DRIVER_PY" ]; then
    log_info "icloud-linux non risulta installato in $ICLOUD_LINUX_DIR: lo installo..."
    install_icloud_linux
fi

if [ -f "$DRIVER_PY" ] && ! systemctl --user is-active --quiet icloud.service 2>/dev/null; then
    log_info "Eseguo 'icloudctl quickstart' (autenticazione iCloud + avvio del servizio)." \
        "Segui le istruzioni a schermo per completare il login."
    (cd "$ICLOUD_LINUX_DIR" && ./icloudctl quickstart "$ICLOUD_MOUNT_DIR")
fi

if [ -f "$DRIVER_PY" ] && ! systemctl --user is-active --quiet icloud.service 2>/dev/null; then
    log_err "icloud.service non risulta attivo dopo il quickstart. Controlla" \
        "'systemctl --user status icloud.service' e i log del servizio, poi" \
        "rilancia questo script. Salto il patching di driver.py e l'estensione Nautilus."
    exit 1
fi

# ---------------------------------------------------------------------
# 1. Installa la versione già patchata di driver.py (elencazione on-demand
#    per cartella), se diversa da quella attualmente su disco.
#
#    Consegnata come FILE COMPLETO, non come .patch: un diff testuale
#    rischierebbe di non applicarsi (fuzz) se la copia di icloud-linux
#    clonata da Antonio fosse anche di poco diversa dalla revisione
#    upstream su cui questa patch è stata generata e testata in questa
#    sessione. Una sostituzione integrale del file, con backup e verifica
#    di sintassi post-copia, è lo stesso pattern già usato altrove in
#    questa ricetta per file di terze parti (es. customize-clock-extension.js
#    per lo screensaver Ken Burns).
# ---------------------------------------------------------------------
if [ ! -f "$DRIVER_PY" ]; then
    log_err "ERRORE: $DRIVER_PY ancora non trovato dopo il tentativo di installazione." \
        "Imposta ICLOUD_LINUX_DIR se il percorso è diverso, oppure clona a mano il" \
        "repository upstream e rilancia questo script."
    exit 1
else
    if cmp -s "$PATCHED_DRIVER_PY" "$DRIVER_PY"; then
        log_info "driver.py risulta già nella versione patchata; salto la copia."
    else
        log_info "Installo la versione patchata (elencazione on-demand) di driver.py..."
        cp "$DRIVER_PY" "$DRIVER_PY.pre-lazy-listing.bak"
        cp "$PATCHED_DRIVER_PY" "$DRIVER_PY"
        if python3 -m py_compile "$DRIVER_PY"; then
            log_info "Sintassi di driver.py patchato verificata (py_compile OK)." \
                "Backup della versione precedente in $DRIVER_PY.pre-lazy-listing.bak"
            RESTART_NEEDED=1
        else
            log_err "ERRORE: driver.py patchato non compila; ripristino il backup."
            cp "$DRIVER_PY.pre-lazy-listing.bak" "$DRIVER_PY"
            exit 1
        fi
    fi

    # -------------------------------------------------------------------
    # 2. Aggiunge crawl_mode: lazy alla config, solo se la chiave non c'è
    #    già (non sovrascrive una scelta esplicita dell'utente, es. "full").
    # -------------------------------------------------------------------
    if [ -f "$CONFIG_YAML" ]; then
        if grep -qE '^\s*crawl_mode\s*:' "$CONFIG_YAML"; then
            log_info "config.yaml ha già una chiave crawl_mode; la lascio invariata."
        else
            log_info "Aggiungo 'crawl_mode: lazy' a $CONFIG_YAML..."
            {
                echo ""
                echo "# Aggiunto da 21-icloud-nautilus-status.sh: elencazione on-demand"
                echo "# per cartella (stile Finder/macOS) invece del crawl ricorsivo"
                echo "# completo all'avvio. Valori possibili: lazy (default) | full."
                echo "crawl_mode: lazy"
            } >> "$CONFIG_YAML"
            RESTART_NEEDED=1
        fi
    else
        log_warn "ATTENZIONE: $CONFIG_YAML non trovato; salto l'aggiunta di crawl_mode" \
            "(verrà comunque usato il default lazy hardcoded in driver.py)."
    fi

    # -------------------------------------------------------------------
    # 3. Riavvia il servizio utente, solo se abbiamo davvero cambiato qualcosa
    # -------------------------------------------------------------------
    if [ "${RESTART_NEEDED:-0}" = "1" ]; then
        if systemctl --user list-unit-files icloud.service > /dev/null 2>&1; then
            log_info "Riavvio icloud.service per applicare le modifiche..."
            systemctl --user restart icloud.service || \
                log_warn "ATTENZIONE: riavvio di icloud.service fallito; riavvialo a mano."
        else
            log_info "icloud.service non risulta registrato per systemd --user;" \
                "riavvia manualmente icloud-linux per applicare le modifiche."
        fi
    fi

    # -------------------------------------------------------------------
    # 3b. Esclude ~/iCloud dall'indicizzazione ricorsiva di Tracker/
    #     localsearch (il "Tracker3 Miner" di GNOME che alimenta la ricerca
    #     di file di Nautilus/Activities).
    #
    #     BUG REALE trovato testando su hardware reale (non riproducibile
    #     nel sandbox di sviluppo, che non ha un ambiente GNOME): dato che
    #     ~/iCloud sta sotto $HOME e org.freedesktop.Tracker3.Miner.Files
    #     indicizza $HOME in modo ricorsivo di default, l'indicizzatore
    #     cammina l'INTERO albero di iCloud Drive e apre il contenuto di
    #     ogni file per indicizzarlo — esattamente come farebbe un utente
    #     che apre ogni cartella e ogni file, ma in automatico e su tutto
    #     l'albero. Per il filesystem FUSE questo è indistinguibile da un
    #     vero utente che sfoglia/apre i file: il risultato è che l'intero
    #     iCloud Drive viene scaricato in background pochi secondi dopo il
    #     mount, vanificando l'elencazione on-demand implementata sopra
    #     (la causa reale dietro alla cartella che sembrava "vuota per
    #     sempre": in realtà stava scaricando tutto, non stava più
    #     elencando pigramente nulla).
    #
    #     Tracker rispetta un marker per-cartella, per-progetto
    #     (impostazione ignored-directories-with-content, default include
    #     ".trackerignore"): un file vuoto con questo nome basta a far
    #     saltare l'intero sottoalbero. Va scritto DIRETTAMENTE nella
    #     cartella "mirror" che fa da backend locale al mount FUSE (non
    #     attraverso ~/iCloud stesso), altrimenti passerebbe per un file
    #     creato dall'utente e finirebbe in coda per l'upload su iCloud.
    # -------------------------------------------------------------------
    CACHE_DIR="$(sed -nE 's/^[[:space:]]*cache_dir[[:space:]]*:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' "$CONFIG_YAML" 2>/dev/null | head -n1)"
    CACHE_DIR="${CACHE_DIR:-$HOME/.cache/icloud-linux}"
    MIRROR_ROOT="$CACHE_DIR/mirror"
    TRACKERIGNORE="$MIRROR_ROOT/.trackerignore"

    # Il mirror locale viene creato dal driver all'avvio (mirror.ensure_dir),
    # non da questo script: se il servizio è appena stato riavviato può
    # volerci un istante prima che la cartella compaia.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -d "$MIRROR_ROOT" ] && break
        sleep 1
    done

    if [ -d "$MIRROR_ROOT" ] && [ ! -f "$TRACKERIGNORE" ]; then
        log_info "Escludo $ICLOUD_MOUNT_DIR dall'indicizzazione di Tracker/localsearch" \
            "(creo $TRACKERIGNORE)..."
        touch "$TRACKERIGNORE"
        # localsearch potrebbe aver già iniziato a camminare l'albero con le
        # regole vecchie (senza il marker): lo riavviamo (è attivato via
        # D-Bus, ripartirà da solo alla prossima occorrenza) così la
        # prossima scansione vede subito il nuovo .trackerignore invece di
        # continuare a scaricare quello che aveva già in coda.
        if pgrep -u "$USER" -f 'localsearch-3|tracker-miner-fs' > /dev/null 2>&1; then
            log_info "Riavvio l'indicizzatore Tracker/localsearch per applicare l'esclusione..."
            pkill -u "$USER" -f 'localsearch-3|tracker-miner-fs' 2>/dev/null || true
        fi
    elif [ ! -d "$MIRROR_ROOT" ]; then
        log_warn "ATTENZIONE: $MIRROR_ROOT non ancora presente; salto l'esclusione da" \
            "Tracker/localsearch. Rilancia questo script una volta che il servizio è" \
            "attivo per applicarla."
    else
        log_info "$ICLOUD_MOUNT_DIR risulta già esclusa dall'indicizzazione di Tracker/localsearch."
    fi
fi

# ---------------------------------------------------------------------
# 4. Installa/aggiorna l'estensione Nautilus di stato
# ---------------------------------------------------------------------
NAUTILUS_EXT_DIR="$HOME/.local/share/nautilus-python/extensions"
mkdir -p "$NAUTILUS_EXT_DIR"
EXT_FILE="$NAUTILUS_EXT_DIR/icloud_status.py"

log_info "Installo/aggiorno l'estensione Nautilus in $EXT_FILE..."
cat > "$EXT_FILE" << 'NAUTILUSEXTEOF'
#!/usr/bin/env python3
"""
icloud_status.py — estensione Nautilus per icloud-linux.

RISCRITTA in questa sessione per il nuovo modello di elencazione on-demand
(crawl_mode: lazy in driver.py): non esiste più un singolo, lungo crawl da
attendere prima del mount, quindi il vecchio meccanismo di placeholder
pre-mount (pensato per un'attesa di minuti/ore) è stato semplificato.

Cosa fa oggi:
  - Tiene d'occhio ~/.local/state/icloud-linux/icloud.log (solo le righe
    nuove ad ogni giro, non rilegge tutto il file).
  - Riconosce questi eventi (emessi da _log_sync in driver.py):
      sync list-directory-start path='...'      -> cartella in esplorazione
      sync list-directory-complete path='...'   -> esplorazione finita
      sync hydrate-start path='...' size=...    -> file in scaricamento
      sync hydrate-complete path='...' ...      -> scaricamento finito
    più il pattern storico (solo rilevante se crawl_mode: full):
      "Timed out enumerating ... skipping folder"
  - Mostra un'etichetta dinamica sul segnalibro "iCloud" nella barra
    laterale (es. "iCloud (esplorando: Documenti)", "iCloud (scaricando:
    fattura.pdf)"), che torna a "iCloud" semplice quando non c'è nulla in
    corso da più di ACTIVITY_WINDOW_SECONDS.
  - Voce di menu "Stato sincronizzazione iCloud…" con il dettaglio
    dell'ultima attività nota.

Cosa NON fa più rispetto alla versione precedente (rimosso perché non più
necessario col mount quasi istantaneo):
  - Il file-placeholder scritto nella cartella di mount prima che il FUSE si
    agganci. Con crawl_mode: lazy il mount avviene in genere in una manciata
    di secondi (basta creare la cartella radice sul mirror), quindi la
    finestra "cartella vuota" che questo placeholder copriva è ormai troppo
    breve per giustificare la complessità — e comunque, se emergesse un caso
    reale in cui serve ancora, si può reintrodurre selettivamente in un
    secondo giro dopo test su hardware.

NON TESTATO su hardware reale in questa sessione: nessun Nautilus/GTK/D-Bus
di sessione reale disponibile nel sandbox in cui è stato scritto. La lettura
e il parsing del log sono stati verificati con file di log sintetici
(vedi test manuale più sotto), non con un vero servizio icloud-linux attivo.
"""

import gi

try:
    gi.require_version("Nautilus", "4.0")
except ValueError:
    # Nautilus può aver già caricato un'altra versione del proprio
    # namespace GI in questo processo — stesso fix già usato altrove
    # nel progetto (nautilus-snapper-restore).
    pass

from gi.repository import Nautilus, GObject, GLib, Gio

import os
import re
import time

LOG_PATH = os.path.expanduser("~/.local/state/icloud-linux/icloud.log")
ICLOUD_MOUNT_DEFAULT = os.path.expanduser("~/iCloud")
POLL_SECONDS = 5
ACTIVITY_WINDOW_SECONDS = 20  # dopo quanto silenzio si torna a "iCloud" semplice
BOOKMARKS_FILE = os.path.expanduser("~/.config/gtk-3.0/bookmarks")

RE_LIST_START = re.compile(r"sync list-directory-start path='([^']*)'")
RE_LIST_DONE = re.compile(r"sync list-directory-complete path='([^']*)'\s*entries=(\d+)")
RE_HYDRATE_START = re.compile(r"sync hydrate-start path='([^']*)'")
RE_HYDRATE_DONE = re.compile(r"sync hydrate-complete path='([^']*)'")
RE_TIMEOUT_SKIP = re.compile(r"Timed out enumerating (\S+) after \d+s")


def _display_name(icloud_path):
    """Da un path assoluto lato iCloud (es. '/Documenti/foo.txt') estrae
    solo l'ultimo componente per un'etichetta breve e leggibile."""
    if not icloud_path or icloud_path == "/":
        return "iCloud"
    return os.path.basename(icloud_path.rstrip("/")) or icloud_path


class ICloudStatusMonitor:
    """Singleton che tiene lo stato corrente e viene aggiornato ogni
    POLL_SECONDS leggendo solo le righe nuove del log."""

    _instance = None

    def __init__(self):
        self._log_pos = 0
        self._last_event_desc = None      # testo umano dell'ultimo evento
        self._last_event_at = 0.0         # timestamp dell'ultimo evento
        self._in_flight = {}               # path -> "listing" | "hydrating"
        self._init_log_position()

    @classmethod
    def instance(cls):
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    def _init_log_position(self):
        # Alla primissima esecuzione partiamo dalla fine del file esistente,
        # per non rileggere (e non mostrare come "attività recente") tutta
        # la storia pregressa del log ad ogni riavvio di Nautilus.
        try:
            self._log_pos = os.path.getsize(LOG_PATH)
        except OSError:
            self._log_pos = 0

    def poll(self):
        try:
            size = os.path.getsize(LOG_PATH)
        except OSError:
            return False  # log non ancora creato: servizio non ancora partito

        if size < self._log_pos:
            # Il log è stato ruotato/troncato: ripartiamo da zero.
            self._log_pos = 0

        changed = False
        if size > self._log_pos:
            with open(LOG_PATH, "r", errors="replace") as fh:
                fh.seek(self._log_pos)
                new_lines = fh.read()
                self._log_pos = fh.tell()
            changed = self._process_lines(new_lines) or changed

        # Anche senza nuove righe, l'etichetta va "scaduta" se è passato
        # troppo tempo dall'ultima attività nota.
        if self._last_event_desc and (time.time() - self._last_event_at) > ACTIVITY_WINDOW_SECONDS:
            self._last_event_desc = None
            changed = True

        return changed

    def _process_lines(self, text):
        changed = False
        now = time.time()
        for line in text.splitlines():
            m = RE_LIST_START.search(line)
            if m:
                path = m.group(1)
                self._in_flight[path] = "listing"
                self._last_event_desc = f"esplorando: {_display_name(path)}"
                self._last_event_at = now
                changed = True
                continue

            m = RE_LIST_DONE.search(line)
            if m:
                path, n = m.group(1), m.group(2)
                self._in_flight.pop(path, None)
                self._last_event_desc = f"{_display_name(path)}: {n} elementi"
                self._last_event_at = now
                changed = True
                continue

            m = RE_HYDRATE_START.search(line)
            if m:
                path = m.group(1)
                self._in_flight[path] = "hydrating"
                self._last_event_desc = f"scaricando: {_display_name(path)}"
                self._last_event_at = now
                changed = True
                continue

            m = RE_HYDRATE_DONE.search(line)
            if m:
                path = m.group(1)
                self._in_flight.pop(path, None)
                self._last_event_desc = f"{_display_name(path)} scaricato"
                self._last_event_at = now
                changed = True
                continue

            m = RE_TIMEOUT_SKIP.search(line)
            if m:
                # Rilevante solo se crawl_mode: full (vedi commento in testa
                # al file); riconosciuto comunque per non perdere il fix già
                # trovato in precedenza per le cartelle KNIME molto annidate.
                path = m.group(1)
                self._last_event_desc = f"cartella lenta, saltata per ora: {_display_name(path)}"
                self._last_event_at = now
                changed = True
                continue

        return changed

    @property
    def status_label_suffix(self):
        """Suffisso da appendere all'etichetta del segnalibro 'iCloud',
        oppure stringa vuota se non c'è nulla di rilevante in corso."""
        if not self._last_event_desc:
            return ""
        return f" ({self._last_event_desc})"

    @property
    def status_menu_text(self):
        if not self._last_event_desc:
            return "iCloud: nessuna attività recente"
        return f"iCloud: {self._last_event_desc}"


def _rewrite_bookmark_label(suffix):
    """Riscrive ~/.config/gtk-3.0/bookmarks aggiornando SOLO la riga del
    segnalibro iCloud, preservando qualunque altra etichetta personalizzata
    l'utente abbia già impostato altrove nel file — stesso approccio già
    verificato funzionante su hardware reale nella versione precedente di
    questo script."""
    mount_uri = "file://" + GLib.uri_escape_string(ICLOUD_MOUNT_DEFAULT, "/", False)
    try:
        with open(BOOKMARKS_FILE, "r") as fh:
            lines = fh.readlines()
    except FileNotFoundError:
        lines = []

    new_lines = []
    found = False
    for line in lines:
        stripped = line.rstrip("\n")
        if stripped.startswith(mount_uri):
            found = True
            new_lines.append(f"{mount_uri} iCloud{suffix}\n")
        else:
            new_lines.append(line)

    if not found:
        new_lines.append(f"{mount_uri} iCloud{suffix}\n")

    os.makedirs(os.path.dirname(BOOKMARKS_FILE), exist_ok=True)
    with open(BOOKMARKS_FILE, "w") as fh:
        fh.writelines(new_lines)


class ICloudStatusExtension(GObject.GObject, Nautilus.MenuProvider, Nautilus.InfoProvider):
    def __init__(self):
        super().__init__()
        self._monitor = ICloudStatusMonitor.instance()
        GLib.timeout_add_seconds(POLL_SECONDS, self._on_tick)

    def _on_tick(self):
        if self._monitor.poll():
            _rewrite_bookmark_label(self._monitor.status_label_suffix)
        return True  # continua a ripetersi

    # --- Nautilus.MenuProvider ---------------------------------------
    def get_file_items(self, files):
        return []

    def get_background_items(self, current_folder):
        item = Nautilus.MenuItem(
            name="ICloudStatusExtension::status",
            label="Stato sincronizzazione iCloud…",
            tip="Mostra l'ultima attività nota di icloud-linux",
        )
        item.connect("activate", self._show_status, current_folder)
        return [item]

    def _show_status(self, menu_item, current_folder):
        # Notifica desktop minimale invece di una finestra di dialogo GTK
        # completa: sufficiente per "vedere cosa sta succedendo adesso"
        # senza costruire una UI dedicata solo per questo.
        try:
            Gio.Notification.new  # solo per verificare disponibilità import
            notif = Gio.Notification.new("iCloud")
            notif.set_body(self._monitor.status_menu_text)
            app = Gio.Application.get_default()
            if app is not None:
                app.send_notification("icloud-status", notif)
        except Exception:
            pass  # in assenza di un'app GApplication attiva, non blocchiamo nulla

    # --- Nautilus.InfoProvider ----------------------------------------
    def update_file_info(self, file):
        return Nautilus.OperationResult.COMPLETE
NAUTILUSEXTEOF

log_info "Estensione Nautilus installata. Riavvio Nautilus per ricaricarla..."
nautilus -q > /dev/null 2>&1 || true

log_info "Fatto."
