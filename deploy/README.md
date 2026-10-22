# 生产部署 / 回滚

## 生产形态

| 实例 | 容器 | 端口 | 引擎配置 |
|---|---|---|---|
| hcu0 | `strata-next-hcu0-xxs-20261015` | 18640 | `/release/hcu0-xxs-nokvres.json` |
| hcu1 | `strata-next-hcu1-xxs-20261016` | 18641 | `/release/hcu1-xxs-nokvres.json` |

- 容器启动命令固定为 `python3 -m serve.server --engine strata --config /release/<inst>.json ...`
- **二进制不是打在镜像里的**，而是挂载：`<B>/bin-new` → 容器内 `/release/bin`，配置里 `exe = /release/bin/strata`
- **环境变量也不是 `docker -e`**，而是写在 config JSON 的 `env` 段里

⇒ 所以一次部署只有两个动作：**换 `<B>/bin-new/strata`** + **改 config 的 `env`**，然后 `docker restart`。

## 前置

```bash
export B=/data/experiments/<生产包目录>     # 含 bin-new/ 与 release/
```

## 步骤

```bash
# 1) 只读自检
bash scripts/preflight.sh

# 2) 先部署一个实例（灰度），观察后再上另一个
bash scripts/deploy.sh /path/to/strata hcu1 STRATA_GEMM_SOL=2560x6144=20377,10240x2560=20385

# 3) 校验（health + 配置回显 + 真实 prefill 计时）
bash scripts/verify.sh hcu1 4096

# 4) 观察正常后部署第二个实例
bash scripts/deploy.sh /path/to/strata hcu0 STRATA_GEMM_SOL=2560x6144=20377,10240x2560=20385
bash scripts/verify.sh hcu0 4096
```

## 回滚

```bash
bash scripts/rollback.sh hcu1              # 回滚到最近一次备份
bash scripts/rollback.sh hcu1 20261022-101500   # 回滚到指定时间点
```

deploy.sh 在 health 检查失败时会**自动回滚**。备份落在 `<B>/backups/deploy/`。

## 安全约定

- 只允许 `hcu0` / `hcu1` 两个实例（脚本硬编码白名单，传其他值直接退出）
- 二进制用**同目录 rename** 原子替换，不会出现"半写"的可执行文件
- 部署期间持有 `flock <B>/.deploy.lock`，并发部署直接失败
- 备份保留：**不删**（脚本里没有任何 `rm`），需要清理时人工 `mv` 到归档目录
