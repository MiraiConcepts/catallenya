# capture — operations

Installing the client, rebuilding the server side, and the credentials both need.
What it is and why it is shaped this way lives in [README.md](README.md).

## Laptop setup

The client is the one piece that lives outside the server.

**1. Install a region-select screenshot tool**

| Platform | Install |
|---|---|
| Wayland (sway, Hyprland, GNOME) | `sudo apt install grim slurp` |
| X11 | `sudo apt install maim` (or `scrot`) |
| macOS | built in (`screencapture`) |
| KDE | `spectacle` |

**2. Copy the client over**

```bash
scp catallenya:/zpool/catallenya/afterimage/client/afterimage.sh ~/.local/bin/capture
chmod +x ~/.local/bin/capture
```

**3. Bind a hotkey**

- **GNOME** — Settings → Keyboard → Custom Shortcuts → `~/.local/bin/capture`
- **sway/Hyprland** — `bindsym $mod+Shift+c exec ~/.local/bin/capture`
- **i3** — same as sway
- **macOS** — Automator "Quick Action" running the script, then assign a shortcut
  in System Settings → Keyboard Shortcuts → Services

**4. Subscribe to the notifications**

Open the ntfy app and subscribe to the **`capture`** topic on the tailnet server.
Without this the pipeline works but you never see the proposals.

The client needs no credentials — it only reaches a tailnet-only URL, and the
Add/Discard callbacks are gated by an unguessable per-capture id.

## Server setup

Done on this box on 2026-07-25 — the container is running behind Caddy, the units are
installed, and captures are flowing. Kept here for a rebuild.

The API key is the one prerequisite. It is read by systemd as root and injected
into the triage process, so it never sits in a file the `carrein` user can read.
It lives in `/etc/ai.env` rather than a capture-specific file because it is shared
infrastructure now — `pigeonhole.triage.service` reads the same file (see
`ai/scripts/ai.lib.sh`):

```bash
sudoedit /etc/ai.env      # ANTHROPIC_API_KEY=sk-ant-...
sudo chmod 600 /etc/ai.env
```

The container also needs the Radicale credential as a docker secret — the same
`base64(carrein:<app pw>)` Caddy injects for mitsume. It is a file, not an env var,
because `docker inspect` and `/proc/1/environ` both expose environment, and that
credential is good for read, write and delete across the whole `/carrein/` tree:

```bash
grep -m1 '^MITSUME_DAV_B64=' .env | cut -d= -f2- > afterimage/dav-secret
chmod 600 afterimage/dav-secret
```

Then:

```bash
docker compose up -d --build capture
docker compose up -d --force-recreate caddy   # new port needs a recreate, not restart
sudo bash systemd/install.sh                  # symlinks + enables the .path and .timer
```

`NTFY_ORIGIN` is set in compose from the tailnet vars. It is the ONE browser origin
allowed to satisfy the `X-Capture` preflight: the ntfy web UI taps buttons with
browser `fetch()`, so CORS applies to it, and refusing every preflight — which
shipped briefly on 2026-07-27 — breaks the web client with an opaque
`TypeError: NetworkError`. The phone app does native HTTP and never sees this. Any
other page is still refused, because browsers set `Origin` and a page cannot forge it.

Last step is subscribing a device to the `capture` topic (above). Everything else can
be green and you will still never see a proposal without it.

## Running and inspecting

```bash
sudo systemctl start afterimage.triage.service      # drain incoming/ now
bash afterimage/scripts/afterimage.sweep.sh --dry-run  # preview the nightly sweep
bash afterimage/tests/run.sh                        # offline suite
bash ai/tests/run.sh                             # the transport half — run both
```

Outcome counts, straight from the archive — there is no ledger, so each record's
own `decision.json` is the source:

```bash
jq -s 'group_by(.outcome)|map({outcome:.[0].outcome,n:length})' afterimage/data/archive/*/decision.json
```

A button tapped to exercise the plumbing is **not** a label — correct that record's
`outcome` (or leave a `note` saying it was a test) so the archive measures the model
rather than your workarounds.
