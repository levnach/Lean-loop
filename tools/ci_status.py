"""Classify `gh pr checks --json` output. Prints pass|fail|pending and writes a JSON summary."""
import json
import re
import sys

raw_path, gating_re, elapsed_min, settle_min, out_path = sys.argv[1:6]
try:
    with open(raw_path, encoding="utf-8") as fh:
        checks = json.load(fh)
    if not isinstance(checks, list):
        checks = []
except Exception:
    checks = []

gate = re.compile(gating_re)
gating = [c for c in checks if gate.search(c.get("workflow") or "")]
other = [c for c in checks if not gate.search(c.get("workflow") or "")]
pending = [c for c in gating if c.get("bucket") == "pending"]
failed = [c for c in gating if c.get("bucket") in ("fail", "cancel")]
elapsed = float(elapsed_min)

if not gating or pending or elapsed < float(settle_min):
    status = "pending"
elif failed:
    status = "fail"
else:
    status = "pass"

summary = {
    "status": status,
    "elapsed_min": round(elapsed, 1),
    "gating_total": len(gating),
    "gating_pending": len(pending),
    "gating_failed": [c.get("name") for c in failed],
    "gating": [
        {k: c.get(k) for k in ("workflow", "name", "state", "bucket", "link", "startedAt", "completedAt")}
        for c in gating
    ],
    "other": [{k: c.get(k) for k in ("workflow", "name", "state", "bucket", "link")} for c in other],
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2)
print(status)
