#!/usr/bin/env bash
# lane-9-grok compute + supplemental to hit 8min wall clock
set -u
WORKDIR="/opt/rhobear/projects/smoke-pressure2-20260623/lane-9"
cd "$WORKDIR"
PROG="$WORKDIR/PROGRESS.log"
: > "$PROG"
START_EPOCH=$(date +%s)
progress() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$PROG"; }

progress "lane-9-grok compute-start pid=$$"
progress "step 1/4 generating 500MB random dataset"
dd if=/dev/urandom of="$WORKDIR/dataset.bin" bs=1M count=500 status=none
progress "step 1/4 done bytes=$(stat -c%s $WORKDIR/dataset.bin)"

progress "step 2/4 hashing 100x5MB chunks"
: > "$WORKDIR/hashes.txt"
for i in $(seq 0 99); do
  dd if="$WORKDIR/dataset.bin" bs=5M skip=$i count=1 status=none 2>/dev/null \
    | sha256sum | awk '{print $1}' >> "$WORKDIR/hashes.txt"
  if [ $((i % 10)) -eq 0 ]; then progress "  hashed $i/100"; fi
done
progress "step 2/4 done lines=$(wc -l < $WORKDIR/hashes.txt)"

progress "step 3/4 running python analysis"
python3 - <<'PY' 2>>"$PROG"
import json
from collections import Counter
lines = open("/opt/rhobear/projects/smoke-pressure2-20260623/lane-9/hashes.txt").read().strip().split("\n")
prefixes = Counter(h[:4] for h in lines)
out = {
  "total_chunks": len(lines),
  "unique_4hex_prefixes": len(prefixes),
  "theoretical_max": 65536,
  "top_10_prefixes": dict(prefixes.most_common(10)),
  "expected_per_prefix": round(len(lines)/65536.0, 3),
}
open("/opt/rhobear/projects/smoke-pressure2-20260623/lane-9/analysis.json","w").write(json.dumps(out, indent=2))
print("analysis done", out["total_chunks"], "chunks")
PY
progress "step 3/4 done analysis.json=$(stat -c%s $WORKDIR/analysis.json)B"

progress "step 4/4 final hash + cleanup"
FINAL=$(sha256sum "$WORKDIR/dataset.bin" | awk '{print $1}')
rm -f "$WORKDIR/dataset.bin"
progress "step 4/4 done final=$FINAL"

# Supplemental compute to extend wall clock to ~8 min (the test point is the load)
progress "supplemental compute phase — extending wall clock to ~8 min"
TARGET_SECS=480  # 8 min
PASS=0
while : ; do
  PASS=$((PASS+1))
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_EPOCH))
  TOTAL=$ELAPSED
  if [ $TOTAL -ge $TARGET_SECS ]; then
    progress "  supplemental pass $PASS elapsed=${ELAPSED}s total_sup=$((TOTAL - ELAPSED + ELAPSED))s — target reached"
    break
  fi
  # CPU-bound loop with occasional IO — burns wall clock + cycles
  python3 -c "
import hashlib, os, time, random, string
end = time.time() + 30
n = 0
while time.time() < end:
    s = ''.join(random.choices(string.ascii_letters + string.digits, k=4096))
    h = hashlib.sha256(s.encode()).hexdigest()
    n += 1
print(f'cpu_burn iters={n}', flush=True)
" >> "$PROG" 2>&1
  ELAPSED=$(($(date +%s) - START_EPOCH))
  progress "  supplemental pass $PASS elapsed=${ELAPSED}s total=${ELAPSED}s"
done
progress "supplemental done passes=$PASS total_secs=$(( $(date +%s) - START_EPOCH ))"

# Write result.json
CHUNKS=$(wc -l < "$WORKDIR/hashes.txt")
ABYTES=$(stat -c%s "$WORKDIR/analysis.json")
COMPLETED=$(date -u +%FT%TZ)
cat > "$WORKDIR/result.json" <<EOF
{
  "lane": "lane-9-grok",
  "pool": "minimax",
  "model": "grok-composer-2.5-fast",
  "chunks_hashed": $CHUNKS,
  "analysis_bytes": $ABYTES,
  "final_sha256": "$FINAL",
  "completed_at": "$COMPLETED"
}
EOF
progress "result.json written $(stat -c%s $WORKDIR/result.json)B"
progress "lane-9-grok compute-DONE total_secs=$(( $(date +%s) - START_EPOCH ))"
