#!/usr/bin/env bash
# 部署后校验：健康 + 与生产配置逐项比对 + 用真实请求测一次 prefill。
# 用法: verify.sh <hcu0|hcu1> [token 数，默认 4096]
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
INST="${1:?用法: verify.sh <hcu0|hcu1> [tokens]}"
NTOK="${2:-4096}"
PORT="$(instance_port "$INST")"

code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$PORT/health")"
printf 'health  %s\n' "$code"

cfg="$B/release/$(instance_cfg "$INST")"
python3 - "$cfg" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print("exe   ", d.get("exe"))
for k in sorted(d.get("env",{})):
    if k.startswith("STRATA_GEMM") or k.startswith("STRATA_PF_PAD") or k in ("STRATA_HC_SPLIT","STRATA_DENSE_TN"):
        print("env   ", k, "=", d["env"][k])
PY

# 真实 prefill 计时：构造一个重复文本，凑够 NTOK 个 token
python3 - "$PORT" "$NTOK" <<'PY'
import json,sys,time,urllib.request,os
port, ntok = sys.argv[1], int(sys.argv[2])
body = " ".join(["海光 DCU 单卡预填充性能验证"] * max(1, ntok // 8))
req = urllib.request.Request(
    "http://127.0.0.1:%s/v1/chat/completions" % port,
    data=json.dumps({"model":"qwen3.8-flash-next-strata","max_tokens":1,
                     "messages":[{"role":"user","content":body}]}).encode(),
    headers={"Content-Type":"application/json",
             "Authorization":"Bearer "+os.environ.get("STRATA_API_KEY","")})
t=time.time()
try:
    r=json.load(urllib.request.urlopen(req, timeout=900))
    print("prefill_wall_s %.2f" % (time.time()-t))
    print("usage", json.dumps(r.get("usage",{}), ensure_ascii=False))
except Exception as e:
    print("REQUEST_FAILED", e)
PY
