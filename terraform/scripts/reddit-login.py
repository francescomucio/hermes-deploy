#!/usr/bin/env python3
"""
Log Barbero's Camofox browser identity into Reddit.

Run this manually (via SSH) if the persisted Reddit session ever gets
invalidated (Reddit security check, cookie expiry, etc.):

    python3 /opt/hermes-deploy/terraform/scripts/reddit-login.py

Reads REDDIT_USERNAME/REDDIT_PASSWORD from /tmp/hermes-deploy.env (the same
file every other deploy script sources), so it works standalone without
re-running the whole terraform apply. Uses the same fixed Camofox userId
(CAMOFOX_USER_ID) that config.yaml's browser.camofox.user_id points Hermes
at, so the resulting session is exactly what Barbero's browser_navigate
calls reuse.
"""
import json
import re
import sys
import time
import urllib.request

ENV_FILE = "/tmp/hermes-deploy.env"
BASE = "http://127.0.0.1:9377"
CAMOFOX_USER_ID = "hermes-reddit"


def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            env[key.strip()] = value.strip()
    return env


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


def main():
    env = load_env(ENV_FILE)
    username = env.get("REDDIT_USERNAME", "")
    password = env.get("REDDIT_PASSWORD", "")
    if not username or not password:
        print("REDDIT_USERNAME/REDDIT_PASSWORD not set in", ENV_FILE)
        sys.exit(1)

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
        sys.exit(1)

    call("POST", f"/tabs/{tab_id}/type", {"userId": CAMOFOX_USER_ID, "ref": user_ref, "text": username})
    call("POST", f"/tabs/{tab_id}/type", {"userId": CAMOFOX_USER_ID, "ref": pass_ref, "text": password})
    call("POST", f"/tabs/{tab_id}/click", {"userId": CAMOFOX_USER_ID, "ref": login_ref})
    time.sleep(3)

    call("POST", f"/tabs/{tab_id}/navigate", {"userId": CAMOFOX_USER_ID, "url": "https://www.reddit.com/settings/"})
    time.sleep(2)
    check = call("GET", f"/tabs/{tab_id}/snapshot?userId={CAMOFOX_USER_ID}")

    call("DELETE", f"/tabs/{tab_id}?userId={CAMOFOX_USER_ID}")

    if "Expand user menu" in check["snapshot"] or "Settings - Account" in check["snapshot"]:
        print("Reddit login OK — session persisted under Camofox userId:", CAMOFOX_USER_ID)
    else:
        print("WARNING: could not confirm login succeeded, check manually")
        sys.exit(1)


if __name__ == "__main__":
    main()
