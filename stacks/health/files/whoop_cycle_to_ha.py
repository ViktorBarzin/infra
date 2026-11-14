"""whoop-cycle-to-ha: Anca's menstrual cycle anchor from WHOOP into ha-london.

WHOOP's public developer API has no menstrual data, so this reads the private
endpoint the WHOOP phone app itself uses (see whoop_cycle_to_ha.tf for the
background and the ban-risk trade-off). It runs ONCE A DAY, so a period Anca
logs in the app reaches ha-london within a day: one token refresh, one read.

Each run reads today's Menstrual Cycle Insights and writes four persisted HA
helpers on ha-london:

  input_datetime.anca_cycle_start     day 1 of the current cycle (today - (cycle_day-1))
  input_number.anca_cycle_length      her typical cycle length, days
  input_number.anca_period_length     her typical period length, days
  input_datetime.anca_cycle_last_sync when this job last ran

A template sensor in packages/anca_cycle.yaml advances the phase and cycle day
LOCALLY from those helpers every day, so the phase stays current even when a
daily read fails. Helpers persist across HA restarts;
transient /api/states sensors do not, which is why this uses helpers.

Recovery, HRV and sleep reach ha-london separately, through the official API
and the HACS integration prankstr/hassio-whoop.

WHOOP emails a 6-digit login code (EMAIL_OTP) on each password login. The job
answers it automatically: it reads the code from Anca's Gmail over IMAP,
completes the login, then deletes the code email. To keep that email to about
once a month, the job saves WHOOP's refresh token (valid ~30 days) in the
Kubernetes Secret SESSION_SECRET and signs in with it on later days. Only when
it is missing or expired does the job fall back to the password + code login. GMAIL_USER / GMAIL_APP_PASSWORD are a Gmail
app password (needs 2-Step Verification on her Google account); it grants broad
mailbox access, so it is stored in Vault and only the WHOOP code email is touched.

Env: WHOOP_EMAIL, WHOOP_PASSWORD, WHOOP_INSTALLATION_ID, HA_URL, HA_TOKEN,
     GMAIL_USER, GMAIL_APP_PASSWORD,
     SESSION_SECRET (optional; Secret in the pod's namespace that holds the
       refresh token; unset = no reuse, every run logs in with a code),
     JITTER_SECONDS (optional, default 3600; 0 disables).
"""
import base64
import datetime as dt
import email
import email.utils
import html
import imaplib
import os
import random
import re
import sys
import time
import uuid

import requests

WHOOP = "https://api.prod.whoop.com"
AUTH_URL = f"{WHOOP}/auth-service/v3/whoop/"
CYCLE_PATH = "/womens-health-service/v1/menstrual-cycle-insights"
TIMEOUT = 30

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
SESSION_KEY = "refresh_token"

IMAP_HOST = "imap.gmail.com"
# WHOOP's login-code emails come from a whoop.com address; match loosely on the
# From header so a sender rename doesn't break us.
OTP_SENDER_SUBSTR = "whoop"
OTP_WAIT_ATTEMPTS = 24   # 24 * 5s = up to 2 min for the email to arrive
OTP_WAIT_INTERVAL = 5

# The WHOOP iOS app's own request identity (app 5.52.0). The data endpoints
# accept a bare bearer token, but sending what the app sends keeps these
# requests looking like the app's rather than like the one client that omits
# the x-whoop-* headers.
COGNITO_USER_AGENT = "aws-sdk-swift/1.5.86 ua/2.1 api/cognito_identity_provider#1.5.86 os/ios#26.3.1 lang/swift#5.10 m/D,N,Z,b"
APP_HEADERS = {
    "user-agent": "iOS",
    "x-whoop-device-platform": "iOS",
    "x-whoop-ios-version": "5.52.0",
    "x-whoop-ios-build-number": "595097",
    "x-whoop-bundle-name": "com.whoop.iphone",
    "x-whoop-time-zone": "Europe/London",
    "locale": "en_US",
    "accept-language": "en",
    "accept": "*/*",
}


