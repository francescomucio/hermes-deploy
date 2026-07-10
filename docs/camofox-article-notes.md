# Notes: Camofox + home-IP routing for Hermes

Source material for an article. This is the "why," in the order things actually happened —
the README's "Camofox Browser Automation" section is the terse reference version of the same
story. Written from a single long debugging/build session; timestamps and exact error strings
are real, taken directly from logs during the work.

Open questions for you are flagged inline with **[ASK: ...]** and collected again at the end.

---

## 1. The problem we started with

Hermes runs two research-oriented Discord bot personas — Claudiano (default) and Barbero
(researcher profile, styled after historian Alessandro Barbero) — that rely on web search to do
their jobs. Search was wired to [SearXNG](https://github.com/searxng/searxng), a self-hosted
metasearch aggregator, running as a container on the same Hetzner VPS as everything else.

The symptom that kicked this off: Barbero's searches against Google and Reddit were failing.
Google served CAPTCHA challenges. Reddit served a hard block: *"You've been blocked by network
security. To continue, log in to your Reddit account or use your developer token."*

**[ASK: what was the actual research task that surfaced this? I recall "RTO Berlin" / "return to
office" queries and a SumUp-related Blind post coming up during testing — was there a specific
project driving the need for working Reddit access, worth naming in the article?]**

The working hypothesis going in: both blocks were IP-reputation based. Hetzner IP ranges are
well-known datacenter space, and search engines/social platforms increasingly treat datacenter
IPs as presumptively automated traffic. The fix, in theory: make Hermes' outbound requests exit
from a residential IP instead — specifically, the user's home internet connection.

This turned out to be **half right**. It explains Google's behavior well. It does not explain
Reddit's — more on that below.

---

## 2. Part one: routing through the home IP

### The naive first idea, and why it was wrong

The first instinct was: install a second SSH server *inside* the Hermes container, so the user's
laptop could open a reverse SOCKS tunnel directly into it. This turned out to be unnecessary
complexity, discovered by actually reading the container's networking config rather than
assuming.

**Discovery**: `nousresearch/hermes-agent`'s own `docker-compose.yml` (upstream, not something
this deploy repo added) already runs the `gateway` service — the container Claudiano/Barbero
live in — with `network_mode: host`. It shares the host's network namespace entirely, rather
than getting its own isolated Docker network. `searxng` was *also* set to host networking, in
this deploy repo, 16 days before this session (commit `bc30f5d`, for the practical reason that
gateway being host-networked meant searxng could reach it — and vice versa — over plain
`127.0.0.1` without setting up a Docker bridge network).

Given that, the second-sshd idea evaporated: **the host already has a normal, working sshd**
(port 22, already open in the Hetzner firewall, already how the deploy pipeline connects). Since
gateway shares the host's network namespace, anything bound to the host's `127.0.0.1` is
directly visible to Claudiano/Barbero's process — no container-to-container networking needed at
all.

### The actual mechanism: OpenSSH reverse dynamic forwarding

The tool: `ssh -R <port>` with **no destination** (just a bare port number, not `port:host:port`).
Supported since OpenSSH 7.6 (2017), this is different from a normal `-R` forward — instead of
tunneling to one fixed destination, it turns the *client* end into a full SOCKS5 proxy. Run from
the laptop:

```bash
ssh -R 1080 root@<server-ip> -N
```

This opens `127.0.0.1:1080` on the **server** as a SOCKS5 proxy that tunnels every connection
back through the laptop's own internet connection. Anything on the server that connects through
that port appears, to the outside world, to be browsing from the laptop's home IP. No public IP
or router port-forward needed on the laptop side — it's an outbound connection the laptop
initiates, same direction as any other SSH session.

Why this over a commercial residential proxy service: zero cost, zero new vendor, and the whole
project's ethos so far had been "self-hosted, no third-party paid dependencies" (Hetzner + R2 +
open-source tools). A commercial proxy was never seriously considered.

**Verification method used**: compare the server's direct outbound IP against the IP seen
through the tunnel, via `curl ifconfig.me` and `curl -x socks5://127.0.0.1:1080 ifconfig.me`.
Two visibly different IPv6 addresses confirmed the tunnel was doing real work, not silently
falling through.

### Wiring it into SearXNG

SearXNG supports per-engine outbound proxy overrides. Added to the `google` (and originally
`reddit`, later removed — see part 3) engine entries in its generated `settings.yml`:

```yaml
engines:
  - name: google
    engine: google
    shortcut: g
    proxies:
      all://:
        - socks5://127.0.0.1:1080
```

### A real bug along the way: `socks5h://` vs `socks5://`

