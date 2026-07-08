# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single Bash script (`claude-rtl-patch.sh`) that patches the macOS Claude Desktop app so mixed RTL/LTR text (Persian, Arabic, Hebrew + English) flows per-paragraph based on the first strong character. There is no build system, no package.json, no tests — the script *is* the product.

## Running it

```bash
./claude-rtl-patch.sh             # apply (idempotent)
./claude-rtl-patch.sh --revert    # restore original Claude.app from backup
./claude-rtl-patch.sh --status    # show patch state, hashes, backup info
./claude-rtl-patch.sh --install   # copy to ~/.claude/ + add zsh alias
./claude-rtl-patch.sh --uninstall # remove the alias only
```

Apply/revert need `sudo` (writes into `/Applications/Claude.app`). The script quits Claude for you via `osascript`.

To smoke-test a change: edit the script, run `./claude-rtl-patch.sh --revert` (if previously applied), then `./claude-rtl-patch.sh`, then launch Claude and verify mixed text renders correctly. `--status` is the fastest sanity check between iterations.

## Architecture / how the patch works

The five things that make this work as a self-contained script — touch any of them and you can break the whole flow:

1. **Asar extract → inject → repack.** The Electron app's code lives in `/Applications/Claude.app/Contents/Resources/app.asar`. The script uses `@electron/asar` (installed locally into `~/.claude-rtl-patch/tool/`, **pinned to ^3** — v4+ is ESM-only and breaks both the CLI invocation and the inline `require()` in `asar_header_hash`) to extract, write `rtl-fix.js` at the asar root, prepend a `try { require('../../rtl-fix.js') } catch ... ` line to `.vite/build/index.pre.js` (the Electron main-process entry point), then repack.

2. **ElectronAsarIntegrity hash.** Electron refuses to load the asar if the SHA-256 in `Info.plist` (`:ElectronAsarIntegrity:Resources/app.asar:hash`) doesn't match. The hash is computed over the asar **header JSON**, not the whole file — see `asar_header_hash()`. After repack, the script updates the plist via `PlistBuddy`.

3. **Ad-hoc re-sign.** `codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime` on the outer bundle only. **Do not add `--deep`** — it re-signs nested helpers as ad-hoc, which invalidates their keychain ACLs and causes repeated keychain prompts on every Claude launch. This was a real prior bug (see README troubleshooting).

4. **The injection itself** (`rtl-fix.js`, heredoc inside `cmd_apply`). Hooks `app.on('browser-window-created')` and `web-contents-created`, then on every webContents event (`dom-ready`, `did-finish-load`, `did-frame-finish-load`, `did-navigate-in-page`) calls `insertCSS` (per-paragraph `unicode-bidi: plaintext`, code forced LTR) and `executeJavaScript` (sets `dir="auto"` on inputs + `MutationObserver` for React-rendered nodes). `dom-ready` is the key event — injecting there avoids a first-launch blank-flash.

5. **Backup + idempotency.** First apply copies the pristine asar to `~/.claude-rtl-patch/app.asar.orig` and stashes the original Info.plist hash + Claude version. The marker `rtl-fix.js` inside the asar is the "is patched" signal (`is_patched` calls `asar list`). `--revert` restores both the asar and the hash, then re-signs.

## Portability constraints — don't break these

- **macOS Bash 3.2 only.** Default `/bin/bash` is 3.2 (no associative arrays, no `mapfile`, no `${var^^}`). Shebang is pinned to `/bin/bash`. `set -eu` + `set -o pipefail`.
- **macOS-native tools only** in the hot path: `curl`, `tar`, `shasum`, `codesign`, `osascript`, `PlistBuddy`, `xattr`. No Homebrew. No GNU coreutils flags.
- **Node bootstrap.** If `node` is missing or <18, the script downloads Node 20 LTS (Apple Silicon or Intel, detected via `uname -m`) into `~/.claude-rtl-patch/` — never system-wide. Installer preference for `@electron/asar`: `bun` → `pnpm` → bootstrapped `npm`.
- **BSD sed/awk.** The uninstall block uses `awk` for sentinel-bounded removal because BSD `sed -i` semantics differ from GNU.

## State that lives outside the repo

- `~/.claude/claude-rtl-patch.sh` — canonical install location (the `--install` target). The `claude-rtl` alias in `~/.zshrc` points here.
- `~/.claude-rtl-patch/` — backup (`app.asar.orig`, `original-hash.txt`, `claude-version.txt`), bootstrapped Node, and the `@electron/asar` tool dir.
- `~/.zshrc` — sentinel-wrapped alias block (`# >>> claude-rtl-patch shortcut >>>` … `<<<`). `--uninstall` removes exactly that block and saves a `.bak.<timestamp>`.