def _cognito(session: requests.Session, target: str, body: dict) -> dict:
    resp = session.post(
        AUTH_URL,
        json=body,
        headers={
            "content-type": "application/x-amz-json-1.1",
            "x-amz-target": f"AWSCognitoIdentityProviderService.{target}",
            "amz-sdk-request": "attempt=1; max=1",
            "amz-sdk-invocation-id": str(uuid.uuid4()),
            "user-agent": COGNITO_USER_AGENT,
            "accept": "*/*",
        },
        timeout=TIMEOUT,
    )
    if resp.status_code != 200:
        raise RuntimeError(f"WHOOP {target} failed ({resp.status_code}): {resp.text[:200]}")
    return resp.json()


OTP_CHALLENGES = {
    "EMAIL_OTP": "EMAIL_OTP_CODE",
    "SMS_MFA": "SMS_MFA_CODE",
    "SOFTWARE_TOKEN_MFA": "SOFTWARE_TOKEN_MFA_CODE",
}


def _visible_text(body: str) -> str:
    """Reduce an HTML (or plain) email body to its visible text, so codes hidden
    in attributes are dropped: a WHOOP code email is HTML-only and its decoy
    6-digit runs live in a CSS color (#000000) and AWS tracking URLs, while the
    real code is visible text between tags."""
    body = re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", body)
    body = re.sub(r"(?s)<[^>]+>", " ", body)
    return html.unescape(body)


def extract_otp(text: str) -> str | None:
    """Pull the 6-digit login code out of a WHOOP email (body may be HTML).
    Reads visible text only, then skips trivial decoys (a single repeated or
    two-value pattern like 000000 / 010101) before taking the first code."""
    visible = _visible_text(text)
    candidates = re.findall(r"(?<!\d)\d{6}(?!\d)", visible)
    non_trivial = [c for c in candidates if len(set(c)) >= 3]
    pool = non_trivial or candidates
    return pool[0] if pool else None


def _whoop_otp_uids(imap: imaplib.IMAP4_SSL, since: dt.datetime) -> list:
    """INBOX message numbers from WHOOP on/after `since`'s date."""
    typ, data = imap.search(None, "SINCE", since.strftime("%d-%b-%Y"))
    return data[0].split() if data and data[0] else []


def fetch_otp_code(user: str, app_password: str, since: dt.datetime) -> str:
    """Return the WHOOP login code that arrived after `since` in the user's
    Gmail. Does NOT delete anything (deletion waits until the login succeeds, so
    a wrong parse never destroys the one good email). Polls, as delivery lags."""
    for _ in range(OTP_WAIT_ATTEMPTS):
        with imaplib.IMAP4_SSL(IMAP_HOST) as imap:
            imap.login(user, app_password)
            imap.select("INBOX")
            best = None  # (received, code)
            for num in reversed(_whoop_otp_uids(imap, since)):
                typ, msg_data = imap.fetch(num, "(RFC822)")
                if typ != "OK" or not msg_data or not isinstance(msg_data[0], tuple):
                    continue
                msg = email.message_from_bytes(msg_data[0][1])
                if OTP_SENDER_SUBSTR not in str(msg.get("From", "")).lower():
                    continue
                recv = email.utils.parsedate_to_datetime(msg.get("Date", ""))
                if recv is None or recv < since - dt.timedelta(minutes=1):
                    continue
                code = extract_otp(str(msg.get("Subject", "")) + " " + _email_text(msg))
                if code and (best is None or recv > best[0]):
                    best = (recv, code)
            if best is not None:
                return best[1]
        time.sleep(OTP_WAIT_INTERVAL)
    raise RuntimeError(f"no WHOOP login code in {user} since {since.isoformat(timespec='seconds')}")