The first attempt used `socks5h://` (the curl/requests convention for "let the proxy do DNS
resolution"), copied directly from SearXNG's own documentation example. It silently failed —
SearXNG's proxy config was simply never applied, and requests kept going out the server's own
IP, with no error surfaced anywhere.

Root cause, found by testing the exact `httpx_socks`/`python_socks` library SearXNG uses,
in-process, against the running container:

```
ValueError: Invalid scheme component: socks5h
```

The specific version of `python_socks` bundled in this SearXNG image doesn't recognize the `h`
suffix at all — only `socks5://`. Switching the scheme fixed it immediately, verified by the same
before/after IP comparison as above.

**Lesson for the article, if useful**: an officially-documented config value silently not
working, with no error surfaced anywhere in the application's own logs, is a very easy trap.
The only way this got caught was by reproducing the exact failing call directly against the
exact library version in use, rather than trusting the docs.

---

## 3. Part two: why the proxy fix wasn't enough on its own

This is the part that turned "install a proxy" into "build a whole second browsing subsystem."

### Google: proxy helped, but SearXNG's approach still failed

Even after the `socks5h`→`socks5` fix, live-testing SearXNG's `google` engine (via its own API,
`/search?q=test&engines=google&format=json`) returned:

```
searx.exceptions.SearxEngineCaptchaException: CAPTCHA (suspended_time=3600)
```

Same result querying *through* the working proxy. Conclusion: Google's bot detection isn't
purely IP-reputation based. SearXNG's `google` engine is a plain `httpx` HTTP client — no real
browser, no JavaScript execution, no cookies, no realistic TLS/header fingerprint. Google can (and
evidently does) flag that pattern independent of source IP.

### Reddit: not an IP problem at all

Tested directly: `curl -x socks5://127.0.0.1:1080` (confirmed working, home IP) against
`reddit.com/r/berlin/search.json` still returned the same block, and the exact response body
was telling:

```
You've been blocked by network security. To continue, log in to your Reddit account or use
your developer token.
```

That's an authentication requirement, not a reputation block — confirmed by testing the same
URL with a plain browser User-Agent through the working home-IP proxy and getting identical
results. Reddit's public JSON search API (`reddit.com/search.json`, what SearXNG's built-in
`reddit` engine uses) now hard-requires either a logged-in session or an OAuth developer token,
regardless of where the request originates. This matches Reddit's public messaging about
locking down previously-open endpoints.

**This reframed the whole task.** "Route through home IP" was necessary but not sufficient for
either target. What was actually needed: a **real browser** (for Google — something that looks
human, JS execution, cookies, realistic fingerprint) and a **real login session** (for Reddit —
no proxy fixes an auth wall).

---

## 4. Part three: choosing Camofox

### The landscape

Hermes Agent ships a full browser-automation toolset with multiple pluggable backends:

- **Camofox** (self-hosted, Firefox-based anti-detection fork)
- **Browserbase / Browser Use / Firecrawl** (paid cloud browser providers)
- **`/browser connect`** (attach to a real Chrome/Brave/Edge instance) — explicitly documented
  as CLI-only, not usable from a Discord/gateway bot, so ruled out immediately for this use case
- **Local `agent-browser` + plain Chromium** — the fallback with no config, but just a normal
  headless Chromium with no stealth patches; would likely get flagged by the same detection that
  blocks SearXNG's plain HTTP client

### Why Camofox specifically

Researched via GitHub activity rather than took the docs' word for it:

- 7,527 stars, 777 forks, actively maintained (pushed within the last month at time of
  research), created ~6 months prior — fast organic growth
- Comparing engineering activity inside `hermes-agent`'s own repo: dozens of substantive Camofox
  feature PRs (cookie import, VNC, persistent sessions, download capture) vs. cloud-provider
  activity that was almost entirely bug-fixes/warning-suppression, not new capability — a proxy
  for "which backend does the community actually use and invest in"
- Self-hosted, zero marginal cost, consistent with the rest of the deployment's philosophy
- Fingerprint spoofing happens at the **C++ level** inside a real Firefox build — not a
  JS-injected stealth shim (which is itself a detectable fingerprint), which was the whole
  weakness of SearXNG's plain-HTTP approach

Rejected: cloud providers (new paid vendor, unnecessary given a working self-hosted option);
plain local Chromium (no stealth, likely to get flagged the same way SearXNG did).

**[ASK: is the "why Camofox, comparing GitHub activity as a signal of real-world community
usage vs. reading docs" angle something you want foregrounded in the article, or was that more
an implementation detail not worth the word count?]**

---

## 5. Part four: why Camofox is its own container

