#!/usr/bin/env bash
# 回滚到指定时间点的备份（默认取最新一份）。
# 用法: rollback.sh <hcu0|hcu1> [时间戳 YYYYmmdd-HHMMSS]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"

INST="${1:?用法: rollback.sh <hcu0|hcu1> [时间戳]}"
CONTAINER="$(instance_container "$INST")" || die "实例必须是 hcu0 或 hcu1"
CFG="$B/release/$(instance_cfg "$INST")"

TS="${2:-}"
if [ -z "$TS" ]; then
  TS="$(ls -1 "$BK"/$(basename "$CFG").bak-* 2>/dev/null | sed 's/.*\.bak-//' | sort | tail -1)"
  [ -n "$TS" ] || die "在 $BK 找不到任何备份"
fi
BINBK="$BK/strata.bak-$TS"
CFGBK="$BK/$(basename "$CFG").bak-$TS"
[ -f "$CFGBK" ] || die "找不到配置备份 $CFGBK"

exec 9>"$B/.deploy.lock"
flock -n 9 || die "另一个部署正在进行"

log "=== 回滚 $INST 到 $TS ==="
if [ -f "$BINBK" ]; then cp -a "$BINBK" "$B/bin-new/strata"; log "  二进制已恢复 ($(sha256sum "$B/bin-new/strata" | cut -d' ' -f1))"; fi
cp -a "$CFGBK" "$CFG"; log "  配置已恢复"
docker restart "$CONTAINER" >/dev/null; log "  容器已重启"
wait_health "$INST" || die "回滚后 health 不通，需人工介入"
log "=== 回滚完成 ==="
