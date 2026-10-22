#!/usr/bin/env bash
# 只读自检：确认部署前置条件，不修改任何东西。
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"

log "=== 实例状态 ==="
for inst in hcu0 hcu1; do
  c="$(instance_container "$inst")"; port="$(instance_port "$inst")"
  st="$(docker inspect -f '{{.State.Status}} {{.State.StartedAt}}' "$c" 2>/dev/null || echo MISSING)"
  code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$port/health" || true)"
  printf '  %-5s %-36s %-45s health=%s\n' "$inst" "$c" "$st" "$code"
done

log "=== 当前制品 ==="
printf '  bin-new/strata  sha256 = %s\n' "$(sha256sum "$B/bin-new/strata" | cut -d' ' -f1)"
for inst in hcu0 hcu1; do
  cfg="$B/release/$(instance_cfg "$inst")"
  printf '  %-22s sha256 = %s\n' "$(basename "$cfg")" "$(sha256sum "$cfg" 2>/dev/null | cut -d' ' -f1)"
  python3 - "$cfg" <<'PY' 2>/dev/null || true
import json,sys
d=json.load(open(sys.argv[1]))
print("    exe =", d.get("exe"))
print("    STRATA_GEMM_SOL =", d.get("env",{}).get("STRATA_GEMM_SOL","(absent)"))
PY
done

log "=== 显存 ==="
for d in renderD128 renderD129; do
  printf '  %-11s used = %s\n' "$d" "$(cat /sys/class/drm/$d/device/mem_info_vram_used 2>/dev/null || echo NA)"
done

log "=== 部署锁 ==="
if [ -e "$B/.deploy.lock" ]; then log "  发现锁文件（可能上次中断）: $B/.deploy.lock"; else log "  无锁"; fi
log "自检完成（未做任何修改）"