Not part of `docker-compose.override.yml` alongside `gateway`/`dashboard`/`searxng` — it's a
fully standalone `docker run`, its own image, its own lifecycle. Reasoning:

1. **Different build model.** `gateway` and `searxng` both use pre-built, published images
   (`nousresearch/hermes-agent:v2026.6.19`, `searxng/searxng:latest`) — pulled, not built.
   Camofox needed `git clone` + local patching + `docker build` (see part six) — a materially
   different deploy shape that didn't fit the "pull an image" pattern the rest of the compose
   file follows.
2. **Independent resource profile.** Camofox does lazy browser launch + idle shutdown
   (~40MB idle per its own docs, verified: real usage sits around a few hundred MB only while
   actively driving a page). Coupling its lifecycle to `docker compose up -d` would mean it
   restarts every time *any* compose service changes, for no reason.
3. **Isolation of blast radius.** This container needed rebuilding five separate times during
   the debugging session (part six). Being fully separate meant every rebuild/patch cycle never
   touched `gateway` — Claudiano/Barbero's uptime was untouched by any of the Camofox iteration,
   except where explicitly discussed.
4. **Reachability without new attack surface.** Because `gateway` already runs on
   `network_mode: host` (see part one), and Camofox was *also* put on `network_mode: host` (for
   reasons in part six), the two containers can talk over plain `127.0.0.1` with **zero new
   firewall rules or port-publish flags** — same trick used for the SSH tunnel. No Docker bridge
   network, no explicit `--link`, nothing exposed beyond the host's own loopback.

---

## 6. Part five: how the Terraform setup made this iteration possible

This deploy repo's Terraform structure was deliberately built (in an earlier session, not this
one) around one principle stated directly in `cloud-init.yaml`'s own comment: *"Minimal
cloud-init: only install Docker. Everything else is handled by remote-exec scripts so changes
don't trigger a server rebuild."*

Why that mattered here specifically: Hetzner Cloud rebuilds the entire server from scratch if
`user_data` (cloud-init) changes — a genuinely destructive, slow operation. Every single
Camofox patch, every proxy config change, every container-networking fix touched only
`terraform/scripts/setup-hermes.sh` (a remote-exec script), never `cloud-init.yaml`. That meant
five rebuild-and-redeploy cycles in one session without ever risking the box itself.

### The idempotent-script discipline

Patches are written to run every time the script executes and the container needs
(re-)creating — not gated behind a "first install only" check — specifically so they self-heal
if `/opt/camofox-browser` already existed from before a given patch was added. This is a general
pattern already used elsewhere in the script (e.g. the `browser` toolset enablement checks
`grep -q '^- browser$' ... || sed -i ...` before inserting, so re-running never duplicates it).

### A real ordering bug this surfaced

Config corrections (enabling the `browser` toolset, setting the model, etc.) were originally
applied in `setup-hermes.sh`, via `docker exec hermes sed -i ... config.yaml`. But
`restore-backup.sh` — a *separate* script that runs immediately afterward as part of the same
Terraform resource — does an R2 restore that overwrites `config.yaml` wholesale. Any edit made
in `setup-hermes.sh` before that point gets silently reverted the moment the restore runs. This
had apparently never surfaced before because the *existing* config corrections (model,
`base_url`) had already been baked into every prior R2 backup, so restoring them was a no-op —
it only became visible the first time a genuinely *new* config value (`browser` in the toolset
list) was added and immediately overwritten by its own deploy's restore step.

Fix: move all config.yaml corrections into `restore-backup.sh`, after the restore, not before it
in a different script. Small structural lesson: **in a system with an backup/restore step,
config mutations need to happen after the restore, not before, or they get silently discarded.**

**[ASK: want the backup/R2 cleanup story (178K files → 32K, `--delete-excluded`, the
`flock`-based race-condition fix between cron backups and deploy-triggered restores) included as
a full section, or just this one paragraph of relevant background? It's a real, separate thread
of work from the same session, tangential to Camofox itself but it's *why* redeploys got fast
enough to iterate on Camofox rapidly in the second half of the session — the first Camofox
redeploy took ~20 minutes for the restore step alone; by the fourth or fifth, it was under 5.]**

---

## 7. Part six: the Camofox bug-hunting saga

The pinned version (`135.0.1-beta.24`, the project's own Makefile default — not an old version
picked by mistake) had real, currently-unfixed bugs, every one of them gated behind
`if (os.platform() === 'linux')` in the source. Working hypothesis, based on the project's own
"runs half on your Mac" branding: the maintainer's day-to-day testing is probably macOS-based,
where this code path never executes — which would explain how bugs this severe (breaks *every*
browser launch) can sit unfixed for months with multiple community PRs open against them.

