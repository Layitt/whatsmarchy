# Whatsmarchy

WhatsApp notifications in the [Omarchy](https://omarchy.org) bar, built on
[wacli](https://github.com/openclaw/wacli).

The bar tells you **who is waiting and how many messages** — never what they
said. Click for previews, image thumbnails, voice-note playback, optional local
transcription, and a quick reply — typed, or recorded as a voice note you listen
back to before it sends.

## How it works

`wacli` pairs as a linked WhatsApp Web device and mirrors your messages into a
local SQLite database. Whatsmarchy **reads that database, read-only** — it never
connects to WhatsApp itself, never opens `session.db` (your encryption keys),
and never writes anything into wacli's store.

```
your phone ──► WhatsApp ──► wacli sync --follow ──► ~/.local/state/wacli/wacli.db
                                                          │ read-only
                                                          ▼
                                                   Whatsmarchy bar widget
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
| `parecord` (or `pw-record`) + `ffmpeg` with `libopus` | recording a voice reply | optional; the microphone button is hidden when missing |
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

Whatsmarchy reads a local database; something has to fill it. Run wacli's sync in
follow mode as a user service. A ready-made unit is in `contrib/`:

```bash
mkdir -p ~/.config/systemd/user
cp contrib/whatsmarchy-sync.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now whatsmarchy-sync
systemctl --user status whatsmarchy-sync
```

The panel tells you when sync is not running, rather than quietly showing a
frozen count.

### 3. Install the plugin

```bash
omarchy plugin add https://github.com/boyoyooo/whatsmarchy
```

Then add the **Whatsmarchy** widget to your bar from Omarchy's bar settings.

## Configuring who may notify you

Open the panel and click the gear. Three modes:

- **Paused** — nothing notifies you. The bar shows a muted icon.
- **Everyone** — every direct message and group.
- **Chosen chats** — pick exactly which contacts and groups may notify you,
  from a searchable list populated live from your synced chats.

The selection is stored at `~/.config/omarchy/whatsmarchy/config.json`
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
- **Voice reply** — the microphone button records from your default input
  device. Press **Stop**, then **Play** to hear it back, then **Send** or
  **Cancel**. It never sends on stop: recording and sending are two separate
  decisions. Recordings are capped at two minutes, encoded to OGG/Opus, and sent
  through `wacli send voice` (WhatsApp's own voice-note format, so it arrives as
  a playable bubble rather than a file attachment).

  Choosing the input device is your audio settings' job, not this widget's — it
  records from whatever is the default. If the preview warns that the recording
  sounds silent, your default input is probably a monitor rather than a
  microphone; `pactl info` will say which.

### Known limitation: no per-chat deep link

Clicking through opens WhatsApp Web's **inbox**, not the specific conversation.
This is a WhatsApp limitation, not a bug: `wa.me/<number>` only opens a *new*
chat compose, and there is no equivalent for groups at all. WhatsApp Web
exposes no stable URL for an existing conversation.

## Voice-note transcription (optional)

Playback needs nothing beyond a media player. Transcription needs a local
speech engine. Whatsmarchy detects `whisper-cli` / `whisper-cpp` (with a `ggml-*`
model) or OpenAI's `whisper`, and only shows a `Transcribe` button when one is
actually present.

If none is found, the settings section offers **Set up local transcription…**.
That button installs nothing. It opens a confirmation dialog, which opens a
terminal, which prints exactly which packages and downloads are involved and
asks you to type `yes` before anything is changed. You can also do it yourself:

```bash
sudo pacman -S --needed whisper-cpp ffmpeg
mkdir -p ~/.local/share/whatsmarchy/models
curl -L -o ~/.local/share/whatsmarchy/models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

Transcription runs entirely on your machine. Audio is never uploaded anywhere.

Point at a different model with `WHATSMARCHY_WHISPER_MODEL=/path/to/ggml-*.bin`.

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
  Two residual exposures, stated rather than glossed over — both are visible
  only to processes already running **as you**, never to other users:
  - `wacli send text` takes the recipient and the message body as command-line
    arguments, so during the second or so a reply is in flight they appear in
    `ps`. That is wacli's interface and cannot be avoided from here.
  - `wacli send voice` likewise takes the recipient and the recording's path as
    arguments. The path names a file in this plugin's own cache and the JID is
    already on the helper's command line, so the send adds no exposure beyond
    what the line below describes.
  - The panel invokes the helper as `wa-ctl.sh <action> <chat-jid> …`, so the
    JID of the chat you are acting on — a phone number, or a group id — is in
    that short-lived process's own arguments. Message content, the allow-list,
    and voice-note transcripts never are.
- Attachment paths recorded in the database are verified to resolve inside
  wacli's own store before any file is handed to a player or viewer;
  WhatsApp-supplied filenames are never used to build a path.
- Downloaded media is cached `0600` under
  `~/.cache/omarchy-whatsmarchy/media/`. Delete that directory to clear it.
- The microphone is only ever open while the recording controls are on screen.
  The recorder is stopped by the panel *closing its pipe*, so "the panel went
  away" and "the user pressed Stop" are the same event — closing the panel,
  collapsing the chat, or the shell quitting all end the recording, not just the
  Stop button. Those controls sit outside the message list precisely so that a
  refresh cannot take them away while the microphone is still open.
  For the one signal a script cannot catch — `SIGKILL`, an OOM kill — the
  recorder is additionally launched under `timeout`, so it stops on its own even
  when nothing is left alive to stop it. Every recording is capped at two
  minutes regardless.
- Recordings waiting to be sent live `0600` in
  `~/.cache/omarchy-whatsmarchy/outgoing/` — a directory that is refused outright
  if it is ever replaced by a symlink — and are deleted on Send or Cancel.
  Anything that survives a crash is swept once it is three hours old, on the next
  open of the panel or the next recording, whichever comes first.
- The panel never learns a recording's path: it gets an opaque token back and
  hands that to play/send/discard, so no value crossing that boundary can name a
  file this plugin did not create. Immediately before the file is handed to
  `wacli` it is renamed to a fresh random name, so the path being sent is one
  that was never published to anything and cannot be swapped underneath it.
- Nothing is installed, updated, or removed from your system without an
  explicit typed confirmation in a terminal.

## Uninstall

```bash
omarchy plugin remove io.github.boyoyooo.whatsmarchy
rm -rf ~/.config/omarchy/whatsmarchy ~/.cache/omarchy-whatsmarchy
systemctl --user disable --now whatsmarchy-sync
rm -f ~/.config/systemd/user/whatsmarchy-sync.service
```

Removing the plugin does not unlink your WhatsApp device. To do that, run
`wacli auth logout`, or remove the linked device from your phone.

## Troubleshooting

```bash
# What does the poller actually see?
~/.config/omarchy/plugins/io.github.boyoyooo.whatsmarchy/bin/wa-status.sh | jq

# Is the mirror being fed?
systemctl --user status whatsmarchy-sync
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
