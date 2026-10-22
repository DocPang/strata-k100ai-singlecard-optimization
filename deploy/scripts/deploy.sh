#!/usr/bin/env bash
# 部署一个引擎二进制到指定实例，并可追加/覆盖 env key。
# 用法: deploy.sh <engine-binary> <hcu0|hcu1> [KEY=VALUE ...]
# 语义: 备份 -> 原子替换二进制 -> 幂等改 config.env -> 重启 -> 等 health -> 失败自动回滚
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"

BIN="${1:?用法: deploy.sh <engine-binary> <hcu0|hcu1> [KEY=VALUE ...]}"
INST="${2:?缺少实例}"
shift 2

CONTAINER="$(instance_container "$INST")" || die "实例必须是 hcu0 或 hcu1"
PORT="$(instance_port "$INST")"
CFG="$B/release/$(instance_cfg "$INST")"
TS="$(date +%Y%m%d-%H%M%S)"
DEST="$B/bin-new/strata"

[ -f "$BIN" ] || die "找不到二进制 $BIN"
[ -x "$BIN" ] || die "二进制不可执行 $BIN"
[ -f "$CFG" ] || die "找不到配置 $CFG"
command -v python3 >/dev/null || die "需要 python3 改 config"
curl -s -o /dev/null -m 3 "http://127.0.0.1:$PORT/health" || log "警告：部署前 $INST 的 /health 不通（继续）"

mkdir -p "$BK"
exec 9>"$B/.deploy.lock"
flock -n 9 || die "另一个部署正在进行（$B/.deploy.lock）"

log "=== 备份 ==="
cp -a "$CFG" "$BK/$(basename "$CFG").bak-$TS"
cp -a "$DEST" "$BK/strata.bak-$TS" 2>/dev/null || true
log "  $BK/strata.bak-$TS"
log "  $BK/$(basename "$CFG").bak-$TS"

rollback_local() {
  log "=== 自动回滚 ==="
  [ -f "$BK/strata.bak-$TS" ] && cp -a "$BK/strata.bak-$TS" "$DEST" && log "  二进制已恢复"
  cp -a "$BK/$(basename "$CFG").bak-$TS" "$CFG" && log "  配置已恢复"
  docker restart "$CONTAINER" >/dev/null && log "  容器已重启"
  wait_health "$INST" || log "  回滚后 health 仍不通，需人工介入"
}

log "=== 安装二进制 ==="
cp -a "$BIN" "$BIN.tmp-$TS"
chmod 750 "$BIN.tmp-$TS"
mv "$BIN.tmp-$TS" "$DEST"          # 同目录 rename，原子生效
log "  $DEST <- $(sha256sum "$DEST" | cut -d' ' -f1)"

if [ "$#" -gt 0 ]; then
  log "=== 更新 config.env ==="
  python3 - "$CFG" "$@" <<'PY' || { rollback_local; die "config 更新失败"; }
import json,sys
path, pairs = sys.argv[1], sys.argv[2:]
d = json.load(open(path))
env = d.setdefault("env", {})
for kv in pairs:
    if "=" not in kv:
        sys.exit("bad pair: %r" % kv)
    k, v = kv.split("=", 1)
    old = env.get(k, "(absent)")
    env[k] = v
    print("  %-24s %s -> %s" % (k, old, v))
json.dump(d, open(path, "w"), ensure_ascii=False, indent=2)
PY
fi

log "=== 重启 $CONTAINER ==="
docker restart "$CONTAINER" >/dev/null || { rollback_local; die "重启失败"; }

if ! wait_health "$INST"; then
  log "health 未通过"
  rollback_local
  die "部署失败，已回滚"
fi

log "=== 部署完成 ==="
printf '  实例        %s (%s)\n' "$INST" "$CONTAINER"
printf '  二进制 sha  %s\n' "$(sha256sum "$DEST" | cut -d' ' -f1)"
printf '  配置备份    %s\n' "$BK/$(basename "$CFG").bak-$TS"
printf '  回滚命令    bash %s/rollback.sh %s %s\n' "$here" "$INST" "$TS"
