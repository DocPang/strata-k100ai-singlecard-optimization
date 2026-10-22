# 04 · 已证伪路线清单（不要再走一遍）

每一条都附**引擎内实测**数据。表中"控制组"均为同批次同配置。这是本仓库最有价值的部分：省掉重复投入。

## A. GEMM / rocBLAS 方向

| 尝试 | 结果 | 判定 |
|---|---|---|
| `rocblas_gemm_ex_get_solutions` 枚举全部 **512** 个 solution 后按形状 pin | 部分形状有效，跨形状仅 2/9 可迁移 | 受限可用 |
| 小形状 solution pin（N=640/512，微基准 +14%/+22%） | 引擎内 **+0.01%**（pin 未命中，引擎已是 bench-best） | 证伪 |
| 用 `ROCBLAS_TENSILE_GEMM_OVERRIDE_PATH` + `rocblas-gemm-tune` 离线调优 | YAML 只打 stdout、需 `Tests:` 包装、15+ 分钟/形状、无 profile 行 | 工程不可行 |
| `STRATA_DENSE_TN=1`（转置布局走 native_tn） | −1.35%，但**与 solution pin 冲突**（合并后只有 −1.24%，比任一单独都差） | 不采用 |
| 合并小 GEMM 以减少调用次数 | N 扫描 51.6→69.7 TF/s **无趋势**，N=14336 比 12288 更慢 | 无意义 |
| 缓存 dequant 结果 | dequant 仅占总 GEMM 时间 **1.8%**（82.2 / 4,614.1 ms） | 收益上限 ≈0 |

## B. 自研 int8 dense GEMM

硬件能力已验证：纯寄存器 MMAC 可跑 **330.07 TFLOP/s（99.8% 峰值）**，条件是 ≥4 waves/SIMD 且 ≥8 累加器。

| 变体 | 时间 | TF/s | 占 int8 峰值 |
|---|---|---|---|
| 单阶段 18 KB LDS | 21.385 ms | 45.01 | 13.6% |
| 两阶段 36 KB | 24.164 ms | 39.84 | 12.0% |
| **三阶段 54 KB** | 19.545 ms | **49.25** | 14.9% |
| 三阶段 NT4 40.5 KB | 48.512 ms | 19.84 | 6.0% |
| 四阶段 | — | — | 需 73,728 B > LDS 上限 65,536 B |

**结论**：流水化只带来 +9.4%；最好成绩 49 TF/s 仍比 rocBLAS f16 的 **95.6** 慢 2 倍，需要吃到 int8 峰值的 29% 才回本。**手写 kernel 到此为止。**

## C. gate/up（占 prefill 17.5%）—— 9 条路径全部引擎内证伪

| 尝试 | 控制组 | 实验组 | Δ |
|---|---|---|---|
| `GATEUP_KS128` | 60,343.0 | 61,196.8 | **+1.4%**（更差） |
| `GATEUP_MT2` | 60,343.0 | 61,143.8 | **+1.3%** |
| `GATEUP_SV4` | 60,343.0 | 60,582.4 | +0.4% |
| `GATEUP_LB3` | 60,343.0 | 127,239.9 | **+111%（spill）** |
| `GATEUP_WSG32_NT4` | 60,281.4 | 60,851.6 | +0.9% |
| `GATEUP_MT2W8`（W8 分组） | 61,181.7 | 124,781.4 | **+104%** |
| WSG16→32 加宽 | 61,214.5 | 60,967.5 | −0.40%（但 gate/up 阶段 −2.3%，被其他阶段吃掉） |
| 提升 rocBLAS solution（microbench MT1 76.25 → MT2 98.83, +29.6%） | — | — | 引擎内不可迁移 |
| 生产 per-32 权重 scale 下的全语义上限 | 实测 52.38 TF/s 探针 vs 引擎反算 37 TF/s | — | 理论上限 ≈ −4% e2e，不足以达标 |

关键机制：生产 kernel 的 per-32 权重 scale 使 MT2 从 11.76 TF/s 起步（比 MT1 慢 5.8×）；把 scale 提前拷贝出来也没有改善。MMA 部分占 gate/up 的 ≈71%，因此即使 MMA 全免费也只有 −4% e2e。

## D. hc read（占 9.1%）

- 真实形状是 `D=10240, LR=320, HC=4, T=30602`（**不是** 2560），共 96 个 unit
- 微基准：upmix 2.2×（65.36 TF/s, sol 20390）、down 1.24×（43.52, sol 20380）
- **引擎内 A/B：0%**（61,257.2 vs 61,283.7）
- 原因：`Gemm::bf16`（源码 line 591）已经把 upmix 路由到 hipBLASLt bf16 默认路径，pin 无从下手
- `STRATA_HC_MMAC=1`（自研 MMAC 化）：60,370.2 vs 60,281.4 → **+0.1%，纯噪声**

## E. 其他"看起来会有效"的开关（引擎内全部落在噪声内）

| 开关 | 控制组 | 实验组 | Δ |
|---|---|---|---|
| `STRATA_PF_PAD=1,STRATA_PF_GEMM=1` | 60,281.4 | 60,187.4 | −0.16%（噪声） |
| `STRATA_PADR_LT=1` | 60,281.4 | 60,395.1 | +0.19% |
| `STRATA_PF_PAD_ROCBLAS=2`（pad 64） | 60,281.4 | 60,603.4 | +0.53%（pad 32 更好） |
| `STRATA_HC_SPLIT=0` + 全部 hc pin | 61,283.7 | 61,257.2 | 0% |

## F. 一些具体的技术陷阱（踩过的坑）

- `rocblas_gemm_ex` 的布局是 `m=N`（权重行数）、`ldc=N`、`lda=K`；写成 `m=M` 会 VMFault
- 引擎真实 `ldc = 2N`（不是 `N`）。**所有扫描若用 `ldc=N` 就全部作废** —— 这一条曾导致一整轮"微基准大赢、引擎零收益"
- `rocblas_gemm_ex_get_solutions` 传 `nullptr` alpha/beta 会返回 status 3（`invalid_pointer`），必须给真实值
- `rocblas_destroy_handle(h)` 不能传 `&h`
- 对本地累加器数组取地址会强制落到 scratch，性能掉约 100×
- rocBLAS 头文件必须在 file scope include；`-lrocblas` 必须显式加进 CMake
- `cp -a` 会把 `build/` 一起带过去，必须先 `mv` 到一边
- 对已打补丁的文件再打一次补丁 → 锚点断言失败（`ANCHOR_FAILED count=0`），所以每个实验树都是从干净树开始的
