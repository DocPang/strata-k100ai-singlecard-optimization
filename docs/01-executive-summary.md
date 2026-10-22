# 01 · 执行摘要

日期：2026-10-22　设备：海光 K100_AI（gfx928）单卡　引擎：Strata　模型：Qwen3.8-Flash-Next IQ3_XXS

## 结论

| 项 | 结果 |
|---|---|
| 目标（端到端 ≥20%） | **未达成** |
| 实际交付 | **−6.6 ~ −7.2%**（其中 −5.0~−5.6% 为已上线的位精确优化，**−1.64%** 为本次新增） |
| 本次新增内容 | 一个环境变量 + 一个重编二进制 |
| 回滚成本 | 删掉一行环境变量，或 `rollback.sh`（≤2 分钟） |
| 精度 | top-1 完全一致，KL 8.3e−05 |

## 做了什么

1. **把 prefill 拆开归因**：建立 `STRATA_PREFILL_TIMING` / `STRATA_GEMM_ATTR` 两套自有探针（环境无 rocprof），把 60 秒 prefill 拆到 6 个阶段、2944 次 GEMM 调用、4 个主导形状。
2. **逐关闭热点**：gate/up、dense GEMM 池、qsa attn、gdn recurrence、qsa select、hc read —— 共 **17 条**路径，全部用引擎内 A/B 证伪，写入 [`04-closed-paths.md`](04-closed-paths.md)。
3. **实测硬件上限**：纯寄存器 MMAC 打到 **330.07 TFLOP/s（99.8% int8 峰值）**，证明瓶颈不在硬件。
4. **找到唯一可交付的确定性收益**：rocBLAS solution 锁定（Tensile solution 编号 pin），**−1.64%**，用交叉 A/B 严格验证。
5. **把方法论固化成可复用资产**：交叉 A/B 脚本、fail-closed 补丁、部署/回滚脚本。

## 为什么 20% 到不了

| 原因 | 数据 |
|---|---|
| 业务形状上 rocBLAS f16 只有 bf16 峰值的 36–42% | 60–70 TF/s |
| 引擎已在这条路径的最优点 | 95.6 TF/s（比独立 microbench 还快） |
| 自研 int8 GEMM 追不上 f16 | 最好 49.25 TF/s，差 2 倍；四阶段超 LDS 上限 |
| 唯一出路是 Tensile 级 int8 内核自动生成 | 见 [`07-int8-next-steps.md`](07-int8-next-steps.md) |

## 建议

1. **先上**：本次 −1.64% 已验证、可回滚、零精度风险，建议直接灰度到 hcu1 再上 hcu0。
2. **并行立项**：int8 GEMM 走 Tensile / 上游 gfx9 逻辑重编，按三阶段推进（单形状 ≥130 TFLOP/s → gate/up → 全量），每阶段可独立终止。

这两件事不冲突。