Six patches total, applied via `sed` directly against the cloned source before `docker build`:

**1. Missing `await` on an async call.**
```js
// before
vdDisplay = localVirtualDisplay.get();
// after
vdDisplay = await localVirtualDisplay.get();
```
`VirtualDisplay.get()` returns a Promise; without `await`, the Promise object itself gets
stringified into the `DISPLAY` environment variable passed to the browser process:
`Error: cannot open display: [object Promise]`. Every browser launch failed outright. Confirmed
as a known, widely-hit bug — a GitHub issue search turned up more than a dozen open, unmerged
duplicate PRs proposing this exact one-line fix.

**2. Incompatible viewport field (two call sites).**
```js
// before
viewport: { width: 1280, height: 720 }
// after
viewport: null
```
Explicit viewport dimensions implicitly set `isMobile: false` in the resulting browser context
config — a field this specific Camoufox build's protocol schema doesn't recognize:
```
Found property "<root>.viewport.isMobile" - false which is not described in this scheme
```
Every tab creation failed with a 500. This one *did* have a proposed upstream fix (PR #6447,
unmerged) for both call sites — matched exactly.

**3. The same bug, a third time, in the health probe.**
Camofox runs a periodic self-health-check every ~3 minutes: `browser.newContext()`, no arguments
at all. Same root cause as #2 — Camoufox's own *default* context still carries the offending
`isMobile` field even with zero explicit options. When the health check failed, Camofox
force-restarted the entire browser process, killing every in-flight tab — including, memorably,
an in-progress Reddit login attempt mid-session. This one had no existing code fix upstream (a
different PR's *documentation* named the exact symptom and remedy — "Health Probe Constantly
Failing... apply viewport: null to ALL context creations" — but never shipped the actual code
change for this specific call site). Patched directly:
```js
testContext = await browser.newContext({ viewport: null });
```

**4. Proxy scheme hardcoded to HTTP.**
```js
// lib/proxy.js, before
server: `http://${host}:${port}`,
// after
server: `socks5://${host}:${port}`,
```
Camofox's documented `PROXY_HOST`/`PROXY_PORT` env vars only ever construct an `http://` proxy
URL — there's no way to specify a SOCKS5 proxy through the documented interface at all, even
though the underlying Playwright library supports `socks5://` natively. Since the home-IP tunnel
(part one) is unavoidably SOCKS5 — that's the only mode OpenSSH's reverse dynamic forwarding
supports — the documented proxy config simply couldn't work with our setup as shipped.

**5. GeoIP verification treated a network hiccup as fatal.**
Setting a proxy automatically triggers Camofox's GeoIP feature (auto-matching browser locale/
timezone/geolocation to the proxy's apparent location — a nice touch for fingerprint realism).
It works by querying up to six external "what's my IP" services *through* the proxy
(`api.ipify.org`, `checkip.amazonaws.com`, `ipinfo.io`, `icanhazip.com`, `ifconfig.co`,
`ipecho.net`) and treats it as a hard launch-blocking error if literally all six fail:
```
Failed to get a public proxy IP address from any API endpoint.
```
Whether this was a transient reachability issue with those specific services through the tunnel,
or something about the library's HTTP client (`Impit`) not handling this particular SOCKS5 setup
correctly, wasn't fully root-caused — the pragmatic fix was to skip GeoIP auto-detection
entirely (`geoip: false` at both call sites), since it's cosmetic fingerprint polish, not
required for the actual goal (getting real traffic to exit via the home IP, which was already
independently verified working via direct `curl`/browser IP-check tests).

**6. Loopback binding, once host networking was needed.**
This last one isn't an upstream bug at all — it's a consequence of a separate architectural fix.
Getting the proxy to actually work required realizing that `127.0.0.1` *inside* the Camofox
container meant the *container's own* loopback, not the host's — because unlike `gateway`/
`searxng`, Camofox was running on Docker's normal bridge networking (its own network namespace),
not `network_mode: host`. `PROXY_HOST=127.0.0.1` was reaching for nothing — hence
`NS_ERROR_PROXY_CONNECTION_REFUSED` from Firefox itself, a *different* error from all the ones
above, that only appeared once the first five patches were already in place and the "real"
underlying networking problem was the last thing standing. Switching Camofox to
`--network host` fixed it (see part four) — but host networking removes Docker's own
per-container port isolation, so as a defense-in-depth measure (redundant with the Hetzner
cloud firewall only allowing port 22 inbound, but cheap insurance), the app's own `express`
server was patched to bind explicitly to `127.0.0.1` instead of the default all-interfaces bind:
```js
// before
const server = app.listen(PORT, async () => { ... });
// after
const server = app.listen(PORT, '127.0.0.1', async () => { ... });
```

