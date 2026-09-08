"""Seed Calibre-Web's SMTP password from the Vault-backed secret, on every start.

Calibre-Web keeps the password Fernet-encrypted in /config/app.db, under the key
in /config/.key. When the two disagree it does not complain: cps/config_sql.py
catches InvalidToken and sets the field to "", and cps/tasks/mail.py then skips
SMTP AUTH entirely (`if self.settings["mail_password_e"]:`), so every send is
refused by the mailserver.

The 2025-11-30 migration to calibre-web-automated hit exactly that: app.db came
across from the old /mnt/main/calibre config directory, the hidden .key did not,
and "Send to Kindle" failed silently until 2026-08-21.

Running this before Calibre-Web starts makes the secret the single source of
truth, so a key that goes missing again is repaired on the next restart rather
than turning into another silent outage. It is idempotent: when the stored value
already decrypts to the secret, nothing is written.
"""

import os
import sqlite3
import sys

from cryptography.fernet import Fernet, InvalidToken

# Overridable only so the branches below can be exercised against a throwaway
# copy of app.db; Calibre-Web always reads /config.
CONFIG_DIR = os.environ.get("CWA_CONFIG_DIR", "/config")
DB_PATH = os.path.join(CONFIG_DIR, "app.db")
KEY_PATH = os.path.join(CONFIG_DIR, ".key")
LOG_PREFIX = "[seed-smtp-password]"


def log(message):
    print("%s %s" % (LOG_PREFIX, message), flush=True)


def load_or_create_key():
    """Return the Fernet key Calibre-Web will load.

    Mirrors cps/config_sql.py get_encryption_key(): a file over 32 bytes that
    base64-decodes is reused, anything else is regenerated. Creating it here when
    absent keeps the write below encrypted under the key the app then picks up,
    instead of racing it.
    """
    if os.path.exists(KEY_PATH) and os.path.getsize(KEY_PATH) > 32:
        return open(KEY_PATH, "rb").read()
    key = Fernet.generate_key()
    with open(KEY_PATH, "wb") as handle:
        handle.write(key)
    log("no usable /config/.key found; generated one")
    return key


def main():
    password = os.environ.get("SMTP_PASSWORD", "")
    if not password:
        log("SMTP_PASSWORD is empty — leaving the stored value alone")
        return 0

    if not os.path.exists(DB_PATH):
        log("no app.db yet (fresh volume); Calibre-Web will create it and the "
            "next start seeds the password")
        return 0

    fernet = Fernet(load_or_create_key())
    connection = sqlite3.connect(DB_PATH)
    try:
        try:
            row = connection.execute("select mail_password_e from settings").fetchone()
        except sqlite3.OperationalError as exc:
            log("settings table not readable (%s); skipping" % exc)
            return 0

        if row is None:
            log("no settings row yet; skipping")
            return 0

        stored = row[0]
        if stored:
            token = stored if isinstance(stored, bytes) else stored.encode()
            try:
                if fernet.decrypt(token).decode() == password:
                    log("stored password already matches the secret; no change")
                    return 0
                log("stored password differs from the secret; rewriting")
            except InvalidToken:
                log("stored password cannot be decrypted with the current "
                    "/config/.key — this is the failure mode that silently "
                    "disabled SMTP AUTH; rewriting")
        else:
            log("no stored password; writing")

        connection.execute(
            "update settings set mail_password_e = ?", (fernet.encrypt(password.encode()),)
        )
        connection.commit()
        log("mail_password_e re-encrypted under the current /config/.key")
        return 0
    finally:
        # Close cleanly so SQLite checkpoints and removes app.db-wal/-shm rather
        # than leaving them behind for Calibre-Web to inherit.
        connection.close()


if __name__ == "__main__":
    sys.exit(main())
