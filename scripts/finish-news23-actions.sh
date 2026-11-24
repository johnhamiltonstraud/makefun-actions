#!/usr/bin/env bash
# finish-news23-actions.sh — port of the VM's finish-news23.sh for the runner.
# Same steps (validate twice byte-identical, commit incl. entry.png, bundle
# --no-discover --no-family, check, submit). Paths come from env set by
# run-news23.sh:
#   WORK, REPO, STAGE, KIT, CLI, KP, MAKEFUN_CREDENTIALS
# Usage: finish-news23-actions.sh <N> "<title>" <buildlog> [rollout] [rollout2] [lane] [opencode_dir]
# Codex lane passes a rollout session file; OpenCode lanes pass the lane
# name (opencode-hms / opencode-dotai) and the opencode store dir, and
# bundle names the SQLite store with --session (opencode.db) instead of
# --opencode-dir — see step 3 for why.
# Exits 0 only when submit returns a claim code AF-...
set -u
N=${1:?}; TITLE=${2:?}; BUILDLOG=${3:?}; ROLLOUT_ARG=${4:-}; ROLLOUT2=${5:-}; LANE_ARG=${6:-codex}; OPENCODE_DIR_ARG=${7:-}
export GIT_DISCOVERY_ACROSS_FILESYSTEM=1 GIT_TERMINAL_PROMPT=0 LC_ALL=C
W="${WORK:?}"; REPO="${REPO:?}"; STAGE="${STAGE:?}"; KIT="${KIT:?}"
CLI="${CLI:?}"; KP="${KP:?}"
export MAKEFUN_CREDENTIALS="${MAKEFUN_CREDENTIALS:?}"
LOG="$W/finish-w$N-news23.log"
: > "$LOG"
say() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

[ -f "$STAGE/main.py" ] || { say "FAIL: no $STAGE/main.py"; exit 1; }
[ -f "$STAGE/README.md" ] || { say "FAIL: no $STAGE/README.md"; exit 1; }

# 1. validate: run twice in temp dirs, byte-identical, PNG 1024x1024, 60KB-1MiB, CRCs valid
#    The validated PNG is saved to $W/validated-entry.png — step 2 commits it.
#    (Never copy STAGE/entry.png: it may be stale if the agent edited main.py
#    after its last run.)
python3 - "$STAGE" "$W/validated-entry.png" <<'PY' || { echo "VALIDATE FAILED"; exit 1; }
import hashlib, os, shutil, struct, subprocess, sys, tempfile, zlib
stage = sys.argv[1]
def run(d):
    import shutil
    os.makedirs(d, exist_ok=True)
    shutil.copy(os.path.join(stage, "main.py"), os.path.join(d, "main.py"))
    subprocess.run([sys.executable, os.path.join(d, "main.py")], cwd=d, check=True)
    return os.path.join(d, "entry.png")
with tempfile.TemporaryDirectory() as t:
    a, b = run(os.path.join(t, "a")), run(os.path.join(t, "b"))
    ha = hashlib.sha256(open(a, "rb").read()).hexdigest()
    hb = hashlib.sha256(open(b, "rb").read()).hexdigest()
    assert ha == hb, f"non-deterministic: {ha} != {hb}"
    data = open(a, "rb").read()
    assert 60000 <= len(data) <= 1048576, f"size {len(data)}"
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not PNG"
    w, h = struct.unpack(">II", data[16:24])
    assert (w, h) == (1024, 1024), f"dims {w}x{h}"
    pos = 8
    while pos < len(data):
        ln, typ = struct.unpack(">I4s", data[pos:pos+8])
        chunk = data[pos+8:pos+8+ln]
        crc_stored, = struct.unpack(">I", data[pos+8+ln:pos+12+ln])
        assert zlib.crc32(typ + chunk) & 0xFFFFFFFF == crc_stored, f"bad CRC {typ}"
        pos += 12 + ln
        if typ == b"IEND": break
    print(f"VALIDATE OK sha256={ha} size={len(data)}")
    shutil.copy(a, sys.argv[2])
PY
say "validate OK"

# 2. copy into repo, commit (author = this wallet's address, like prior wallets)
#    entry.png MUST be committed: the 9 wave59 HMS + 1 Codex-test entries were
#    all REJECTED round 1 because the repo held only 4 files (no entry.png,
#    source bundle 7-12KB). The validated PNG from step 1 is authoritative.
WALLET=$(python3 -c "import json;print(json.load(open('$MAKEFUN_CREDENTIALS'))['keys']['https://make.fun']['wallet'])")
cp "$STAGE/main.py" "$STAGE/README.md" "$REPO/"
[ -f "$W/validated-entry.png" ] || { say "FAIL: no validated entry.png from step 1"; exit 1; }
cp "$W/validated-entry.png" "$REPO/entry.png"
git -C "$REPO" config user.name "$WALLET"
git -C "$REPO" config user.email "$WALLET"
git -C "$REPO" add main.py README.md entry.png >>"$LOG" 2>&1
if git -C "$REPO" status --porcelain | grep -q .; then
  git -C "$REPO" commit -m "$TITLE" >>"$LOG" 2>&1 || { say "FAIL: git commit"; exit 1; }