### A practical side-lesson: disk space

Each rebuilt image was ~3.68GB. Iterating through five rebuild cycles without cleaning up
between them once filled the server's disk entirely mid-build (`no space left on device`,
93% used, 2.6GB free) — Camofox's container had already been removed by an earlier
recreate-for-missing-volume check by that point, leaving *zero* working browser automation until
the disk issue was resolved. Recovery: `docker rmi` on superseded tags, `docker builder prune`,
retag the last-known-good image as canonical rather than always rebuilding from scratch. Later
rebuilds used `docker cp` to hot-patch a running container's files and `docker restart` — much
cheaper than a full `--no-cache` rebuild — reserving full rebuilds for consolidating everything
into one clean, properly-tagged image at the end.

---

## 8. Part seven: getting Reddit to actually work end-to-end

Camofox alone (real browser, no proxy) got past general Reddit page blocks — a manual test
login succeeded on the very first try, no CAPTCHA, real authenticated session (`/settings/`
page loaded with genuine account data). But that raised the actual remaining question: how does
an *unattended* agent maintain a login, and where do credentials live?

### Design

- **Fixed Camofox identity.** Camofox scopes cookies/sessions to a `userId` string. Rather than
  let Hermes generate a random one per task (the default), `browser.camofox.user_id` in
  `config.yaml` is pinned to a constant (`hermes-reddit`), so every `browser_navigate` call from
  Barbero reuses the exact same logged-in identity instead of starting fresh each time.
- **Persistent storage, survives redeploys.** Camofox's own cookie/session state
  (`~/.camofox/profiles/`) is bind-mounted to `/opt/camofox-data` on the host — without this, a
  container recreation (which happens on nearly every redeploy) would silently wipe the login.
- **Credentials**: a dedicated *throwaway* Reddit account (explicitly not a personal one),
  stored in `terraform.tfvars` — the same gitignored-secrets file every other credential in this
  deploy already lives in (Discord tokens, email password, R2 keys). Considered and rejected:
  GitHub repo secrets — this project has no CI/CD pipeline that would ever read them; everything
  deploys from a local `terraform apply`, so they'd just sit unused.
- **Recovery script** (`terraform/scripts/reddit-login.py`): drives the actual login form via
  Camofox's REST API — create tab, snapshot the page to find form field refs *by accessible
  name* (not hardcoded ref IDs, which change on every page load), type credentials, click
  submit, verify by checking for authenticated-only page content. Runs automatically on a fresh
  Camofox install; re-runnable manually if the session ever gets invalidated.

### The login-specific fraud detection wrinkle

