# Wamarchy

WhatsApp notifications in the [Omarchy](https://omarchy.org) bar, built on
[wacli](https://github.com/openclaw/wacli).

The bar tells you **who is waiting and how many messages** — never what they
said. Click for previews, image thumbnails, voice-note playback, optional local
transcription, and a quick text reply.

## How it works

`wacli` pairs as a linked WhatsApp Web device and mirrors your messages into a
local SQLite database. Wamarchy **reads that database, read-only** — it never
connects to WhatsApp itself, never opens `session.db` (your encryption keys),
and never writes anything into wacli's store.

```
your phone ──► WhatsApp ──► wacli sync --follow ──► ~/.local/state/wacli/wacli.db
                                                          │ read-only
                                                          ▼
                                                   Wamarchy bar widget
```

Outgoing actions (quick reply, media download) shell out to `wacli` itself, so
nothing here re-implements the WhatsApp protocol.

## Requirements

| Requirement | Why | Notes |
|---|---|---|
| `wacli`, paired | the message source | see below |
| `wacli sync --follow` running | keeps the database fresh | see below |
| `sqlite3`, `jq` | read the local mirror | present on a standard Omarchy install |
| `mpv` (or `ffplay`, `paplay`) | voice-note / video playback | optional |
| `whisper-cpp` + `ffmpeg` | voice-note transcription | optional, opt-in, never auto-installed |

## Install

### 1. Install and pair wacli

wacli is not packaged for Arch, and the Homebrew tap is a heavy dependency for
one binary. The release archive is the simplest route:

```bash
VER=0.17.1   # check https://github.com/openclaw/wacli/releases for the latest
cd "$(mktemp -d)"
curl -fLO "https://github.com/openclaw/wacli/releases/download/v$VER/wacli_${VER}_linux_amd64.tar.gz"
curl -fLO "https://github.com/openclaw/wacli/releases/download/v$VER/checksums.txt"
sha256sum -c --ignore-missing checksums.txt
tar xzf "wacli_${VER}_linux_amd64.tar.gz"
install -Dm755 wacli ~/.local/bin/wacli
wacli --version
```

`~/.local/bin` is on the PATH the Omarchy shell inherits, so the widget will
find it there. Homebrew (`brew install openclaw/tap/wacli`) and a source build
(`CGO_ENABLED=1 go install -tags sqlite_fts5 github.com/openclaw/wacli/cmd/wacli@latest`)
both work too — a source build needs the `sqlite_fts5` tag for search.

Then pair it. This shows a QR code you scan from your phone
(**WhatsApp → Settings → Linked devices → Link a device**):

```bash
wacli auth
```

WhatsApp allows up to four linked devices, so this coexists with WhatsApp Web
in your browser and with any other linked device you already use.

Verify:

```bash
wacli doctor
wacli chats list
```

### 2. Keep the local mirror up to date

Wamarchy reads a local database; something has to fill it. Run wacli's sync in
follow mode as a user service. A ready-made unit is in `contrib/`:

```bash
mkdir -p ~/.config/systemd/user
cp contrib/wamarchy-sync.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now wamarchy-sync
systemctl --user status wamarchy-sync
```

The panel tells you when sync is not running, rather than quietly showing a
frozen count.

### 3. Install the plugin

```bash
omarchy plugin add https://github.com/boyoyooo/wamarchy
```

Then add the **Wamarchy** widget to your bar from Omarchy's bar settings.

## Configuring who may notify you

Open the panel and click the gear. Three modes:

- **Paused** — nothing notifies you. The bar shows a muted icon.
- **Everyone** — every direct message and group.
- **Chosen chats** — pick exactly which contacts and groups may notify you,
  from a searchable list populated live from your synced chats.

The selection is stored at `~/.config/omarchy/wamarchy/config.json`
(`0600`, outside the plugin folder, so updating the plugin never touches it).

## Configuring how much is shown

Widget settings, per instance:

| Setting | Default | Effect |
|---|---|---|
| What the bar shows | Sender and count | `Icon only` / `Count only` / `Sender and count`. **Message text is never shown in the bar at any setting.** |
| Messages previewed per chat | 4 | How much history the expanded panel shows |
| Desktop notifications | Sender only | `Off` / `Sender only` / `Sender and preview` |
| Include WhatsApp Channels | off | Channels are usually broadcast noise |
| Hide the widget when there is nothing new | off | |
| Refresh interval | 20 s | How often the local database is read |

`Sender and preview` puts message text on your screen where anyone nearby can
read it. That is why it is not the default.

## Using the panel

- **Click a chat** — expands it, marks it read, and shows the recent messages.
- **Click it again** — hands off to the official WhatsApp Web app.
- **Photos** — shown as thumbnails; `Open` hands them to your image viewer.
- **Documents** — icon, filename, and `Open`.
- **Voice notes** — `Play` plays the original audio. `Transcribe` appears only
  when a local speech engine is installed.
- **Reply** — type and press Enter. This sends through
  `wacli send text`. It is always you typing and pressing send: the plugin has
  no automatic, scheduled, or agent-initiated send path of any kind.

### Known limitation: no per-chat deep link

Clicking through opens WhatsApp Web's **inbox**, not the specific conversation.
This is a WhatsApp limitation, not a bug: `wa.me/<number>` only opens a *new*
chat compose, and there is no equivalent for groups at all. WhatsApp Web
exposes no stable URL for an existing conversation.

## Voice-note transcription (optional)

Playback needs nothing beyond a media player. Transcription needs a local
speech engine. Wamarchy detects `whisper-cli` / `whisper-cpp` (with a `ggml-*`
model) or OpenAI's `whisper`, and only shows a `Transcribe` button when one is
actually present.

If none is found, the settings section offers **Set up local transcription…**.
That button installs nothing. It opens a confirmation dialog, which opens a
terminal, which prints exactly which packages and downloads are involved and
asks you to type `yes` before anything is changed. You can also do it yourself:

```bash
sudo pacman -S --needed whisper-cpp ffmpeg
mkdir -p ~/.local/share/wamarchy/models
curl -L -o ~/.local/share/wamarchy/models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

Transcription runs entirely on your machine. Audio is never uploaded anywhere.

Point at a different model with `WAMARCHY_WHISPER_MODEL=/path/to/ggml-*.bin`.

## Privacy and security notes

- The poller opens `wacli.db` with a `SQLITE_OPEN_READONLY` connection. It
  cannot modify your message store even if a query were wrong.
- `session.db` — wacli's WhatsApp encryption keys — is never read.
- Message text never reaches the bar, and never reaches a desktop notification
  unless you explicitly select `Sender and preview`.
- Nothing private reaches a command line on this plugin's side of the boundary.
  Reply text and the allow-list arrive over **stdin**; SQL queries, chat JIDs,
  the config, and voice-note transcripts are piped into `sqlite3` and `jq`
  rather than passed as arguments. Process arguments are readable by every
  other process running as you via `/proc/<pid>/cmdline`, so none of this is
  put there.
  **One exception, outside this plugin's control:** `wacli send text` takes the
  recipient and the message body as command-line arguments. For the second or
  so a reply is in flight, they are visible in `ps` to other processes running
  as you. That is wacli's interface; it is stated here rather than glossed over.
- Attachment paths recorded in the database are verified to resolve inside
  wacli's own store before any file is handed to a player or viewer;
  WhatsApp-supplied filenames are never used to build a path.
- Downloaded media is cached `0600` under
  `~/.cache/omarchy-wamarchy/media/`. Delete that directory to clear it.
- Nothing is installed, updated, or removed from your system without an
  explicit typed confirmation in a terminal.

## Uninstall

```bash
omarchy plugin remove io.github.boyoyooo.wamarchy
rm -rf ~/.config/omarchy/wamarchy ~/.cache/omarchy-wamarchy
systemctl --user disable --now wamarchy-sync
rm -f ~/.config/systemd/user/wamarchy-sync.service
```

Removing the plugin does not unlink your WhatsApp device. To do that, run
`wacli auth logout`, or remove the linked device from your phone.

## Troubleshooting

```bash
# What does the poller actually see?
~/.config/omarchy/plugins/io.github.boyoyooo.wamarchy/bin/wa-status.sh | jq

# Is the mirror being fed?
systemctl --user status wamarchy-sync
wacli doctor

# QML / widget errors
journalctl --user --since "2 minutes ago" | grep -i quickshell
```

The poller always exits 0 and always prints one JSON object: `{"ok":true,...}`
or `{"ok":false,"error":"..."}`. A failed poll is rendered as a fault marker in
the bar, never as "no new messages".

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with, endorsed by, or connected to WhatsApp or Meta.
