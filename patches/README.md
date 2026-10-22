# 源码补丁（只有三个，全部 fail-closed）

生产二进制与基线二进制的**唯一差别**就是这三个补丁。它们都不改变数值语义，只增加"按形状选择 rocBLAS solution"的能力。

| 补丁 | 作用 | 锚点 |
|---|---|---|
| `patch_gemsol.py` | 在 `strata/src/prefill/gemm.cu` 的 `Gemm::f16_inplace`（~line 1067）与 `Gemm::native` 的 padr else 分支插入 hook：按 `N×K` 查表给 `rocblas_gemm_ex` 指定 solution | 两处锚点，命中数必须为 1 |
| `patch_gemsol2.py` | 第二处 hook（`Gemm::native` 的 padr 分支），补上 `10240×2560` 这个形状 | 同上 |
| `patch_cmake_rocblas.py` | 在 CMake 里加 `-lrocblas`（**必须显式**，不会自动带出） | `target_link_libraries` |

## 环境变量协议

```
STRATA_GEMM_SOL=<N>x<K>=<solution_id>[,<N>x<K>=<solution_id>...]
```

- 未设置 / 为空 → 不改任何行为（走 rocBLAS 默认选择）
- 设置了但没匹配到形状 → 静默走默认，**不会报错**（因此必须用 `STRATA_GEMM_ATTR=1` 或 stride 打印确认命中）
- 内部有 `dead` 失败标志：句柄创建失败时一次置位，后续不再尝试，避免每次都付初始化开销

## 关键实现细节（踩坑记录）

- `#include <rocblas/rocblas.h>` 必须在 **file scope**，不能放在 `namespace` 或函数内
- 用**私有 static handle**，不要复用引擎自己的 handle（否则 stream 语义会被打乱）
- `rocblas_gemm_ex_get_solutions` 的 alpha/beta **不能传 nullptr**（会返回 status 3 `invalid_pointer`）
- 布局：`m = N`（权重行数）、`ldc = N`（**引擎真实 ld=2N，别照抄手写 bench**）、`lda = K`
- 析构：`rocblas_destroy_handle(h)`，**不能**传 `&h`
- `Gemm::native` 在某些分支会 `return native_tn(...)` 提前返回，**绕过这两个 hook** —— 所以 `STRATA_DENSE_TN=1` 与 solution pin 互斥

## 为什么要 fail-closed

锚点找不到时**必须**报错退出。曾经出现过"对已打补丁的文件再打一次"，锚点计数为 0，脚本静默通过，结果构建出一个没有任何 hook 的二进制，白跑了 40 分钟 A/B。