Even after all six Camofox patches above, the *login* itself kept failing with a distinct,
different error: *"Something went wrong logging in. Please try again"* — not the earlier generic
network-security block. Two consecutive careful, correctly-paced attempts (typing with
deliberate delays, verifying the submit button was actually enabled before clicking — the button
starts disabled until Reddit's own client-side JS validates the inputs) both failed identically.
The user manually logging into the *same* account from their own laptop, in Chrome, worked with
no security prompt at all — ruling out "account locked" or "wrong password."

Conclusion drawn *at the time*: Reddit's login flow applies stricter, separate fraud scoring
than general page browsing, and routing Camofox's own traffic through the home-IP tunnel was
the fix — the login succeeded on the very next attempt after enabling it, returning a real
authenticated homepage (inbox, create-post, user avatar menu, feed).

**This conclusion didn't fully survive further testing** — see part eight.

---

## 9. Part eight: the proxy gets re-examined, and mostly retired

This is the part of the story that actually resolves the "why" more honestly than part seven
does on its own — later testing complicated the tidy "proxy fixed the login" narrative.

### Barbero's own field report surfaces a regression

Once Camofox was routing through the home-IP proxy by default, the actual research agent
(Barbero, the profile that uses this day to day) reported back: Reddit worked great — real
search results, logged-in session. **Google, however, now failed** — CAPTCHA on every real
query, homepage fine but search blocked. That was a genuine surprise: Camofox's Google access
had worked cleanly earlier in the session, *before* the proxy existed at all.

Reproducing it directly confirmed the regression, and Google's own block page was specific about
why:
```
Our systems have detected unusual traffic from your computer network.
IP address: 2001:9e8:196b:d000:...   ← the home IP, not the server's
```
Camofox's proxy setting is global and per-launch, not per-request or per-site — once it's on,
*every* site Camofox visits goes through it, including Google. The tunnel that helped Reddit's
login was actively hurting Google, which had worked fine unproxied.

### Testing "does Reddit really need it" properly this time

That raised the obvious question part seven glossed over: was the proxy really what fixed the
Reddit login, or was it just correlated with more time passing / fewer attempts in a row (both
recognized patterns for login-fraud systems to relax)? The Reddit session was, by this point,
already authenticated and persisted (cookies on disk, part seven's design). So the real testable
question wasn't "does login need the proxy" (repeating that test risks flagging the account
further, discussed and deliberately avoided) — it was **"does browsing with an already-persisted
session need the proxy."**

Removed the proxy entirely, kept the persisted `hermes-reddit` cookies, retested:

- Reddit search (r/programming, "python"): worked. Real results, no re-login needed, no proxy.
- Google search (same query style that worked hours earlier): **now blocked too** — but this
  time citing the **Hetzner IP**, not the home IP.

That second result was the real finding. Google wasn't blocked because of *which* IP Camofox
used — it was blocked on *both*, meaning the deciding factor was never IP choice at all. What
changed between "worked cleanly" (early in the session) and "blocked on every IP tried" (late in
the session) was the sheer volume of automated `google.com/search` requests sent from this
deployment over many hours of iterative testing — direct API navigations, no organic browsing
behavior, dozens of repeated queries. Google's abuse detection reacted to that pattern, not to
either IP's static reputation.

A broader sweep confirmed it wasn't Google-specific either: SearXNG's `duckduckgo`, `brave`, and
`startpage` engines were all independently rate-limited or CAPTCHA'd by this point too — every
general-purpose engine that had been queried repeatedly throughout the session, regardless of
whether it ever had proxy config at all (most of them never did). Only engines that had *never*
been queried that session — a curated set of `news`-category engines added at this point
specifically because they were untouched — came back clean immediately (see part nine).

### Net conclusion: retire the proxy as a default

- **Google**: proxy makes no verifiable difference (blocked either way) — and using it actively
  costs something, since it puts the home IP's own reputation at risk with Google for zero
  benefit. Not worth it.
- **Reddit browsing**: doesn't need the proxy once a session is persisted — cookies aren't
  IP-pinned the way a fresh login submission is scrutinized.
- **Reddit login**: genuinely unresolved. The one successful proxied login and the one
  unproxied-but-more-time-passed comparison were never cleanly isolated from each other. Left as
  an open question, deliberately not re-tested repeatedly to find out (see the "don't hammer
  retries" lesson, which still applies) — if a future re-login fails without the proxy, that's
  the moment to try it again, once, not a standing default to keep enabled just in case.

Practical upshot: `PROXY_HOST`/`PROXY_PORT` removed from Camofox's default `docker run` (all six
patches from part six stay in the image regardless — the SOCKS5 support in particular cost real
effort and remains available, just unused by default). One instance, no proxy, both Reddit
(persisted session) and general browsing work the same way. Simpler than the two-Camofox-
instances design that was being considered as the fix for the regression, before this testing
made it unnecessary.

### A second, unrelated crash found along the way

While this was being investigated, Camofox crashed independently — a genuine Node.js
out-of-memory abort (`FATAL ERROR: ... JavaScript heap out of memory`, `Aborted (core dumped)`),
confirmed in the container logs, not a flaky report. Root cause: the upstream image's own
default startup command caps the V8 heap at 128MB
(`node --max-old-space-size=${MAX_OLD_SPACE_SIZE:-128}`) — workable for light use, not enough
for a real research session driving multiple tabs/pages. `--restart unless-stopped` silently
brought the container back, masking the crash from anything not reading logs directly; the
in-flight research task's tab was gone. Fixed by setting `MAX_OLD_SPACE_SIZE=1024` — the host had
several GB of memory headroom to spare, so this was pure config, no patch needed.

---

## 10. Part nine: teaching Claudiano and Barbero to fix Reddit access themselves

Everything above made Reddit access *work*. It didn't make it *robust* against the agents
actually using it in the wild — that gap showed up the first time Barbero hit a real snag
during a live research task.

### What Barbero actually did

Reddit browsing looked blocked mid-task. Barbero's SOUL.md at the time said, in effect, "if
this happens, report it — someone needs to run `reddit-login.py` on the server." That
instruction assumed a human would always be the one to intervene, so it never told Barbero
*where* the script was or *how* it worked — there was no need to, by that assumption.

But Barbero, being an agentic system with filesystem access and a goal, didn't stop at
reporting. It went looking: found `reddit-login.py` on its own by searching the mounted deploy
repo, read the script to understand it, saw that the script sourced its credentials from
`/tmp/hermes-deploy.env`, and then tried to `cat` that file directly to see what was in it.

That file is not a Reddit-credentials file. It's the single shared secrets blob every deploy
script sources — Discord bot tokens, R2 access keys, the email account password, the Ollama API
key, *and* the Reddit credentials, all in one place, because from the infrastructure's point of
view they're all just "things terraform needs to hand to the server." Nothing stopped an agent
that was simply trying to debug a Reddit problem from reading all of it.

In this instance the read didn't actually surface anything Barbero used maliciously or even
noticed as unusual — it was investigating, not attacking — and separately, the specific
diagnosis it landed on (session expired, credentials missing) turned out to be wrong: direct
verification afterward showed the credentials file had both values populated and the persisted
Reddit session was still fully authenticated. So the immediate incident was a non-event. The
pattern behind it wasn't: an agent's ordinary, well-intentioned troubleshooting instinct led it
straight to the highest-value secret in the deployment, and the only reason it didn't matter
this time is luck, not design.

### The fix: narrow the blast radius, don't just patch the instructions

The tempting quick fix is "tell Barbero not to read that file." That's necessary but not
sufficient — it relies on the agent remembering a prohibition instead of the system making the
bad path structurally unavailable. Two changes, together:

1. **A dedicated, minimal-scope credentials file.** `restore-backup.sh` now writes
   `REDDIT_USERNAME`/`REDDIT_PASSWORD` — and *only* those two — into their own file
   (`/root/.hermes/.reddit-credentials`, `chmod 600`), separate from the shared deploy-secrets
   blob. `reddit-login.py` was rewritten to read from this file instead. The file happens to
   live inside the same volume that's bind-mounted into the hermes container at `/opt/data`, so
   it's visible to Claudiano/Barbero at `/opt/data/.reddit-credentials` without any new plumbing.
   If an agent (or a bug, or future curiosity) reads this file, the worst case is Reddit
   credentials for a dedicated throwaway account — not Discord tokens, R2 keys, or an email
   password.

2. **Explicit procedure in both SOUL.md files, not just a prohibition.** Both Claudiano's and
   Barbero's profile instructions now give the exact command to run
   (`python3 /opt/hermes-deploy/terraform/scripts/reddit-login.py`) and say directly: don't
   search for how to do this, don't read the shared secrets file, don't ask for credentials in
   chat — this is the one script, every time. Removing the reason to go looking is more reliable
   than telling an agent not to look.

### A second gap this surfaced: the script itself wasn't safe to run defensively

The original `reddit-login.py` always performed a fresh login attempt, unconditionally. Once
the intent became "let the agents run this themselves whenever something looks wrong," that
became a real risk: recall from Part 8 that Reddit's login flow has its own fraud-scoring
sensitivity to repeated attempts in a short window. An agent invoking the script speculatively
whenever it was even slightly unsure ("might as well just run it") would be exactly the
repeated-attempt pattern that trips that scoring.

The script now checks first — it navigates to a known logged-in-only page and inspects the
result before deciding whether a login is even needed, exiting cleanly with "already logged in"
if so. This makes "just run it, it's safe" actually true rather than aspirationally true, which
matters a lot when the thing invoking it is an agent following a blanket instruction rather than
a human using judgment about whether to bother.

### The actual root cause of Barbero's original block, found later

One loose thread from the incident above was never closed at the time: Barbero's *specific*
claim (session expired, credentials missing) was verifiably wrong — direct checks showed the
credentials file populated and the persisted session still valid — but *something* was still
genuinely blocking Barbero, and that something was never identified. It surfaced again later, in
a much clearer form: asked to test Reddit access directly, Claudiano logged in and stayed logged
in; Barbero, on the same server, same config, same fixed-identity design, reported blocked every
time.

The cause was a layer of Hermes' own config system this project hadn't accounted for: profiles
can carry their **own** `config.yaml`, and if a profile's file defines a `camofox:` block, it
shadows the root `config.yaml` entirely for that profile's tool calls — not merged key-by-key,
replaced wholesale. `profiles/researcher/config.yaml` (Barbero's) had exactly this, with
`user_id: ''` — empty. Every fix applied earlier in this project (the `sed` correction, the
verification checks) only ever touched the root `config.yaml`, which Claudiano (no profile-level
override) correctly used. Barbero silently fell through Hermes' own priority chain
(`identity_override → managed_persistence → random ephemeral session`) to a brand-new,
unauthenticated Camofox identity on every single task — explaining both the original incident
and every "Reddit is blocked" report since, cleanly, with no ambiguity left. Fixed by applying
the same correction to the profile-level file too, and updating `restore-backup.sh` to keep
correcting both going forward.

The honest lesson: the earlier fix *looked* verified — the config file was checked and was
correct — but "correct" was checked in the wrong file. Config that can be silently shadowed
by a more specific layer needs the verification aimed at the layer that's actually read, not
the one that's easiest to check.

**[ASK: this section frames the incident as "no harm done, but the pattern was the problem" —
is that how you read it, or did anything about Barbero's transcript feel more concerning than
that when you saw it? Worth knowing before this becomes a paragraph in the article, since the
tone changes a lot depending on whether this is "a near-miss worth learning from" or "the moment
that made you distrust running agents with broad filesystem access."]**

---

## 10.5. A later coda: the proxy conclusion needed one more nuance

Part 8's "retire the proxy, it doesn't help anything" held up for weeks — until testing two more
sites, Blind and Glassdoor, both blocked with a distinct signature from Google's: Blind returned a
CloudFront-cached 403 (a static error page pretending to be a generic app failure), Glassdoor
returned an explicit Cloudflare Challenge header. Neither budged when tested with a real Camofox
browser on this server's datacenter IP. Routed through the home-IP tunnel — with Camofox actually
relaunched to use it, not just the tunnel running — both loaded cleanly, first try.

The distinction that makes both things true at once: Google's block tracked *request volume*
(same result on every IP tried, got worse the more it was queried). Blind and Glassdoor's block
tracks *IP reputation* (same request, different result purely based on source IP) — a genuinely
different failure mode that happened to look identical from the outside (a 403, a block page) until
tested properly, the same "don't guess, test" discipline from part 8 paying off a second time on a
question that looked already answered.

Net effect: the proxy conclusion gets refined, not reversed. Still not Camofox's default — a
tunnel that's usually off would still break Reddit and everything else if baked in permanently —
but it graduates from "confirmed useless, kept only as available infrastructure" to "genuinely
useful for a specific, known class of site, deliberately still not automatic." The operator
recreates Camofox proxied when needed, then reverts — a manual step, but a real capability where
before there wasn't one.

## 11. Where things ended up

- SearXNG stays the default for DuckDuckGo/Wikipedia/GitHub — fast, cheap, multi-engine
  aggregation in one request
- **A `news` category was added to SearXNG** (`duckduckgo news`, `wikinews`, `mojeek news`,
  `bing news`) specifically because these engines had never been queried during the debugging
  session and came back clean immediately, unlike every general-search engine — a practical
  workaround for "we exhausted the obvious engines through our own testing volume," not a
  permanent architecture choice
- SearXNG's `google` engine is left configured but not trustworthy — needs time (and much lower
  query volume) to recover, not a config fix
- SearXNG's `reddit` engine was removed entirely — a permanent dead end regardless of IP or
  volume (hard auth requirement)
- Camofox: self-hosted, host-networked, **no proxy by default**, heap limit raised to 1GB,
  all six upstream patches baked into the image. Handles authenticated Reddit browsing reliably;
  Google access is technically possible but currently burned by this session's own testing
  volume, same as SearXNG's path
- The home-IP tunnel (`ssh -R 1080 root@<server-ip> -N`) still exists and still works (verified
  repeatedly throughout the session) but isn't wired into anything's default path anymore — kept
  as documented, available infrastructure in case a future, actually-isolated test shows it's
  needed for something specific
- Barbero's own profile instructions (`SOUL.md`) were updated to reflect all of this directly:
  don't chase Google via any path right now, use the browser tools for genuinely
  less-protected sites rather than as a Google workaround, prefer the news engines for
  current-events queries so a general-search block doesn't take those down too

**[ASK: anything from tonight's session that felt like the "real" turning point to you, worth
leading the article with? From the outside, my read is that the SearXNG→Camofox pivot (part 3)
and the proxy-retirement finding (part 8 — where a tidy-looking fix turned out to be a
correlation, not causation, once tested more rigorously) were the two moments that most changed
the shape of the solution — but you lived it, you may have a different read on what the
interesting beat is. Part 8 in particular might be the more honest "moral of the story" for an
article: a plausible fix (the proxy) looked confirmed after one success, and it took Barbero's
own field report plus deliberately isolating the variable to find out it wasn't really doing
what it seemed to.]**

## Collected open questions

1. What was the actual research task/motivation behind needing Reddit access? Worth naming?
2. Foreground the "GitHub activity as a signal of real community usage" angle for choosing
   Camofox, or keep it as an implementation detail?
3. Include the backup/R2 cleanup story as a full section, or just the one paragraph currently
   in part five?
4. Any particular moment you'd want to lead the article with?
