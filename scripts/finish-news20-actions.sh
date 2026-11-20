#!/usr/bin/env bash
# finish-news20-actions.sh — port of the VM's finish-news20.sh for the runner.
# Same steps (validate twice byte-identical, commit, bundle --no-discover
# --no-family, check, submit). Paths come from env set by run-news20.sh:
#   WORK, REPO, STAGE, KIT, CLI, KP, MAKEFUN_CREDENTIALS
# Usage: finish-news20-actions.sh <N> "<title>" <buildlog> [rollout] [rollout2]
# Exits 0 only when submit returns a claim code AF-...
set -u
N=${1:?}; TITLE=${2:?}; BUILDLOG=${3:?}; ROLLOUT_ARG=${4:-}; ROLLOUT2=${5:-}
export GIT_DISCOVERY_ACROSS_FILESYSTEM=1 GIT_TERMINAL_PROMPT=0 LC_ALL=C
W="${WORK:?}"; REPO="${REPO:?}"; STAGE="${STAGE:?}"; KIT="${KIT:?}"
CLI="${CLI:?}"; KP="${KP:?}"
export MAKEFUN_CREDENTIALS="${MAKEFUN_CREDENTIALS:?}"
LOG="$W/finish-w$N-news20.log"
: > "$LOG"
say() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

[ -f "$STAGE/main.py" ] || { say "FAIL: no $STAGE/main.py"; exit 1; }
[ -f "$STAGE/README.md" ] || { say "FAIL: no $STAGE/README.md"; exit 1; }

# 1. validate: run twice in temp dirs, byte-identical, PNG 1024x1024, 60KB-1MiB, CRCs valid
python3 - "$STAGE" <<'PY' || { echo "VALIDATE FAILED"; exit 1; }
import hashlib, os, struct, subprocess, sys, tempfile, zlib
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
PY
say "validate OK"

# 2. copy into repo, commit (author = this wallet's address, like prior wallets)
WALLET=$(python3 -c "import json;print(json.load(open('$MAKEFUN_CREDENTIALS'))['keys']['https://make.fun']['wallet'])")
cp "$STAGE/main.py" "$STAGE/README.md" "$REPO/"
git -C "$REPO" config user.name "$WALLET"
git -C "$REPO" config user.email "$WALLET"
git -C "$REPO" add main.py README.md >>"$LOG" 2>&1
if git -C "$REPO" status --porcelain | grep -q .; then
  git -C "$REPO" commit -m "$TITLE" >>"$LOG" 2>&1 || { say "FAIL: git commit"; exit 1; }
else
  say "nothing new to commit, reusing HEAD"
fi
SHA=$(git -C "$REPO" rev-parse HEAD)
say "committed $SHA"

# 3. rollout session file (passed in by the runner script; fallback: newest)
ROLLOUT="$ROLLOUT_ARG"
if [ -z "$ROLLOUT" ] || [ ! -f "$ROLLOUT" ]; then
  ROLLOUT=$(find "$HOME/.codex/sessions" -name '*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
fi
[ -f "$ROLLOUT" ] || { say "FAIL: no rollout session found"; exit 1; }
say "rollout $ROLLOUT"

# 4. bundle (transcript, --no-discover --no-family, fresh kit)
#    --instructions none: the runner's Codex was started with the prompt as
#    a CLI argument and the runner has no instruction files at all (no
#    AGENTS.md/CLAUDE.md in the repo or the harness config), so bundle
#    refuses to write one until we say so — run 44827086802 failed here.
#    The kit refuses the flag while it finds instruction files, so this
#    stays truthful: it only passes where there genuinely are none.
BUNDLE=$W/bundle-news20-w$N.tar.gz
EXTRA_SESSION=""
if [ -n "$ROLLOUT2" ]; then EXTRA_SESSION="--session $ROLLOUT2"; fi
# shellcheck disable=SC2086
node "$CLI" bundle --repo "$REPO" --out "$BUNDLE" --session "$ROLLOUT" $EXTRA_SESSION --no-discover --no-family --effort default --instructions none >>"$LOG" 2>&1 \
  || { say "FAIL: bundle"; tail -20 "$LOG"; exit 1; }
say "bundle OK $BUNDLE"

# 5. check (kit's own pre-submit checks)
node "$CLI" check --kit "$KIT" --repo "$REPO" --commit "$SHA" --transcripts "$BUNDLE" >>"$LOG" 2>&1 \
  || { say "FAIL: check"; tail -30 "$LOG"; exit 1; }
say "check OK"

# 6. submit
SUBOUT=$W/submit-w$N-news20.out
node "$CLI" submit --competition news-image-20261120 --source "$REPO" --commit "$SHA" \
  --title "$TITLE" --bundle "$BUNDLE" --keypair "$KP" --instructions none --json >"$SUBOUT" 2>"$W/submit-w$N-news20.err" \
  || { say "FAIL: submit"; tail -30 "$SUBOUT" "$W/submit-w$N-news20.err"; exit 1; }
CLAIM=$(grep -o -m1 'AF-[A-Z0-9]\{5\}-[A-Z0-9]\{5\}-[A-Z0-9]\{5\}-[A-Z0-9]\{5\}' "$SUBOUT" || true)
SUBID=$(python3 -c "import json,sys; d=json.load(open('$SUBOUT')); print(d.get('submission_id') or d.get('id') or '')" 2>/dev/null || true)
say "SUBMIT OK claim=$CLAIM submission=$SUBID sha=$SHA"
echo "CLAIM=$CLAIM"
echo "SUBMISSION=$SUBID"
echo "SHA=$SHA"
exit 0