def delete_otp_emails(user: str, app_password: str, since: dt.datetime) -> int:
    """Move WHOOP sign-in-code emails (on/after `since`'s date) to Gmail Trash.
    Runs after a successful login, so the code email is gone once used; sweeps
    up any decoys that accumulated too. Best-effort: never fails the run."""
    moved = 0
    try:
        with imaplib.IMAP4_SSL(IMAP_HOST) as imap:
            imap.login(user, app_password)
            imap.select("INBOX")
            for num in _whoop_otp_uids(imap, since):
                typ, msg_data = imap.fetch(num, "(RFC822)")
                if typ != "OK" or not msg_data or not isinstance(msg_data[0], tuple):
                    continue
                msg = email.message_from_bytes(msg_data[0][1])
                frm = str(msg.get("From", "")).lower()
                subj = str(msg.get("Subject", "")).lower()
                if OTP_SENDER_SUBSTR not in frm or "sign-in code" not in subj:
                    continue
                # Gmail: adding the \Trash label removes the message from INBOX
                # and actually trashes it (auto-purged after 30 days), unlike a
                # bare \Deleted+expunge, which only archives it.
                try:
                    imap.store(num, "+X-GM-LABELS", "\\Trash")
                    moved += 1
                except imaplib.IMAP4.error:
                    imap.store(num, "+FLAGS", "\\Deleted")
            try:
                imap.expunge()
            except imaplib.IMAP4.error:
                pass
    except Exception as exc:  # cleanup must never fail the job
        print(f"warning: could not clean up OTP emails: {exc}")
    return moved


def _email_text(msg: email.message.Message) -> str:
    parts = []
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() in ("text/plain", "text/html"):
                payload = part.get_payload(decode=True)
                if payload:
                    parts.append(payload.decode(part.get_content_charset() or "utf-8", "ignore"))
    else:
        payload = msg.get_payload(decode=True)
        if payload:
            parts.append(payload.decode(msg.get_content_charset() or "utf-8", "ignore"))
    return " ".join(parts)


def authenticate(session: requests.Session, email_addr: str, password: str,
                 otp_getter) -> tuple[str, str | None]:
    """Return (access token, refresh token) for a password login, answering an
    emailed login code if asked.
    `otp_getter()` is called only when WHOOP issues an OTP challenge, so no email
    is read on a login that WHOOP lets through directly."""
    body = _cognito(session, "InitiateAuth", {
        "AuthFlow": "USER_PASSWORD_AUTH",
        "AuthParameters": {"USERNAME": email_addr, "PASSWORD": password},
        "ClientId": "",
    })
    if body.get("AuthenticationResult"):
        result = body["AuthenticationResult"]
        return result["AccessToken"], result.get("RefreshToken")

    challenge = body.get("ChallengeName")
    code_key = OTP_CHALLENGES.get(challenge)
    if not code_key:
        raise RuntimeError(f"WHOOP login returned an unhandled challenge: {challenge}")
    if not body.get("Session"):
        raise RuntimeError("WHOOP OTP challenge carried no Session token")

    code = otp_getter()
    resp = _cognito(session, "RespondToAuthChallenge", {
        "ClientId": "",
        "ChallengeName": challenge,
        "Session": body["Session"],
        "ChallengeResponses": {"USERNAME": email_addr, code_key: code},
    })
    if not resp.get("AuthenticationResult"):
        raise RuntimeError(f"WHOOP rejected the login code; challenge={resp.get('ChallengeName')}")
    result = resp["AuthenticationResult"]
    return result["AccessToken"], result.get("RefreshToken")


def refresh_tokens(session: requests.Session, refresh_token: str) -> tuple[str, str] | None:
    """Exchange a saved refresh token for (access token, refresh token), or None
    if WHOOP no longer accepts it. WHOOP's proxy fills in ClientId and
    SECRET_HASH, so only the token is sent. Cognito usually keeps the same
    refresh token; a rotated one is returned so the caller can save it."""
    try:
        body = _cognito(session, "InitiateAuth", {
            "AuthFlow": "REFRESH_TOKEN_AUTH",
            "AuthParameters": {"REFRESH_TOKEN": refresh_token},
            "ClientId": "",
        })
    except RuntimeError as exc:
        print(f"saved WHOOP sign-in not accepted ({exc}); logging in with a code")
        return None
    result = body.get("AuthenticationResult") or {}
    if not result.get("AccessToken"):
        return None
    return result["AccessToken"], result.get("RefreshToken") or refresh_token


