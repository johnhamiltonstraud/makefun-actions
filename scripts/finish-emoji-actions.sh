#!/usr/bin/env bash
# finish-emoji-actions.sh — port of finish-news23-actions.sh for One Emoji One Smile.
# Same steps (validate twice byte-identical, commit, bundle --no-discover
# --no-family, check, submit) but for entry.txt, NOT entry.png, and with NO
# README requirement (local emoji repos hold only main.py + LICENSE + .makefun).
# Paths come from env set by run-emoji-codex.sh:
#   WORK, REPO, STAGE, KIT, CLI, KP, MAKEFUN_CREDENTIALS
# Usage: finish-emoji-actions.sh <N> "<emoji>" <buildlog> [rollout] [rollout2] [lane] [opencode_dir]
# Codex lane passes a rollout session file. Exits 0 only when submit returns
# a claim code AF-...
set -u
N=${1:?}; EMOJI=${2:?}; BUILDLOG=${3:?}; ROLLOUT_ARG=${4:-}; ROLLOUT2=${5:-}; LANE_ARG=${6:-codex}; OPENCODE_DIR_ARG=${7:-}
export GIT_DISCOVERY_ACROSS_FILESYSTEM=1 GIT_TERMINAL_PROMPT=0 LC_ALL=C
W="${WORK:?}"; REPO="${REPO:?}"; STAGE="${STAGE:?}"; KIT="${KIT:?}"
CLI="${CLI:?}"; KP="${KP:?}"
export MAKEFUN_CREDENTIALS="${MAKEFUN_CREDENTIALS:?}"
LOG="$W/finish-w$N-emoji.log"
: > "$LOG"
say() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

[ -f "$STAGE/main.py" ] || { say "FAIL: no $STAGE/main.py"; exit 1; }

# 1. validate: run twice in temp dirs, byte-identical entry.txt, content
#    exactly the assigned emoji (UTF-8, 1-8 characters, no trailing newline).
#    The validated entry.txt is saved to $W/validated-entry.txt.
#    (Never copy STAGE/entry.txt: it may be stale if the agent edited main.py
#    after its last run.)
python3 - "$STAGE" "$W/validated-entry.txt" "$EMOJI" <<'PY' || { echo "VALIDATE FAILED"; exit 1; }
import hashlib, os, shutil, subprocess, sys, tempfile
stage, dest, emoji = sys.argv[1], sys.argv[2], sys.argv[3]
want = emoji.encode("utf-8")
def run(d):
    os.makedirs(d, exist_ok=True)
    shutil.copy(os.path.join(stage, "main.py"), os.path.join(d, "main.py"))
    subprocess.run([sys.executable, os.path.join(d, "main.py")], cwd=d, check=True)
    return os.path.join(d, "entry.txt")
with tempfile.TemporaryDirectory() as t:
    a, b = run(os.path.join(t, "a")), run(os.path.join(t, "b"))
    da, db = open(a, "rb").read(), open(b, "rb").read()
    assert da == db, "non-deterministic entry.txt"
    assert da == want, f"entry.txt {da!r} != assigned emoji {want!r}"
    nchars = len(da.decode("utf-8"))
    assert 1 <= nchars <= 8, f"chars {nchars}"
    assert not da.endswith(b"\n"), "trailing newline"
    print(f"VALIDATE OK sha256={hashlib.sha256(da).hexdigest()} chars={nchars}")
    shutil.copy(a, dest)
PY
say "validate OK"

# 2. copy into repo, commit (author = this wallet's address, like prior wallets).
#    main.py is required; README.md is copied only if the builder wrote one
#    (local emoji repos have no README). entry.txt is NOT committed: the
#    program generates it at grading time; the repo holds the program.
WALLET=$(python3 -c "import json;print(json.load(open('$MAKEFUN_CREDENTIALS'))['keys']['https://make.fun']['wallet'])")
cp "$STAGE/main.py" "$REPO/"
[ -f "$STAGE/README.md" ] && cp "$STAGE/README.md" "$REPO/"
git -C "$REPO" config user.name "$WALLET"
git -C "$REPO" config user.email "$WALLET"
git -C "$REPO" add main.py README.md >>"$LOG" 2>&1
if git -C "$REPO" status --porcelain | grep -q .; then
  git -C "$REPO" commit -m "$EMOJI" >>"$LOG" 2>&1 || { say "FAIL: git commit"; exit 1; }
else
  say "nothing new to commit, reusing HEAD"
fi
SHA=$(git -C "$REPO" rev-parse HEAD)
say "committed $SHA"

# 3. Transcript source: Codex lane passes a rollout session file (passed
#    in by the runner script; fallback: newest); OpenCode lanes pass the
#    opencode SQLite store. See finish-news23-actions.sh step 3 for why the
#    opencode db is named with --session instead of --opencode-dir.
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
#    refuses to write one until we say so. The kit refuses the flag while it
#    finds instruction files, so this stays truthful: it only passes where
#    there genuinely are none.
BUNDLE=$W/bundle-emoji-w$N.tar.gz
EXTRA_SESSION=""
if [ -n "$ROLLOUT2" ]; then EXTRA_SESSION="--session $ROLLOUT2"; fi
# shellcheck disable=SC2086
if [ -n "$OPENCODE_DB" ]; then
  node "$CLI" bundle --repo "$REPO" --out "$BUNDLE" --session "$OPENCODE_DB" --no-discover --no-family --effort default --mcp none --system-prompt "$W/prompt-w$N-emoji.txt" >>"$LOG" 2>&1 \
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

# 6. submit — --commit takes the FULL explicit SHA (bare --commit is rejected:
#    "argument is ambiguous", finisher W2114 lesson). Title is the emoji.
SUBOUT=$W/submit-w$N-emoji.out
node "$CLI" submit --competition u-0xkianno-one-emoji-one-smile-5470751f --source "$REPO" --commit "$SHA" \
  --title "$EMOJI" --bundle "$BUNDLE" --keypair "$KP" --json >"$SUBOUT" 2>"$W/submit-w$N-emoji.err" \
  || { say "FAIL: submit"; tail -30 "$SUBOUT" "$W/submit-w$N-emoji.err"; exit 1; }
CLAIM=$(grep -o -m1 'AF-[A-Z0-9]\{5\}-[A-Z0-9]\{5\}-[A-Z0-9]\{5\}-[A-Z0-9]\{5\}' "$SUBOUT" || true)
SUBID=$(python3 -c "import json,sys; d=json.load(open('$SUBOUT')); print(d.get('submission_id') or d.get('id') or '')" 2>/dev/null || true)
say "SUBMIT OK claim=$CLAIM submission=$SUBID sha=$SHA"
echo "CLAIM=$CLAIM"
echo "SUBMISSION=$SUBID"
echo "SHA=$SHA"
exit 0
