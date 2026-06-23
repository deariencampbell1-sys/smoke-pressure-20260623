#!/bin/bash
# compute pressure-test driver for lane-3
# Uses ABSOLUTE paths everywhere — never relies on $WORKDIR env expansion inside heredocs.
set -u
WORK="/opt/rhobear/projects/smoke-pressure2-20260623/lane-3"
PROG="$WORK/PROGRESS.log"
BURN_SEC="${BURN_SEC:-300}"   # 5min sustained burn-in
BURN_WORKERS="${BURN_WORKERS:-8}"

cd "$WORK"
touch "$PROG"
progress() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$PROG"; }

# Step 1
progress "lane-3-minimax compute-start pid=$$"
progress "step 1/4 generating 500MB random dataset"
dd if=/dev/urandom of="$WORK/dataset.bin" bs=1M count=500 status=none
progress "step 1/4 done bytes=$(stat -c%s $WORK/dataset.bin)"

# Step 2 — chunked SHA-256 hash, 100 chunks of 5MB each (main load)
progress "step 2/4 hashing 100x5MB chunks"
for i in $(seq 0 99); do
  dd if="$WORK/dataset.bin" bs=5M skip=$i count=1 status=none 2>/dev/null | sha256sum | awk '{print $1}' >> "$WORK/hashes.txt"
  if [ $((i % 10)) -eq 0 ]; then progress "  hashed $i/100"; fi
done
progress "step 2/4 done lines=$(wc -l < $WORK/hashes.txt)"

# Step 3 — python analysis
progress "step 3/4 running python analysis"
python3 -B - "$WORK/hashes.txt" "$WORK/analysis.json" <<'PY' 2>>"$PROG"
import sys, json
from collections import Counter
hashes_path, out_path = sys.argv[1], sys.argv[2]
lines = open(hashes_path).read().strip().split("\n")
prefixes = Counter(h[:4] for h in lines)
out = {
  "total_chunks": len(lines),
  "unique_4hex_prefixes": len(prefixes),
  "theoretical_max": 65536,
  "top_10_prefixes": dict(prefixes.most_common(10)),
  "expected_per_prefix": round(len(lines)/65536.0, 3),
}
open(out_path, "w").write(json.dumps(out, indent=2))
print("analysis done", out["total_chunks"], "chunks", flush=True)
PY
progress "step 3/4 done analysis.json=$(stat -c%s $WORK/analysis.json)B"

# Step 3.5 — sustained SHA-256 burn-in via THREADS to actually hit 8min wall clock
progress "step 3.5/4 sustained SHA-256 burn-in target=${BURN_SEC}s, ${BURN_WORKERS} threads"
BURN_SEC="$BURN_SEC" BURN_WORKERS="$BURN_WORKERS" BURN_OUT="$WORK/burnin.json" \
  python3 -B "$WORK/burn.py" >"$WORK/burn.stdout" 2>>"$PROG"
progress "step 3.5/4 done burnin.json=$(stat -c%s $WORK/burnin.json)B"

# Step 4 — final hash + cleanup
progress "step 4/4 final hash + cleanup"
FINAL=$(sha256sum "$WORK/dataset.bin" | awk '{print $1}')
rm -f "$WORK/dataset.bin"
progress "step 4/4 done final=$FINAL"

# Step 5 — result.json
cat > "$WORK/result.json" <<EOF
{
  "lane": "lane-3-minimax",
  "pool": "minimax",
  "model": "MiniMax-M3",
  "chunks_hashed": $(wc -l < $WORK/hashes.txt),
  "analysis_bytes": $(stat -c%s $WORK/analysis.json),
  "final_sha256": "$FINAL",
  "completed_at": "$(date -u +%FT%TZ)"
}
EOF
progress "result.json written $(stat -c%s $WORK/result.json)B"
progress "lane-3-minimax compute-DONE"