else
  say "nothing new to commit, reusing HEAD"
fi
SHA=$(git -C "$REPO" rev-parse HEAD)
say "committed $SHA"

# 3. Transcript source: Codex lane passes a rollout session file (passed
#    in by the runner script; fallback: newest); OpenCode lanes pass the
#    opencode SQLite store. OpenCode 1.19.6 keeps sessions ONLY in
#    opencode.db — --opencode-dir finds the store but drops the session
#    when its directory is not the entry repo (the build runs from $WORK,
#    the repo lives in _temp), which is exactly how run 45265104229 died:
#    "no session of .../entry-repo-w210 was found". Naming the db with
#    --session bundles it whole (verified locally 24 Nov: a copied
#    opencode.db bundled into a valid tarball, exit 0).
ROLLOUT="$ROLLOUT_ARG"
OPENCODE_DB=""
if [ -n "$OPENCODE_DIR_ARG" ] && [ -f "$OPENCODE_DIR_ARG/opencode.db" ] && [ "$LANE_ARG" != "codex" ]; then
  OPENCODE_DB="$OPENCODE_DIR_ARG/opencode.db"
  say "lane $LANE_ARG: opencode session db $OPENCODE_DB"
else
  if [ -z "$ROLLOUT" ] || [ ! -f "$ROLLOUT" ]; then
    ROLLOUT=$(find "$HOME/.codex/sessions" -name '*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
  fi
  [ -f "$ROLLOUT" ] || { say "FAIL: no rollout session found"; exit 1; }
  say "rollout $ROLLOUT"
fi

# 4. bundle (transcript, --no-discover --no-family, fresh kit)
#    --instructions none: the runner's Codex was started with the prompt as
#    a CLI argument and the runner has no instruction files at all (no
#    AGENTS.md/CLAUDE.md in the repo or the harness config), so bundle
#    refuses to write one until we say so — run 44827086802 failed here.
#    The kit refuses the flag while it finds instruction files, so this
#    stays truthful: it only passes where there genuinely are none.
BUNDLE=$W/bundle-news23-w$N.tar.gz
EXTRA_SESSION=""
if [ -n "$ROLLOUT2" ]; then EXTRA_SESSION="--session $ROLLOUT2"; fi
# shellcheck disable=SC2086
if [ -n "$OPENCODE_DB" ]; then
  # OpenCode sessions carry no system prompt and no MCP list, so pass the
  # build prompt as --system-prompt (the instructions the agent was
  # started with) and --mcp none (opencode runs use no MCP servers); and
  # do NOT pass --instructions none — bundle collects opencode.json(.jsonc)
  # as the instruction files it ran with and refuses the flag while it
  # finds any. All three verified locally 24 Nov (bundle exit 0).
  node "$CLI" bundle --repo "$REPO" --out "$BUNDLE" --session "$OPENCODE_DB" --no-discover --no-family --effort default --mcp none --system-prompt "$W/prompt-w$N-news23.txt" >>"$LOG" 2>&1 \
    || { say "FAIL: bundle (opencode)"; tail -20 "$LOG"; exit 1; }
else
  node "$CLI" bundle --repo "$REPO" --out "$BUNDLE" --session "$ROLLOUT" $EXTRA_SESSION --no-discover --no-family --effort default --instructions none >>"$LOG" 2>&1 \
    || { say "FAIL: bundle"; tail -20 "$LOG"; exit 1; }
fi
say "bundle OK $BUNDLE"

# 5. check (kit's own pre-submit checks)
node "$CLI" check --kit "$KIT" --repo "$REPO" --commit "$SHA" --transcripts "$BUNDLE" >>"$LOG" 2>&1 \
  || { say "FAIL: check"; tail -30 "$LOG"; exit 1; }
say "check OK"

# 6. submit
SUBOUT=$W/submit-w$N-news23.out
node "$CLI" submit --competition news-image-20261123 --source "$REPO" --commit "$SHA" \
  --title "$TITLE" --bundle "$BUNDLE" --keypair "$KP" --json >"$SUBOUT" 2>"$W/submit-w$N-news23.err" \
  || { say "FAIL: submit"; tail -30 "$SUBOUT" "$W/submit-w$N-news23.err"; exit 1; }
CLAIM=$(grep -o -m1 'AF-[A-Z0-9]\{5\}-[A-Z0-9]\{5\}-[A-Z0-9]\{5\}-[A-Z0-9]\{5\}' "$SUBOUT" || true)
SUBID=$(python3 -c "import json,sys; d=json.load(open('$SUBOUT')); print(d.get('submission_id') or d.get('id') or '')" 2>/dev/null || true)
say "SUBMIT OK claim=$CLAIM submission=$SUBID sha=$SHA"
echo "CLAIM=$CLAIM"
echo "SUBMISSION=$SUBID"
echo "SHA=$SHA"
exit 0
