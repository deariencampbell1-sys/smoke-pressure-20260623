#!/bin/bash
set -e
cd /opt/rhobear/projects/smoke-pressure2-20260623/lane-8
export WORKDIR=/opt/rhobear/projects/smoke-pressure2-20260623/lane-8
PROG="$WORKDIR/PROGRESS.log"
touch "$PROG"
progress() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$PROG"; }

# Slow loop to make the compute take longer (real pressure test)
SLOWDOWN=${SLOWDOWN:-60}   # default ~60s per chunk group on slow path

progress "lane-8-grok compute-start pid=$$"

# Step 1: 500MB random data
progress "step 1/4 generating 500MB random dataset"
dd if=/dev/urandom of="$WORKDIR/dataset.bin" bs=1M count=500 status=none
progress "step 1/4 done bytes=$(stat -c%s $WORKDIR/dataset.bin)"

# Step 2: chunked SHA-256 + slow pressure
progress "step 2/4 hashing 100x5MB chunks"
> "$WORKDIR/hashes.txt"
for i in $(seq 0 99); do
  dd if="$WORKDIR/dataset.bin" bs=5M skip=$i count=1 status=none 2>/dev/null \
    | sha256sum | awk '{print $1}' >> "$WORKDIR/hashes.txt"
  if [ $((i % 10)) -eq 0 ]; then
    progress "  hashed $i/100"
    # Slow loop: real CPU pressure for the swarm test
    python3 -c "import hashlib,os
data=os.urandom(1024*1024)
for _ in range($SLOWDOWN):
    hashlib.sha256(hashlib.sha256(data).digest()).digest()
" 2>/dev/null
  fi
done
progress "step 2/4 done lines=$(wc -l < $WORKDIR/hashes.txt)"

# Step 3: python analysis
progress "step 3/4 running python analysis"
python3 - "$WORKDIR/hashes.txt" "$WORKDIR/analysis.json" <<'PY' 2>>"$PROG"
import json, sys
from collections import Counter
lines = open(sys.argv[1]).read().strip().split("\n")
prefixes = Counter(h[:4] for h in lines)
out = {
  "total_chunks": len(lines),
  "unique_4hex_prefixes": len(prefixes),
  "theoretical_max": 65536,
  "top_10_prefixes": dict(prefixes.most_common(10)),
  "expected_per_prefix": round(len(lines)/65536.0, 3),
}
open(sys.argv[2], "w").write(json.dumps(out, indent=2))
print("analysis done", out["total_chunks"], "chunks")
PY
progress "step 3/4 done analysis.json=$(stat -c%s $WORKDIR/analysis.json)B"

# Step 4: final hash + cleanup
progress "step 4/4 final hash + cleanup"
FINAL=$(sha256sum "$WORKDIR/dataset.bin" | awk '{print $1}')
rm -f "$WORKDIR/dataset.bin"
progress "step 4/4 done final=$FINAL"

# Step 5: result.json
cat > "$WORKDIR/result.json" <<EOF
{
  "lane": "lane-8-grok",
  "pool": "minimax",
  "model": "grok-composer-2.5-fast",
  "chunks_hashed": $(wc -l < $WORKDIR/hashes.txt),
  "analysis_bytes": $(stat -c%s $WORKDIR/analysis.json),
  "final_sha256": "$FINAL",
  "completed_at": "$(date -u +%FT%TZ)"
}
EOF
progress "result.json written $(stat -c%s $WORKDIR/result.json)B"
progress "lane-8-grok compute-DONE"
echo "FINAL=$FINAL"
