#!/usr/bin/env bash
# 公共定义：实例表、路径、备份约定。所有脚本 source 这个文件。
set -uo pipefail

# ── 可覆盖的环境变量 ─────────────────────────────────────────────
: "${B:?需要设置 B = 生产包目录（含 bin-new/ 与 release/）}"
: "${BK:=$B/backups/deploy}"          # 备份目录
: "${HEALTH_TIMEOUT:=420}"            # 重启后等待 /health 的超时秒数

# ── 实例表（只允许这两个） ────────────────────────────────────────
instance_container() {
  case "$1" in
    hcu0) echo "strata-next-hcu0-xxs-20261015" ;;
    hcu1) echo "strata-next-hcu1-xxs-20261016" ;;
    *) return 1 ;;
  esac
}
instance_port() {
  case "$1" in
    hcu0) echo 18640 ;;
    hcu1) echo 18641 ;;
    *) return 1 ;;
  esac
}
instance_cfg() {
  case "$1" in
    hcu0) echo "hcu0-xxs-nokvres.json" ;;
    hcu1) echo "hcu1-xxs-nokvres.json" ;;
    *) return 1 ;;
  esac
}

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] FATAL: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

wait_health() {
  local inst="$1" port deadline
  port="$(instance_port "$inst")" || die "未知实例 $inst"
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  log "等待 http://127.0.0.1:$port/health （上限 ${HEALTH_TIMEOUT}s）"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$port/health" || true)"
    if [ "$code" = "200" ]; then log "health OK ($inst)"; return 0; fi
    sleep 5
  done
  return 1
}
