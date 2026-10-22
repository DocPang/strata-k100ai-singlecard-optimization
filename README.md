# Strata K100_AI 单卡 Prefill 优化

面向 **海光 K100_AI（gfx928, 120 CU @ 1.400 GHz, DTK 2604）** 单卡 `Strata` 推理引擎的 prefill 性能优化记录、可复现实验脚本、以及一份可执行的部署/回滚方案。

- 工作负载：`Qwen3.8-Flash-Next` GSQ-RCO `IQ3_XXS`（MoE），**ctx128 = 126,856 token 单次 prefill**，chunk = 30,602
- 基线：prefill ≈ **61.3 s**（≈2,070 tok/s），`gpu_busy` ≈ 99.3%
- 硬件理论峰值（本仓库实测口径）：**bf16 165.3 TFLOP/s，int8 330.8 TFLOP/s**

## 结论（重要，先读这个）

| 项 | 值 |
|---|---|
| 立项目标 | **端到端 ≥ 20% 提速** |
| 实际达成 | **未达成**（但上线后实测 −8.9% ~ −11.2%，见下） |
| 本次交付到生产 | **重编二进制 −9.2% + solution 锁定 −1.64%** |
| 上线后同实例实测 | 23k token：13.270 → **11.785 s（−11.2%）**；126k token：70.78 → **64.47 s（≈−8.9%）** |
| 原有位精确优化集 | −5.0 ~ −5.6%（相对旧二进制） |
| 进一步收益 | 需更换内核生成方式，见 [`docs/07-int8-next-steps.md`](docs/07-int8-next-steps.md) |

> **重要**：上线时发现**旧生产二进制本身就落后约 9%**（源码相同、仅构建配置不同，输出位精确等价）。这一条比优化工作本身更大，详见 [`docs/08-production-rollout.md`](docs/08-production-rollout.md)。

**为什么 20% 拿不到**：本仓库用可复核的数据把 prefill 的五大热点逐一关闭（gate/up 17.5%、dense GEMM 池 27%、qsa attn 12.8%、gdn recurrence 10.9%、qsa select 7.7%、hc read 9.1%）。硬件本身不慢 —— 纯寄存器 MMAC 实测 **330.07 TFLOP/s = 99.8% int8 峰值**；但业务形状上的 GEMM 受 rocBLAS f16 上限（**60~70 TF/s**）约束，自研 int8 GEMM 三级流水只到 **49.25 TF/s**（比 rocBLAS f16 还慢 2 倍）。要把 int8 吃满，需要 **Tensile 级别的内核自动生成**，而不是继续手调 tile。详见 [`docs/07-int8-next-steps.md`](docs/07-int8-next-steps.md)。

## 目录

```
docs/     方法论、逐实验台账、已证伪路线、精度证据、int8 立项材料
deploy/   生产部署与回滚（脚本 + 环境变量清单）
patches/  唯一需要进源码的三个 fail-closed 补丁
bench/    可复现的交叉 A/B 脚本（含测量纪律）
data/     全部 A/B 实测数据（CSV）
```

## 快速使用

```bash
# 1) 复现一次交叉 A/B（控制组/实验组各两次，交替执行）
bash bench/ab_pin4.sh

# 2) 部署前自检（只读）
bash deploy/scripts/preflight.sh

# 3) 部署 / 回滚
bash deploy/scripts/deploy.sh    <engine-binary> <instance>
bash deploy/scripts/rollback.sh  <instance>
```

## 关键测量纪律（本仓库最重要的经验）

1. **"控制组"必须真的是控制组**。曾把 `BASE` 里已含实验开关的组误当控制组，于是"控制组 40 分钟漂了 1.5%"——其实那就是实验组。真控制组稳定在 61.27 s（极差 0.25%）。任何 <2% 的收益，**必须用同一时间窗内交替执行的 A/B 才能成立**。
2. **独立微基准不是有效仪器**。同一 rocBLAS 调用，独立 bench 最好 72.07 TF/s，而引擎内实测 **95.6 TF/s**，比任何独立配置都快。微基准的结论不能外推到引擎。
3. **只有"同 kernel 换 Tensile solution"可迁移**；换 tile / 换 kernel / 换路径一律不可迁移（连续 3 次证伪）。

## 许可

MIT
