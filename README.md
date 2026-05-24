# claude-rtl

**Fix the RTL bug in Claude Desktop on macOS.** Mixed Persian/Arabic/Hebrew + English text now flows in the correct direction per paragraph — automatically, everywhere in the app.

```
سلام hi چطوری         →  flows RTL, "hi" mirrored inside
hi سلام how are you   →  flows LTR, "سلام" mirrored inside
print("سلام")         →  code stays LTR no matter what
```

One script. One command. Reversible. Universal — works on any Mac, with or without Node installed.

---

## Install & update

Same one-liner does both — fresh install **or** pulling the latest version:

```bash
curl -fsSLo /tmp/c.sh https://raw.githubusercontent.com/SMKeramati/claude-rtl/main/claude-rtl-patch.sh && chmod +x /tmp/c.sh && /tmp/c.sh --install && source ~/.zshrc
```

`--install` overwrites `~/.claude/claude-rtl-patch.sh` in place; your existing `claude-rtl` alias keeps working.

Then quit Claude and run:

```bash
claude-rtl
```

That's it. Open Claude — mixed RTL/LTR text now auto-flows by paragraph.

---

## Why this exists

Claude Desktop is an Electron shell that loads claude.ai. The web app's chat input and message containers don't set `dir="auto"` or `unicode-bidi: plaintext`, so the Unicode bidirectional algorithm has nothing to anchor on and mixed RTL+LTR text renders left-to-right — unreadable for ~520M Arabic / Persian / Hebrew speakers.

