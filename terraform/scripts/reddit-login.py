#!/usr/bin/env python3
"""
Log the fixed Camofox identity ("hermes-reddit") into Reddit.

Safe to run any time you suspect Reddit access is broken — it checks
whether the persisted session is still valid FIRST, and only attempts a
fresh login if it actually isn't. Running it defensively/repeatedly does
not risk extra login attempts against Reddit's fraud detection.

Runnable both from the host (via SSH) and from inside Claudiano/Barbero's
own sandbox (the container mounts this same repo at the same path):

    python3 /opt/hermes-deploy/terraform/scripts/reddit-login.py

Reads REDDIT_USERNAME/REDDIT_PASSWORD from a narrow, Reddit-only
credentials file — NOT from /tmp/hermes-deploy.env or any other shared
deploy-secrets file. Those files hold every credential in this
deployment (Discord tokens, R2 keys, email password, API keys) and must
never be read to debug a Reddit problem. If this script can't find its
credentials file, that's the bug to report — not a reason to go looking
in a broader one.
"""
import json
import re
import sys
import time
import urllib.request

CRED_FILES = [
    "/opt/data/.reddit-credentials",       # as seen from inside the hermes container
    "/root/.hermes/.reddit-credentials",   # as seen from the host
]
BASE = "http://127.0.0.1:9377"
CAMOFOX_USER_ID = "hermes-reddit"
LOGGED_IN_MARKERS = ("Expand user menu", "Settings - Account")


def load_credentials():
    for path in CRED_FILES:
        try:
            env = {}
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    key, _, value = line.partition("=")
                    env[key.strip()] = value.strip()
            username = env.get("REDDIT_USERNAME", "")
            password = env.get("REDDIT_PASSWORD", "")
            if username and password:
                return username, password
        except FileNotFoundError:
            continue
    print("No REDDIT_USERNAME/REDDIT_PASSWORD found in:", ", ".join(CRED_FILES))
    print("Do not fall back to /tmp/hermes-deploy.env — fix the credentials file instead.")
    sys.exit(1)


def call(method, path, body=None):
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def find_ref(snapshot, label):
    m = re.search(rf'"{re.escape(label)}"[^\[]*\[(e\d+)\]', snapshot)
    return m.group(1) if m else None


def is_logged_in(snapshot_text):
    return any(marker in snapshot_text for marker in LOGGED_IN_MARKERS)


def check_existing_session():
    tab = call("POST", "/tabs", {
        "userId": CAMOFOX_USER_ID,
        "sessionKey": "reddit-login",
        "url": "https://www.reddit.com/settings/",
    })
    tab_id = tab["tabId"]
    time.sleep(2)
    snap = call("GET", f"/tabs/{tab_id}/snapshot?userId={CAMOFOX_USER_ID}")
    call("DELETE", f"/tabs/{tab_id}?userId={CAMOFOX_USER_ID}")
    return is_logged_in(snap["snapshot"])


def perform_login(username, password):
    tab = call("POST", "/tabs", {
        "userId": CAMOFOX_USER_ID,
        "sessionKey": "reddit-login",
        "url": "https://www.reddit.com/login/",
    })
    tab_id = tab["tabId"]
    time.sleep(2)

    snap = call("GET", f"/tabs/{tab_id}/snapshot?userId={CAMOFOX_USER_ID}")
    user_ref = find_ref(snap["snapshot"], "Email or username")
    pass_ref = find_ref(snap["snapshot"], "Password")
    login_ref = find_ref(snap["snapshot"], "Log In")

    if not (user_ref and pass_ref and login_ref):
        print("ERROR: could not find login form fields in snapshot")
        print(snap["snapshot"][:1000])
        call("DELETE", f"/tabs/{tab_id}?userId={CAMOFOX_USER_ID}")
        sys.exit(1)

    call("POST", f"/tabs/{tab_id}/type", {"userId": CAMOFOX_USER_ID, "ref": user_ref, "text": username})
    call("POST", f"/tabs/{tab_id}/type", {"userId": CAMOFOX_USER_ID, "ref": pass_ref, "text": password})
    call("POST", f"/tabs/{tab_id}/click", {"userId": CAMOFOX_USER_ID, "ref": login_ref})
    time.sleep(3)

    call("POST", f"/tabs/{tab_id}/navigate", {"userId": CAMOFOX_USER_ID, "url": "https://www.reddit.com/settings/"})
    time.sleep(2)
    check = call("GET", f"/tabs/{tab_id}/snapshot?userId={CAMOFOX_USER_ID}")
    call("DELETE", f"/tabs/{tab_id}?userId={CAMOFOX_USER_ID}")

    if is_logged_in(check["snapshot"]):
        print("Reddit login OK — session persisted under Camofox userId:", CAMOFOX_USER_ID)
    else:
        print("WARNING: could not confirm login succeeded, check manually")
        sys.exit(1)


def main():
    if check_existing_session():
        print("Already logged in — session under Camofox userId", CAMOFOX_USER_ID, "is still valid. Nothing to do.")
        return

    print("Session not valid, logging in...")
    username, password = load_credentials()
    perform_login(username, password)


if __name__ == "__main__":
    main()
