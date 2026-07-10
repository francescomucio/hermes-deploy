#!/usr/bin/env python3
"""
Log the fixed Camofox identity ("hermes-reddit" — shared across sites,
not Reddit-specific despite the name) into Blind (teamblind.com).

Unlike Reddit, Blind is blocked at the CDN edge (CloudFront) by IP
reputation, not by an auth wall — reachable from a real browser on the
operator's home IP, not from this server's datacenter IP directly. That
means this script only works when BOTH of these are true:

  1. The operator has the home-IP SOCKS5 tunnel running
     (`ssh -R 1080 root@<server-ip> -N`, see README).
  2. Camofox is currently launched with PROXY_HOST=127.0.0.1
     PROXY_PORT=1080 pointed at that tunnel (not the default — Camofox
     normally runs unproxied, since most sites don't need it and a
     dead tunnel would otherwise break every navigation. Recreating
     the container with the proxy vars is an operator action, not
     something Claudiano/Barbero can do themselves — no Docker access).

Safe to run any time, including speculatively: it checks whether the
persisted session is already valid before attempting anything, and
checks whether Blind is even reachable before trying to log in, so a
misfire here fails with a clear, correct explanation instead of a
confusing timeout or blank form.

    python3 /opt/hermes-deploy/terraform/scripts/blind-login.py

Reads BLIND_USERNAME/BLIND_PASSWORD from a narrow, Blind-only
credentials file — never from /tmp/hermes-deploy.env or any other
shared deploy-secrets file.
"""
import json
import re
import sys
import time
import urllib.request

CRED_FILES = [
    "/opt/data/.blind-credentials",
    "/root/.hermes/.blind-credentials",
]
BASE = "http://127.0.0.1:9377"
CAMOFOX_USER_ID = "hermes-reddit"
BLOCKED_MARKERS = ("Oops! Something went wrong", "blindapp@teamblind.com")
LOGGED_IN_MARKERS = ("Write a Post", "Account Menu")


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
            username = env.get("BLIND_USERNAME", "")
            password = env.get("BLIND_PASSWORD", "")
            if username and password:
                return username, password
        except FileNotFoundError:
            continue
    print("No BLIND_USERNAME/BLIND_PASSWORD found in:", ", ".join(CRED_FILES))
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


def is_blocked(snapshot_text):
    return any(marker in snapshot_text for marker in BLOCKED_MARKERS)


def is_logged_in(snapshot_text):
    return any(marker in snapshot_text for marker in LOGGED_IN_MARKERS)


def open_homepage():
    tab = call("POST", "/tabs", {
        "userId": CAMOFOX_USER_ID,
        "sessionKey": "blind-login",
        "url": "https://www.teamblind.com/",
    })
    tab_id = tab["tabId"]
    time.sleep(4)
    snap = call("GET", f"/tabs/{tab_id}/snapshot?userId={CAMOFOX_USER_ID}")
    return tab_id, snap["snapshot"]


def main():
    tab_id, snapshot = open_homepage()

    if is_blocked(snapshot):
        call("DELETE", f"/tabs/{tab_id}?userId={CAMOFOX_USER_ID}")
        print("Blind is blocking this request (CloudFront IP-reputation block).")
        print("This means the operator's home-IP tunnel isn't active, or Camofox")
        print("isn't currently proxied through it — not something fixable from")
        print("here. Ask the operator to start the tunnel and re-proxy Camofox.")
        sys.exit(1)

    if is_logged_in(snapshot):
        call("DELETE", f"/tabs/{tab_id}?userId={CAMOFOX_USER_ID}")
        print("Already logged in — session under Camofox userId", CAMOFOX_USER_ID, "is still valid. Nothing to do.")
        return

    # Cookie consent dialog blocks the sign-in button on a fresh session.
    agree_ref = find_ref(snapshot, "AGREE")
    if agree_ref:
        call("POST", f"/tabs/{tab_id}/click", {"userId": CAMOFOX_USER_ID, "ref": agree_ref})
        time.sleep(2)
        snapshot = call("GET", f"/tabs/{tab_id}/snapshot?userId={CAMOFOX_USER_ID}")["snapshot"]

    signin_ref = find_ref(snapshot, "Sign in")
    if not signin_ref:
        print("ERROR: could not find the Sign in button")
        print(snapshot[:1000])
        call("DELETE", f"/tabs/{tab_id}?userId={CAMOFOX_USER_ID}")
        sys.exit(1)

    call("POST", f"/tabs/{tab_id}/click", {"userId": CAMOFOX_USER_ID, "ref": signin_ref})
    time.sleep(2)
    snapshot = call("GET", f"/tabs/{tab_id}/snapshot?userId={CAMOFOX_USER_ID}")["snapshot"]

    user_ref = find_ref(snapshot, "Email or Login ID")
    pass_ref = find_ref(snapshot, "Password")
    submit_ref = find_ref(snapshot, "Sign in")

    if not (user_ref and pass_ref and submit_ref):
        print("ERROR: could not find login form fields in snapshot")
        print(snapshot[:1000])
        call("DELETE", f"/tabs/{tab_id}?userId={CAMOFOX_USER_ID}")
        sys.exit(1)

    username, password = load_credentials()
    call("POST", f"/tabs/{tab_id}/type", {"userId": CAMOFOX_USER_ID, "ref": user_ref, "text": username})
    call("POST", f"/tabs/{tab_id}/type", {"userId": CAMOFOX_USER_ID, "ref": pass_ref, "text": password})
    call("POST", f"/tabs/{tab_id}/click", {"userId": CAMOFOX_USER_ID, "ref": submit_ref})
    time.sleep(3)

    check = call("GET", f"/tabs/{tab_id}/snapshot?userId={CAMOFOX_USER_ID}")
    call("DELETE", f"/tabs/{tab_id}?userId={CAMOFOX_USER_ID}")

    if is_logged_in(check["snapshot"]):
        print("Blind login OK — session persisted under Camofox userId:", CAMOFOX_USER_ID)
    else:
        print("WARNING: could not confirm login succeeded, check manually")
        sys.exit(1)


if __name__ == "__main__":
    main()
