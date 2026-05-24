#!/bin/bash
# Claude Desktop RTL patch for macOS
# Makes mixed Persian/Arabic/Hebrew + English text flow per-paragraph
# based on the first strong character (so "سلام hi" goes RTL,
# "hi سلام" goes LTR — automatically, everywhere in the app).
#
# Universal: works on stock macOS Bash 3.2 (no Homebrew needed) and
# auto-installs a local Node if you don't have one. Uses only macOS-
# native tools (curl, tar, shasum, codesign, PlistBuddy, osascript).
#
# Usage:
#   ./claude-rtl-patch.sh              # apply (idempotent)
#   ./claude-rtl-patch.sh --revert     # undo (restores original)
#   ./claude-rtl-patch.sh --status     # show current state
#   ./claude-rtl-patch.sh --install    # add 'claude-rtl' alias to ~/.zshrc
#   ./claude-rtl-patch.sh --uninstall  # remove the alias
#   ./claude-rtl-patch.sh --help

set -eu
set -o pipefail

APP="/Applications/Claude.app"
RES="$APP/Contents/Resources"
ASAR="$RES/app.asar"
PLIST="$APP/Contents/Info.plist"
STATE_DIR="$HOME/.claude-rtl-patch"
BACKUP_ASAR="$STATE_DIR/app.asar.orig"
BACKUP_HASH="$STATE_DIR/original-hash.txt"
BACKUP_VERSION="$STATE_DIR/claude-version.txt"
MARKER="rtl-fix.js"   # presence in asar means "patched"

c_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
c_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
c_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
c_dim()    { printf "\033[2m%s\033[0m\n" "$*"; }
step()     { printf "→ %s\n" "$*"; }
die()      { c_red "✗ $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

ensure_prereqs() {
  require_cmd curl
  require_cmd tar
  require_cmd shasum
  require_cmd codesign
  require_cmd /usr/libexec/PlistBuddy
  [ -d "$APP" ] || die "Claude.app not found at $APP"
  ensure_node
  ensure_asar_tool
}

# Pinned local Node (LTS). Only downloaded if the user has no usable node.
LOCAL_NODE_VERSION="20.18.0"

ensure_node() {
  # Prefer system Node if it's 18+
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    local v
    v=$(node -p 'parseInt(process.versions.node)' 2>/dev/null || echo 0)
    if [ "${v:-0}" -ge 18 ] 2>/dev/null; then
      NODE_BIN="$(command -v node)"
      NPM_BIN="$(command -v npm)"
      return
    fi
  fi
  # Otherwise bootstrap a local Node into $STATE_DIR (one-time, ~30MB).
  local arch_id
  case "$(uname -m)" in
    arm64)  arch_id="darwin-arm64" ;;
    x86_64) arch_id="darwin-x64" ;;
    *) die "Unsupported macOS architecture: $(uname -m)" ;;
  esac
  local node_dir="$STATE_DIR/node-v$LOCAL_NODE_VERSION-$arch_id"
  if [ ! -x "$node_dir/bin/node" ]; then
    step "No usable Node found. Bootstrapping local Node $LOCAL_NODE_VERSION (~30 MB, one-time)..."
    mkdir -p "$STATE_DIR"
    local url="https://nodejs.org/dist/v$LOCAL_NODE_VERSION/node-v$LOCAL_NODE_VERSION-$arch_id.tar.gz"
    curl -fsSL "$url" | tar -xz -C "$STATE_DIR" \
      || die "Failed to download Node from $url (check your network)."
  fi
  NODE_BIN="$node_dir/bin/node"
  NPM_BIN="$node_dir/bin/npm"
}

# Install @electron/asar locally once so we can call it fast on every run.
# Pinned to ^3 — v4+ went ESM-only and renamed the bin to asar.mjs, which
# breaks both `node bin/asar.js` and the inline `require('@electron/asar')`
# call in asar_header_hash.
#
# Installer preference: bun → pnpm → npm. The first one already on PATH wins;
# bootstrapped Node ships with npm as the guaranteed fallback.
ensure_asar_tool() {
  TOOL_DIR="$STATE_DIR/tool"
  if [ -f "$TOOL_DIR/node_modules/@electron/asar/bin/asar.js" ]; then
    return
  fi
  rm -rf "$TOOL_DIR"
  mkdir -p "$TOOL_DIR"
  printf '{"name":"claude-rtl-tool","private":true}\n' > "$TOOL_DIR/package.json"

  local installer_name installer_cmd
  if command -v bun >/dev/null 2>&1; then
    installer_name="bun";  installer_cmd="bun add"
  elif command -v pnpm >/dev/null 2>&1; then
    installer_name="pnpm"; installer_cmd="pnpm add"
  else
    installer_name="npm";  installer_cmd="$NPM_BIN i"
  fi

  step "Installing @electron/asar via ${installer_name}..."
  # shellcheck disable=SC2086
  ( cd "$TOOL_DIR" && $installer_cmd '@electron/asar@^3' >/dev/null 2>&1 ) \
    || die "Failed to install @electron/asar into ${TOOL_DIR} (using ${installer_name})"
}

