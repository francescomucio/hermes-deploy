---
name: work-email
description: "Read/send Mucio's WORK email (mucio@untitleddata.company) via Gmail API. Never the personal Gmail."
version: 1.0.0
author: hermes-deploy
metadata:
  hermes:
    tags: [email, gmail, work, untitled-data]
---

# Work Email (Gmail API)

Access to Mucio's **work** mailbox: `mucio@untitleddata.company`, via Google's OAuth Gmail API.

## The golden rule — two mailboxes, two tools

| Mailbox | Tool | Auth |
|---|---|---|
| `mucio@untitleddata.company` (WORK) | Gmail API (`google_api.py`) | OAuth token |
| `francescomucio@gmail.com` (PERSONAL) | `himalaya` | IMAP app password |

**Never mix them.** The Gmail API is wired to the WORK account only. The personal Gmail is
reachable only through himalaya. If asked about a personal email, use himalaya; if asked about
work, use the Gmail API. Do not try to reach the work inbox through himalaya or vice versa.

## Setup (already done — this is what makes it work)

The OAuth token lives at `$HERMES_HOME/google_token.json` and auto-refreshes. For a named
profile `$HERMES_HOME` is the profile dir (e.g. `/opt/data/profiles/researcher`), and the token
is a **symlink** to the deployment-wide token at `/opt/data/google_token.json`. If the token
ever goes missing for this profile, that symlink is what needs recreating:

```bash
ln -sfn /opt/data/google_token.json "$HERMES_HOME/google_token.json"
ln -sfn /opt/data/google_client_secret.json "$HERMES_HOME/google_client_secret.json"
```

(The deploy recreates these automatically at boot — see `terraform/scripts/setup-hermes.sh`.)

## Usage

**Use an explicit interpreter.** Confirmed live: bare `python3` in a profile session resolves to
`/usr/bin/python3`, which does NOT have `google-api-python-client` and fails with
`ModuleNotFoundError`. Use one of these instead — both have the libs and both were verified
working against the work mailbox:

```bash
PY=/opt/hermes/.venv/bin/python3        # preferred (Hermes venv)
PY=/opt/data/.venv-google/bin/python    # fallback (dedicated google venv)

GAPI="$PY $HERMES_HOME/skills/productivity/google-workspace/scripts/google_api.py"

$GAPI gmail search "is:unread" --max 10
$GAPI gmail search "from:sohohouse.com newer_than:7d"
$GAPI gmail get MESSAGE_ID
```

Do NOT waste turns discovering this: `python3` alone fails, `$PY` works.

Health check before trusting an empty result:

```bash
$GAPI gmail search "is:unread" --max 1
```

An auth failure prints `Not authenticated` — that means the token symlink is missing.

## Reading a full message + attachments

The CLI's `gmail get` returns an empty `body` for HTML-only messages. For the real text
(and attachments), use the Python API directly:

```python
import base64
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
import os
creds = Credentials.from_authorized_user_file(os.path.join(os.environ["HERMES_HOME"], "google_token.json"))
s = build('gmail','v1',credentials=creds)
m = s.users().messages().get(userId='me', id='MESSAGE_ID', format='full').execute()
def walk(p, out):
    if p.get('body',{}).get('data'):
        out.append(base64.urlsafe_b64decode(p['body']['data']).decode('utf-8','replace'))
    for c in p.get('parts',[]) or []:
        walk(c, out)
out=[]; walk(m['payload'], out)
print("\n".join(out)[:4000])
```

Attachments: walk the payload for parts with `filename` + `body.attachmentId`, then
`s.users().messages().attachments().get(...)` and base64-decode.

## Sending — NEVER without a draft shown first

Composing and sending are possible (`$GAPI gmail send ...`, `$GAPI gmail reply MID --body ...`),
but **never send an email without showing Mucio the draft and getting explicit confirmation.**
This applies to every profile in this deployment. Read the thread first, draft, present, wait.

## Pitfalls

- `gmail search` returns an empty `body` field by design — use the Python snippet above.
- Empty results are not proof of an empty inbox; run the health check first.
- The token is a symlink: `ls -la "$HERMES_HOME/google_token.json"` should show it pointing at
  `/opt/data/google_token.json`. A regular file here means the symlink was replaced.