There are 10+ open GitHub issues about it ([#38005](https://github.com/anthropics/claude-code/issues/38005), [#45652](https://github.com/anthropics/claude-code/issues/45652), [#30085](https://github.com/anthropics/claude-code/issues/30085), and others) with no official fix yet. This script applies the fix locally by injecting two lines of CSS + a small auto-attribute setter into every Claude window.

---

## Quick start

```bash
# 1. Download
curl -fsSLo claude-rtl-patch.sh https://raw.githubusercontent.com/SMKeramati/claude-rtl/main/claude-rtl-patch.sh
chmod +x claude-rtl-patch.sh

# 2. Install (copies itself to ~/.claude/ and wires up the 'claude-rtl' alias)
./claude-rtl-patch.sh --install

# 3. Reload shell, quit Claude, then apply
source ~/.zshrc
claude-rtl
```

Open Claude — mixed RTL/LTR text now auto-flows by paragraph.

---

## Commands

| Command | What it does |
|---|---|
| `claude-rtl` | Apply the patch. Idempotent — safe to re-run. |
| `claude-rtl --revert` | Restore the original `Claude.app` from backup. |
| `claude-rtl --status` | Show whether currently patched, hashes, backup info. |
| `claude-rtl --install` | Copy script to `~/.claude/` (overwriting any existing copy) and add the `claude-rtl` alias to `~/.zshrc`. Re-run to update. |
| `claude-rtl --uninstall` | Remove the alias from `~/.zshrc`. Does **not** revert the patch — use `--revert` first if needed. |
| `claude-rtl --help` | Print usage. |

**Claude must be quit** before `apply` or `--revert` (the script tries to quit it for you).

---

## How it works

1. **Extracts** `/Applications/Claude.app/Contents/Resources/app.asar`.
2. **Injects** a small file (`rtl-fix.js`) that hooks `app.on('browser-window-created')` in the Electron main process, then on every window's `did-finish-load`:
   - Calls `webContents.insertCSS()` with:
     ```css
     textarea, [contenteditable], .ProseMirror { unicode-bidi: plaintext !important; text-align: start !important; }
     p, li, blockquote, h1-h6, .message, .markdown { unicode-bidi: plaintext !important; }
     pre, code { unicode-bidi: isolate !important; direction: ltr !important; }
     ```
   - Calls `webContents.executeJavaScript()` to set `dir="auto"` on existing input elements, plus a `MutationObserver` to apply it to anything React renders later.
3. **Repacks** the asar.
4. **Updates** the `ElectronAsarIntegrity` SHA-256 hash in `Info.plist` (Electron refuses to load the asar otherwise — the hash is computed over the asar header JSON, not the whole file).
5. **Ad-hoc re-signs** the bundle with `codesign --force --deep --sign -` (Apple notarization is lost, but Gatekeeper still launches it locally).
6. **Clears** the quarantine xattr.

**Per-paragraph auto direction.** `unicode-bidi: plaintext` on block elements + `dir="auto"` on inputs is what makes each paragraph's direction depend on its first strong character — Persian-leading lines go RTL, English-leading lines go LTR, automatically. Code blocks are forced LTR so source code never mirrors.

---

## Safety & reversibility

- **Backup is automatic.** First run saves the original `app.asar` to `~/.claude-rtl-patch/app.asar.orig` and the original integrity hash to `~/.claude-rtl-patch/original-hash.txt`.
- **`--revert` restores both** byte-for-byte and re-signs. The backup is kept after revert so you can re-apply later without redownloading anything.
- **Idempotent.** Re-running apply detects the in-asar marker and is a no-op.
- **Sentinel-wrapped zshrc edit.** The alias is inserted between `# >>> claude-rtl-patch shortcut >>>` markers. `--uninstall` removes exactly that block and saves a `~/.zshrc.bak.<timestamp>` first.
- **No system-wide changes.** Everything outside `/Applications/Claude.app` lives in `~/.claude/` (the script) and `~/.claude-rtl-patch/` (backup + tooling).

---

## Updates

**When Claude auto-updates,** macOS replaces `app.asar` — your patch is wiped. Just re-run:

```bash
claude-rtl
```

The script detects "not patched", makes a fresh backup of the new asar, and re-applies. Takes ~5 seconds.

**To update the script itself,** re-run the [install & update one-liner](#install--update).

### Auto re-apply on Claude updates (optional)

Tired of running `claude-rtl` after every Claude update? One command turns on a
LaunchAgent that re-applies the patch silently whenever Claude's auto-updater
replaces `app.asar`:

```bash
claude-rtl --auto-install      # enable
claude-rtl --auto-uninstall    # disable
```

**How it works.** Creates `~/Library/LaunchAgents/com.claude-rtl.watcher.plist`
with `WatchPaths` on `/Applications/Claude.app/Contents/Resources/app.asar` →
event-driven, not polling. Re-applying needs root, so a scoped passwordless rule
is added to `/etc/sudoers.d/claude-rtl` (limited to exactly this script's path),
and the script is chowned `root:wheel` so user-level processes can't replace
what runs. Logs at `~/.claude-rtl-patch/auto.log` (read with `sudo tail`).

**Tradeoff.** The sudoers rule trusts the *path*, not the *content*. Root-owning
the script closes the user-tamper hole; the cost is that future `--install`
runs prompt for sudo once to overwrite (still better than once per *apply*).
Touch ID for sudo via `/etc/pam.d/sudo_local` is a comparable alternative if
you want a tap-to-confirm per fire instead.

---

## Universal compatibility

| Concern | Handled |
|---|---|
| macOS Bash 3.2 (the default `/bin/bash`) | ✅ Script uses no 4.x features. Shebang pinned to `/bin/bash`. |
| Apple Silicon (arm64) and Intel (x86_64) | ✅ Detected via `uname -m`. |
| No Node installed | ✅ Auto-downloads Node 20 LTS into `~/.claude-rtl-patch/` on first run (~30 MB, one time). Never installs system-wide. |
| No Homebrew | ✅ Not required. Uses only `curl`, `tar`, `shasum`, `codesign`, `osascript`, `PlistBuddy` — all bundled with macOS. |
| Has Node already | ✅ Uses system Node if it's v18+. |

---

## Troubleshooting

**macOS keeps prompting for keychain access when Claude launches.**
This happens if you applied an *earlier* version of this script that used `codesign --deep`, which re-signed every nested helper as ad-hoc. The current version signs only the outer bundle (preserving Anthropic's signatures on the helpers), so fresh installs don't have this issue. If you already hit it, you have two options:
1. **Click "Always Allow" 2–3 times** when prompted. After macOS records the new signature against each keychain ACL, the prompts stop.
2. **Reinstall Claude cleanly:** download a fresh `Claude.app` from [anthropic.com/desktop](https://claude.ai/download), drop it into `/Applications`, then re-run `claude-rtl`.

**"Claude can't be opened because it is from an unidentified developer."**
The ad-hoc resigning isn't notarized. Run:
```bash
sudo xattr -dr com.apple.quarantine /Applications/Claude.app
```
Then open Claude normally.

**Patch worked, but Persian still looks wrong in some areas.**
Open DevTools (⌘⌥I), Inspect the affected element, and confirm it's a `textarea` / `[contenteditable]` / paragraph-level tag. The CSS targets common selectors — Anthropic may have introduced new ones; please open an issue with the selector.

**Claude auto-updated and now mixed text flows LTR again.**
Expected. Re-run `claude-rtl` to re-apply against the new asar.

**I want to fully remove everything.**
```bash
claude-rtl --revert            # restore Claude.app
claude-rtl --uninstall         # remove the alias from .zshrc
rm -rf ~/.claude-rtl-patch     # delete backups and bundled tools
rm ~/.claude/claude-rtl-patch.sh
```

---

## Caveats (the honest cost)

- **Apple notarization is lost** (you re-sign ad-hoc). For local use, Gatekeeper still launches the app. If you ship Claude to other Macs you'd need Anthropic's signature.
- **Auto-update overwrites the patch.** Re-run `claude-rtl`. Re-application is fast.
- **Anthropic could restructure `index.pre.js`.** The script fails loudly with a clear error if the entry point isn't where it expects. Open an issue and the path can be updated.

---

## What this is not

- Not a fork of Claude Desktop.
- Not an extension or plugin (Anthropic doesn't expose an extension API for the desktop chat).
- Not a workaround for Claude Code in your real terminal — for that, use a Bidi-aware terminal like iTerm2, WezTerm, or Ghostty.

---

## Contributing

PRs welcome. Especially:
- Confirmed selectors for new Claude UI versions.
- Linux / Windows ports (current Windows patch lives at [shraga100/claude-desktop-rtl-patch](https://github.com/shraga100/claude-desktop-rtl-patch)).
- Improvements to the bidi CSS for edge cases (long mixed paragraphs, lists with leading punctuation, etc.).

---

## License

MIT. See `LICENSE`.

---

## Credits

- The fix concept (`unicode-bidi: plaintext` + `dir="auto"`) is the standard CSS Writing Modes / HTML approach for bidirectional text.
- Hash + signing technique adapted from the macOS Electron asar-integrity / codesign documentation, plus prior art in [shraga100/claude-desktop-rtl-patch](https://github.com/shraga100/claude-desktop-rtl-patch) (Windows).
- Built for everyone who's been typing `سلام hi` and squinting at the result.