asar_run() {
  # $1 = "extract" | "pack" | "list"  ; $2..$N = args
  ( cd "$TOOL_DIR" && "$NODE_BIN" node_modules/@electron/asar/bin/asar.js "$@" )
}

quit_claude() {
  step "Quitting Claude..."
  osascript -e 'tell application "Claude" to quit' 2>/dev/null || true
  # Wait up to 5s for it to actually exit
  for _ in 1 2 3 4 5; do
    pgrep -x "Claude" >/dev/null || break
    sleep 1
  done
  pkill -x "Claude" 2>/dev/null || true
  sleep 1
}

# Electron's ElectronAsarIntegrity is SHA-256 of the asar HEADER JSON,
# NOT of the whole file. Compute it the same way Electron does.
asar_header_hash() {
  local target="${1:-$ASAR}"
  ( cd "$TOOL_DIR" && "$NODE_BIN" -e "
    const asar = require('@electron/asar');
    const crypto = require('crypto');
    const { headerString } = asar.getRawHeader(process.argv[1]);
    process.stdout.write(crypto.createHash('sha256').update(headerString).digest('hex'));
  " "$target" )
}

plist_hash() {
  /usr/libexec/PlistBuddy -c "Print :ElectronAsarIntegrity:Resources/app.asar:hash" "$PLIST" 2>/dev/null || echo ""
}

is_patched() {
  # "patched" = our marker file present inside the asar
  asar_run list "$ASAR" 2>/dev/null | grep -q "/$MARKER$"
}

claude_version() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || echo "?"
}

cmd_status() {
  ensure_prereqs
  c_dim "Claude version:    $(claude_version)"
  c_dim "asar header hash:  $(asar_header_hash)"
  c_dim "Info.plist hash:   $(plist_hash)"
  if is_patched; then
    c_green "● PATCHED (RTL auto-direction active)"
  else
    c_yellow "○ not patched"
  fi
  if [ -f "$BACKUP_ASAR" ]; then
    c_dim "Backup present: $BACKUP_ASAR"
    c_dim "Backup header hash: $(asar_header_hash "$BACKUP_ASAR")"
    [ -f "$BACKUP_VERSION" ] && c_dim "Backup taken from Claude version: $(cat "$BACKUP_VERSION")"
  else
    c_dim "No backup recorded."
  fi
}

