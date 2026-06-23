#!/usr/bin/env bash
# lane-4-minimax compute pressure-test worker (8-min wall clock target)
# Canonical 6-step recipe + stretch (80 cycles of 500MB urandom + 8-way parallel SHA256)
set -u

WORKDIR="/opt/rhobear/projects/smoke-pressure2-20260623/lane-4"
export WORKDIR
PROG="$WORKDIR/PROGRESS.log"
: > "$PROG"   # truncate prior progress
START_TS=$(date -u +%s)
LAST_PROGRESS_TS=$START_TS

progress() {
  local now; now=$(date -u +%s)
  LAST_PROGRESS_TS=$now
  printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$PROG"
}

heartbeat() {
  local now; now=$(date -u +%s)
  if [ $((now - LAST_PROGRESS_TS)) -ge 25 ]; then
    progress "heartbeat elapsed=$((now - START_TS))s"
  fi
}

progress "lane-4-minimax compute-start pid=$$ workdir=$WORKDIR"

# ============ CANONICAL 6 STEPS ============
progress "step 1/4 generating 500MB random dataset"
dd if=/dev/urandom of="$WORKDIR/dataset.bin" bs=1M count=500 status=none
progress "step 1/4 done bytes=$(stat -c%s "$WORKDIR/dataset.bin")"

progress "step 2/4 hashing 100x5MB chunks"
: > "$WORKDIR/hashes.txt"
for i in $(seq 0 99); do
  dd if="$WORKDIR/dataset.bin" bs=5M skip=$i count=1 status=none 2>/dev/null \
    | sha256sum | awk '{print $1}' >> "$WORKDIR/hashes.txt"
  if [ $((i % 10)) -eq 0 ]; then progress "  hashed $i/100"; fi
done
progress "step 2/4 done lines=$(wc -l < "$WORKDIR/hashes.txt")"

progress "step 3/4 running python analysis"
WD="$WORKDIR" python3 - <<'PY'
import json, os
from collections import Counter
WD = os.environ["WD"]
lines = open(os.path.join(WD, "hashes.txt")).read().strip().split("\n")
prefixes = Counter(h[:4] for h in lines)
out = {
  "total_chunks": len(lines),
  "unique_4hex_prefixes": len(prefixes),
  "theoretical_max": 65536,
  "top_10_prefixes": dict(prefixes.most_common(10)),
  "expected_per_prefix": round(len(lines)/65536.0, 3),
}
open(os.path.join(WD, "analysis.json"), "w").write(json.dumps(out, indent=2))
print("analysis done", out["total_chunks"], "chunks")
PY
progress "step 3/4 done analysis.json=$(stat -c%s "$WORKDIR/analysis.json")B"

progress "step 4/4 final hash + cleanup"
FINAL=$(sha256sum "$WORKDIR/dataset.bin" | awk '{print $1}')
rm -f "$WORKDIR/dataset.bin"
progress "step 4/4 done final=$FINAL"

cat > "$WORKDIR/result.json" <<EOF
{
  "lane": "lane-4-minimax",
  "pool": "minimax",
  "model": "MiniMax-M3",
  "chunks_hashed": $(wc -l < "$WORKDIR/hashes.txt"),
  "analysis_bytes": $(stat -c%s "$WORKDIR/analysis.json"),
  "final_sha256": "$FINAL",
  "completed_at": "$(date -u +%FT%TZ)"
}
EOF
progress "result.json written $(stat -c%s "$WORKDIR/result.json")B"
progress "lane-4-minimax compute-CANONICAL-DONE elapsed=$(( $(date -u +%s) - START_TS ))s"

# ============ STRETCH: 80 cycles x (500MB urandom + 8-way parallel SHA256) ============
N_CYCLES=${N_CYCLES:-80}
CHUNKS_PER_CYCLE=${CHUNKS_PER_CYCLE:-100}
PARALLEL=${PARALLEL:-8}

progress "=== STRETCH START cycles=$N_CYCLES chunks/cycle=$CHUNKS_PER_CYCLE parallel=$PARALLEL ==="