def sign_in(session: requests.Session, email_addr: str, password: str, store, otp_getter) -> str:
    """Return a WHOOP access token. Uses the refresh token in `store` when WHOOP
    still accepts it, so no login-code email is sent; otherwise logs in with
    password + emailed code and saves the new refresh token."""
    saved = store.load()
    if saved:
        tokens = refresh_tokens(session, saved)
        if tokens:
            access, refresh = tokens
            if refresh != saved:
                store.save(refresh)
            print("signed in with the saved WHOOP refresh token")
            return access
    access, refresh = authenticate(session, email_addr, password, otp_getter)
    if refresh:
        store.save(refresh)
    print("signed in with password + login code; saved the new refresh token")
    return access


def token_from_secret(secret: dict) -> str | None:
    raw = (secret.get("data") or {}).get(SESSION_KEY)
    if not raw:
        return None
    return base64.b64decode(raw).decode() or None


def secret_patch_body(token: str) -> dict:
    return {"data": {SESSION_KEY: base64.b64encode(token.encode()).decode()}}


class KubeSecretStore:
    """The refresh token, kept in a Secret in this pod's namespace. The pod's
    ServiceAccount may only get and patch that one Secret."""

    def __init__(self, name: str):
        with open(f"{SA_DIR}/namespace", encoding="utf-8") as fh:
            namespace = fh.read().strip()
        with open(f"{SA_DIR}/token", encoding="utf-8") as fh:
            self._headers = {"Authorization": f"Bearer {fh.read().strip()}"}
        host = os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc")
        port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
        self._url = f"https://{host}:{port}/api/v1/namespaces/{namespace}/secrets/{name}"

    def load(self) -> str | None:
        resp = requests.get(self._url, headers=self._headers, verify=f"{SA_DIR}/ca.crt", timeout=TIMEOUT)
        resp.raise_for_status()
        return token_from_secret(resp.json())

    def save(self, token: str) -> None:
        resp = requests.patch(
            self._url, json=secret_patch_body(token), verify=f"{SA_DIR}/ca.crt", timeout=TIMEOUT,
            headers={**self._headers, "Content-Type": "application/merge-patch+json"},
        )
        resp.raise_for_status()


class NoStore:
    """No saved sign-in (local runs): every run logs in with a code."""

    def load(self) -> None:
        return None

    def save(self, token: str) -> None:
        pass


def fetch_cycle(session: requests.Session, token: str, date: str, installation_id: str) -> dict:
    resp = session.get(
        WHOOP + CYCLE_PATH,
        params={"date": date, "apiVersion": "7"},
        headers={**APP_HEADERS, "x-whoop-installation-identifier": installation_id, "authorization": f"Bearer {token}"},
        timeout=TIMEOUT,
    )
    resp.raise_for_status()
    return resp.json()


def _tile(raw: dict, tile_type: str) -> dict:
    for tile in raw.get("tiles") or []:
        if isinstance(tile, dict) and tile.get("type") == tile_type:
            content = tile.get("content")
            return content if isinstance(content, dict) else {}
    return {}


def _int(value: object) -> int | None:
    match = re.search(r"\d+", str(value)) if value is not None else None
    return int(match.group()) if match else None


def _stat(raw: dict, title: str) -> int | None:
    for stat in _tile(raw, "TYPICAL_CYCLE_TILE").get("stats") or []:
        if isinstance(stat, dict) and title in str(stat.get("title_display", "")).upper():
            return _int(stat.get("value_display"))
    return None


def project(raw: dict, date: str) -> dict:
    """Reduce the app's tile response to the anchor fields HA needs."""
    header = _tile(raw, "HEADER_TILE")
    subtitle = header.get("subtitle_display")
    style = header.get("style")
    if isinstance(subtitle, str) and subtitle:
        phase = re.sub(r"\s*phase$", "", subtitle, flags=re.IGNORECASE)
    elif isinstance(style, str) and style:
        phase = style.title()
    else:
        phase = None

    calendar = _tile(raw, "CALENDAR_TILE").get("calendar") or {}
    days = calendar.get("days_of_month") or [] if isinstance(calendar, dict) else []

    def next_start(phase_name: str) -> str | None:
        starts = [
            d["date"] for d in days
            if isinstance(d, dict) and d.get("first_day_of_phase") is True
            and d.get("phase") == phase_name and isinstance(d.get("date"), str) and d["date"] >= date
        ]
        return min(starts, default=None)

    return {
        "phase": phase,
        "cycle_day": _int(header.get("title_display")),
        "cycle_length": _stat(raw, "CYCLE LENGTH"),
        "period_length": _stat(raw, "PERIOD LENGTH"),
        "next_period": next_start("MENSTRUAL"),
        "ovulation": next_start("OVULATORY"),
    }