cmd_apply() {
  ensure_prereqs

  if is_patched; then
    c_green "Already patched. Nothing to do."
    c_dim "Run with --revert to undo, or --status to inspect."
    exit 0
  fi

  quit_claude

  # Snapshot originals (only if we don't have a clean backup yet)
  mkdir -p "$STATE_DIR"
  if [ ! -f "$BACKUP_ASAR" ]; then
    step "Saving pristine backup → $BACKUP_ASAR"
    sudo cp "$ASAR" "$BACKUP_ASAR"
    plist_hash > "$BACKUP_HASH"
    claude_version > "$BACKUP_VERSION"
  else
    c_dim "Reusing existing backup at $BACKUP_ASAR"
    c_dim "(if Claude was updated since backup, run --revert first, then re-apply)"
  fi

  WORK="$(mktemp -d)/claude-asar"
  step "Extracting asar → $WORK"
  asar_run extract "$ASAR" "$WORK"

  step "Writing RTL injector module..."
  cat > "$WORK/$MARKER" <<'JS'
// Injected by claude-rtl-patch.sh — applies per-paragraph auto direction
// (sentence-leading character decides RTL or LTR) to every Claude window.
const { app } = require('electron');

const CSS = `
  /* Inputs: first strong char per paragraph decides direction */
  textarea, input[type="text"], input:not([type]),
  [contenteditable=""], [contenteditable="true"], .ProseMirror {
    unicode-bidi: plaintext !important;
    text-align: start !important;
  }
  /* Rendered text: same treatment, per block */
  p, li, blockquote, h1, h2, h3, h4, h5, h6,
  .prose, .markdown, .message, .message-content,
  [class*="message"] p, [class*="message"] li {
    unicode-bidi: plaintext !important;
  }
  /* Code stays LTR no matter what */
  pre, code, pre *, .hljs, .hljs * {
    unicode-bidi: isolate !important;
    direction: ltr !important;
    text-align: left !important;
  }
`;

const JS_PAYLOAD = `
  (() => {
    if (window.__claudeRtlPatchApplied) return;
    window.__claudeRtlPatchApplied = true;
    const sel = 'textarea, input[type="text"], [contenteditable=""], [contenteditable="true"], .ProseMirror';
    const apply = (root) => {
      const q = root.querySelectorAll ? root.querySelectorAll(sel) : [];
      q.forEach(el => { if (el.getAttribute('dir') !== 'auto') el.setAttribute('dir','auto'); });
    };
    const safe = (root) => { try { apply(root); } catch (e) {} };
    safe(document);
    new MutationObserver(ms => {
      for (const m of ms) for (const n of m.addedNodes) if (n && n.nodeType === 1) safe(n);
    }).observe(document.documentElement, { childList: true, subtree: true });
  })();
`;

function attach(wc) {
  if (!wc || wc.__claudeRtlPatched) return;
  wc.__claudeRtlPatched = true;
  const run = () => {
    wc.insertCSS(CSS).catch(() => {});
    wc.executeJavaScript(JS_PAYLOAD).catch(() => {});
  };
  wc.on('did-finish-load', run);
  wc.on('did-frame-finish-load', run);
  wc.on('did-navigate-in-page', run);
}

app.on('browser-window-created', (_, win) => attach(win.webContents));
app.on('web-contents-created', (_, wc) => attach(wc));
JS

  step "Wiring injector into entry point..."
  ENTRY="$WORK/.vite/build/index.pre.js"
  [ -f "$ENTRY" ] || die "Entry point not found: $ENTRY (Claude internal layout changed?)"
  if ! grep -q "$MARKER" "$ENTRY"; then
    {
      printf "try { require('../../%s'); } catch (e) { console.error('RTL patch load failed:', e); }\n" "$MARKER"
      cat "$ENTRY"
    } > "$ENTRY.tmp" && mv "$ENTRY.tmp" "$ENTRY"
  fi

  step "Repacking asar..."
  TMP_ASAR="$(mktemp -t claude-asar-XXXXXX).asar"
  asar_run pack "$WORK" "$TMP_ASAR"
  sudo mv "$TMP_ASAR" "$ASAR"

  step "Updating ElectronAsarIntegrity hash in Info.plist..."
  NEWHASH=$(asar_header_hash)
  sudo /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $NEWHASH" "$PLIST"
  c_dim "  new header hash: $NEWHASH"

  step "Ad-hoc re-signing the bundle..."
  sudo codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$APP"
  sudo xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

  rm -rf "$(dirname "$WORK")"

  c_green "✓ Patched. Launch Claude — mixed RTL/LTR will now auto-flow per paragraph."
  c_dim   "Revert anytime with: $0 --revert"
  echo
  c_yellow "Note: On first launch after patching, macOS may prompt to allow"
  c_yellow "Claude to access keychain items (auth token, cookies). Click"
  c_yellow "\"Always Allow\" 2-3 times — it stops after that."
}

cmd_revert() {
  ensure_prereqs
  [ -f "$BACKUP_ASAR" ] || die "No backup found at $BACKUP_ASAR — nothing to revert."

  quit_claude

  step "Restoring original app.asar from $BACKUP_ASAR..."
  sudo cp "$BACKUP_ASAR" "$ASAR"

  if [ -f "$BACKUP_HASH" ] && [ -s "$BACKUP_HASH" ]; then
    OLDHASH=$(cat "$BACKUP_HASH")
    step "Restoring ElectronAsarIntegrity hash → $OLDHASH"
    sudo /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $OLDHASH" "$PLIST"
  else
    c_yellow "No saved Info.plist hash; recomputing from restored asar..."
    OLDHASH=$(asar_header_hash)
    sudo /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $OLDHASH" "$PLIST"
  fi

  step "Ad-hoc re-signing to keep Gatekeeper happy..."
  sudo codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$APP"
  sudo xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

  c_green "✓ Reverted. Claude is back to its original state."
  c_dim   "Backup retained at $BACKUP_ASAR. Delete $STATE_DIR if you don't need it."
}