STRETCH_SHA=""
: > "$WORKDIR/all_hashes.txt"

for c in $(seq 1 $N_CYCLES); do
  DS="$WORKDIR/stretch_${c}.bin"
  dd if=/dev/urandom of="$DS" bs=1M count=500 status=none

  PER=$(( (CHUNKS_PER_CYCLE + PARALLEL - 1) / PARALLEL ))
  TMPDIR="$WORKDIR/.tmp_$c"
  mkdir -p "$TMPDIR"
  for p in $(seq 0 $((PARALLEL-1))); do
    (
      start=$((p * PER))
      end=$(( start + PER - 1 ))
      [ $end -ge $CHUNKS_PER_CYCLE ] && end=$((CHUNKS_PER_CYCLE - 1))
      [ $start -gt $end ] && exit 0
      out="$TMPDIR/p${p}.txt"
      : > "$out"
      for i in $(seq $start $end); do
        dd if="$DS" bs=5M skip=$i count=1 status=none 2>/dev/null \
          | sha256sum | awk '{print $1}' >> "$out"
      done
    ) &
  done
  wait

  cat "$TMPDIR"/p*.txt >> "$WORKDIR/all_hashes.txt"
  rm -rf "$TMPDIR"

  CYCLE_FINAL=$(sha256sum "$DS" | awk '{print $1}')
  STRETCH_SHA="$CYCLE_FINAL"
  rm -f "$DS"

  progress "stretch cycle $c/$N_CYCLES done total_lines=$(wc -l < "$WORKDIR/all_hashes.txt")"
  heartbeat
done

progress "=== STRETCH COMPLETE total_lines=$(wc -l < "$WORKDIR/all_hashes.txt") final_stretch=$STRETCH_SHA ==="

WD="$WORKDIR" python3 - <<'PY'
import json, os
from collections import Counter
WD = os.environ["WD"]
lines = open(os.path.join(WD, "all_hashes.txt")).read().strip().split("\n")
prefixes = Counter(h[:4] for h in lines)
out = {
  "lane": "lane-4-minimax",
  "pool": "minimax",
  "model": "MiniMax-M3",
  "total_hashes": len(lines),
  "unique_4hex_prefixes": len(prefixes),
  "theoretical_max": 65536,
  "coverage_pct": round(100.0 * len(prefixes) / 65536.0, 3),
  "max_collision": max(prefixes.values()) if prefixes else 0,
  "top_5_prefixes": dict(prefixes.most_common(5)),
}
open(os.path.join(WD, "big_analysis.json"), "w").write(json.dumps(out, indent=2))
print("big_analysis done", out["total_hashes"], "hashes")
PY
progress "big_analysis.json written $(stat -c%s "$WORKDIR/big_analysis.json")B"

WD="$WORKDIR" STRETCH_FINAL="$STRETCH_SHA" START_TS="$START_TS" python3 - <<'PY'
import json, os, time
WD = os.environ["WD"]
r = json.load(open(os.path.join(WD, "result.json")))
b = json.load(open(os.path.join(WD, "big_analysis.json")))
r["stretch_chunks_hashed"] = b["total_hashes"]
r["stretch_unique_prefixes"] = b["unique_4hex_prefixes"]
r["stretch_final_sha256"] = os.environ["STRETCH_FINAL"]
r["wall_clock_seconds"] = int(time.time()) - int(os.environ["START_TS"])
r["progress_log_lines"] = sum(1 for _ in open(os.path.join(WD, "PROGRESS.log")))
open(os.path.join(WD, "result.json"), "w").write(json.dumps(r, indent=2))
PY

ELAPSED=$(($(date -u +%s) - START_TS))
progress "lane-4-minimax compute-DONE elapsed=${ELAPSED}s"

echo "DONE lane-4-minimax — $(wc -l < "$WORKDIR/hashes.txt") canonical chunks, $(wc -l < "$WORKDIR/all_hashes.txt") total chunks, final=${FINAL:0:16}..., elapsed=${ELAPSED}s"
exit 0