def cycle_start_date(cycle: dict, today: dt.date) -> dt.date | None:
    """Day 1 of the current cycle, inferred from today's cycle day."""
    if cycle["cycle_day"] is None:
        return None
    return today - dt.timedelta(days=cycle["cycle_day"] - 1)


def phase_for_day(cycle_day: int, cycle_length: int, period_length: int) -> str:
    """Map a cycle day to a phase. MUST stay in step with the identical
    arithmetic in packages/anca_cycle.yaml, which advances the phase daily.
    Luteal is the ~14 days before the next period, so ovulation sits at
    cycle_length - 14; menstrual spans the period, follicular the days
    between, with a 1-day window around ovulation."""
    cl = max(cycle_length, 1)
    day = ((cycle_day - 1) % cl) + 1
    ovulation_day = max(cl - 14, period_length + 1)
    if day <= period_length:
        return "Menstrual"
    if abs(day - ovulation_day) <= 1:
        return "Ovulatory"
    if day < ovulation_day:
        return "Follicular"
    return "Luteal"


def helper_calls(cycle: dict, today: dt.date, now_iso: str) -> list[tuple[str, dict]]:
    """(service_path, payload) pairs that write the persisted HA helpers.
    A None field is skipped so a sparse response never clears a good helper."""
    calls: list[tuple[str, dict]] = []
    start = cycle_start_date(cycle, today)
    if start is not None:
        calls.append(("input_datetime/set_datetime",
                      {"entity_id": "input_datetime.anca_cycle_start", "date": start.isoformat()}))
    if cycle["cycle_length"] is not None:
        calls.append(("input_number/set_value",
                      {"entity_id": "input_number.anca_cycle_length", "value": cycle["cycle_length"]}))
    if cycle["period_length"] is not None:
        calls.append(("input_number/set_value",
                      {"entity_id": "input_number.anca_period_length", "value": cycle["period_length"]}))
    calls.append(("input_datetime/set_datetime",
                  {"entity_id": "input_datetime.anca_cycle_last_sync", "datetime": now_iso}))
    return calls


def main() -> int:
    env = os.environ
    jitter = int(env.get("JITTER_SECONDS", "3600"))
    if jitter > 0:
        delay = random.randint(0, jitter)
        print(f"jitter: sleeping {delay}s before contacting WHOOP")
        time.sleep(delay)

    now = dt.datetime.now(dt.UTC)
    today = now.date()
    login_started = now  # the OTP email must be newer than this
    store = KubeSecretStore(env["SESSION_SECRET"]) if env.get("SESSION_SECRET") else NoStore()
    code_emailed = []

    def otp_getter() -> str:
        code_emailed.append(True)
        return fetch_otp_code(env["GMAIL_USER"], env["GMAIL_APP_PASSWORD"], login_started)

    try:
        with requests.Session() as session:
            token = sign_in(session, env["WHOOP_EMAIL"], env["WHOOP_PASSWORD"], store, otp_getter)
            cycle = project(fetch_cycle(session, token, today.isoformat(), env["WHOOP_INSTALLATION_ID"]), today.isoformat())
            print(f"{today}: {cycle}")
            for service_path, payload in helper_calls(cycle, today, now.isoformat(timespec="seconds")):
                resp = session.post(
                    f"{env['HA_URL']}/api/services/{service_path}",
                    json=payload,
                    headers={"Authorization": f"Bearer {env['HA_TOKEN']}"},
                    timeout=TIMEOUT,
                )
                resp.raise_for_status()
    finally:
        # A code was emailed, so trash it and any decoys, even if a later step failed.
        if code_emailed:
            moved = delete_otp_emails(env["GMAIL_USER"], env["GMAIL_APP_PASSWORD"], login_started)
            print(f"cleaned up {moved} WHOOP sign-in-code email(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