RC_FILE="${ZDOTDIR:-$HOME}/.zshrc"
RC_BEGIN="# >>> claude-rtl-patch shortcut >>>"
RC_END="# <<< claude-rtl-patch shortcut <<<"
CANONICAL_DIR="$HOME/.claude"
CANONICAL_PATH="$CANONICAL_DIR/claude-rtl-patch.sh"
SOURCE_PATH="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"

cmd_install() {
  # 1) Copy ourselves to the canonical home so the user can delete the
  #    original (e.g. from ~/Downloads) without breaking the alias.
  #    Always overwrites — `--install` is the "update" path too.
  mkdir -p "$CANONICAL_DIR"
  if [ "$SOURCE_PATH" = "$CANONICAL_PATH" ]; then
    c_dim "Running from canonical location — script already in place."
  elif [ -f "$CANONICAL_PATH" ]; then
    step "Overwriting existing script → $CANONICAL_PATH"
    cp -f "$SOURCE_PATH" "$CANONICAL_PATH"
    chmod +x "$CANONICAL_PATH"
  else
    step "Installing script → $CANONICAL_PATH"
    cp "$SOURCE_PATH" "$CANONICAL_PATH"
    chmod +x "$CANONICAL_PATH"
  fi

  # 2) Wire up the zshrc alias (pointing at the canonical copy).
  [ -e "$RC_FILE" ] || touch "$RC_FILE"
  if grep -q "$RC_BEGIN" "$RC_FILE"; then
    c_yellow "Alias already present in $RC_FILE — leaving it alone."
    c_dim    "(Script at $CANONICAL_PATH was refreshed.)"
  else
    step "Adding 'claude-rtl' alias to $RC_FILE"
    {
      printf "\n%s\n" "$RC_BEGIN"
      printf "alias claude-rtl=%q\n" "$CANONICAL_PATH"
      printf "%s\n" "$RC_END"
    } >> "$RC_FILE"
  fi

  c_green "✓ Installed."
  c_dim   "Script is safe at: $CANONICAL_PATH (original can be deleted)"
  c_dim   "Open a new terminal (or: source $RC_FILE), then use:"
  c_dim   "  claude-rtl              # apply"
  c_dim   "  claude-rtl --revert     # undo"
  c_dim   "  claude-rtl --status     # inspect"
}

cmd_uninstall() {
  if [ ! -f "$RC_FILE" ] || ! grep -q "$RC_BEGIN" "$RC_FILE"; then
    c_yellow "No shortcut block found in $RC_FILE — nothing to remove."
    exit 0
  fi
  step "Removing 'claude-rtl' alias from $RC_FILE"
  # Strip the sentinel block (BSD sed compatible).
  cp "$RC_FILE" "$RC_FILE.bak.$(date +%s)"
  awk -v b="$RC_BEGIN" -v e="$RC_END" '
    $0 ~ b {skip=1; next}
    $0 ~ e {skip=0; next}
    !skip
  ' "$RC_FILE" > "$RC_FILE.tmp" && mv "$RC_FILE.tmp" "$RC_FILE"
  c_green "✓ Removed. Open a new terminal for it to take effect."
}

cmd_help() {
  cat <<EOF
Claude Desktop RTL patch (macOS)

Makes mixed RTL/LTR text (Persian, Arabic, Hebrew + English) auto-direct
per paragraph. First strong character decides direction.

Usage:
  $0                  apply the patch (idempotent; safe to re-run)
  $0 --revert         restore the original Claude.app
  $0 --status         show current state and backup info
  $0 --install        add 'claude-rtl' shortcut to ~/.zshrc
  $0 --uninstall      remove the 'claude-rtl' shortcut from ~/.zshrc
  $0 --help           this message

Notes:
  - Requires sudo (writes into /Applications/Claude.app).
  - Backup of the original app.asar is saved in: $STATE_DIR
  - Re-signs the bundle ad-hoc (Apple notarization is lost, locally-only fine).
  - When Claude auto-updates, the patch is wiped — just re-run this script.
EOF
}

case "${1:-apply}" in
  apply|"")       cmd_apply ;;
  --revert|-r)    cmd_revert ;;
  --status|-s)    cmd_status ;;
  --install|-i)   cmd_install ;;
  --uninstall|-u) cmd_uninstall ;;
  --help|-h)      cmd_help ;;
  *)              cmd_help; exit 1 ;;
esac
