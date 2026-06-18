# Agent Pipeline Contract
## Workflow Execution Order
任何时候启动新功能开发，必须严格按照以下流水线串行推进：

1. **[Architect Phase]**: 读入功能描述，输出 `抽象接口类`、`Data Model` 以及 `核心数据流拓扑图`。
2. **[Auditor Phase]**: 接入上一步的骨架，强行将所有参数、方法边界、延迟范围数字化，输出 `硬指标测试契约`。
3. **[Checker Phase]**: 接入前两步的结果，用安卓生命周期、内存泄露防范、720P 渲染重绘限制进行挑刺，输出 `防御性补丁代码规范`。

最终合并输出：一份零模糊、高可执行力的 `PRD_Architecture.md`。