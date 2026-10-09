# 踩坑记录（Lessons Learned）

> 本文件是项目最重要的资产之一。每次遇到新故障必须追加，避免同一坑反复烧算力。

## 1. 沙箱重启清空 /workspace（发生 ≥3 次：9/29、10/8、10/9）

**现象**：本地 SQL 文件、Python 脚本、CSV 明细、pipeline.log 全部消失；galaxy-cli 登录态失效。
**影响**：无法续跑监控脚本，需重建所有落盘产物。
**对策**：
- ✅ **代码资产 Git 化**（本仓库即为此目的），每轮迭代结束立即 push。
- 远端 du_temp 表不受沙箱重启影响，是跨重启的可靠载体。
- 恢复 CLI 登录优先用 access-token 免浏览器方式。

## 2. 临时表 LIFECYCLE 7 天自动回收（9/28、10/8 两次整链重建）

**现象**：超过一周未重跑，中间表被清理，下游全断。
**对策**：
- 长链路任务先盘点哪些中间表存活（COUNT 实测），优先复用最重的宽表/dataset，只补缺失下游。
- 关键结果表（ATE/CATE）如需长期保留，考虑延长 LIFECYCLE 或转正式表。

## 3. "运行成功 ≠ 有数据"—— PERCENTILE()/STDDEV() 致 CTAS 静默空表（9/29）

**现象**：Step 4 monetary 显示执行成功，实际 0 行，级联污染 Step 6/7/8/DML 全链路输出 0 行。
**根因**：MaxCompute Spark 引擎下这两类聚合导致 CTAS 静默产出空表。
**对策**：
- median/std 列改 `CAST(NULL AS DOUBLE)` 占位。
- 旧空壳表无法 OR REPLACE 覆盖 → 用新表名（monetary_v2、features_full_v3）并同步改所有下游引用。
- **每步 CTAS 后强制 COUNT(*) 校验非零再放行**。

## 4. sql_check_permission 对不存在的表仍返回 passed=true（10/9）

**现象**：权限校验说通过，实际查询报 Table not found。
**对策**：探测表是否存在必须用能真实暴露错误的查询（单表 COUNT via sql_execute），不能依赖表级权限工具。

## 5. 字段口径实测修正（9/20~9/21）

| 错误假设 | 实测正确值 |
|---|---|
| coupon_status = 2 核销 | coupon_status = **1** 已核销（6.08 亿） |
| order_discount_status = 1 核销 | order_discount_status = **2** 已核销（7.23 亿） |
| face_value 券面额 | discount_amount |
| user_id（券表） | buyer_user_id |
| coupon_id（券表） | coupon_no |
| subord_pay_amount | 表原生 net_gmv |
| return_status_code | refund_status_code |
| dw_act_coupon fullscan | pt='快照分区' + create_time 过滤 |

## 6. JOIN 扇出与去重

- BC 补贴表按子订单号有重复行，关联前必须 GROUP BY subord_no 去重，否则订单量放大。
- 快照表用 MAX_PT/指定单分区+业务时间过滤；日增量表用分区区间过滤，混用会静默丢数据。

## 7. Celeborn Remote Shuffle 集群故障（9/21）

**现象**：所有含 shuffle 的查询报 "Fallback to spark built-in shuffle is prohibited"。
**对策**：平台级问题，无法靠改 SQL 解决，等集群恢复或联系运维。可临时简化 SQL（全局去均值 OLS 减少大表 JOIN）。

## 8. 行数上限与明细拉取（9/30）

- 单次 SELECT 拉取 ≤1 万条硬限制。
- 突破方式：明细先落远端临时表，按 ROW_NUMBER 分片（如 treated 24 片）分批拉齐拼接，零截断。
- treated 全保留 + control 按比例抽样时，拟合 E[T|X] 必须按抽样权重回乘还原 T 边缘分布，否则 θ 有偏。

## 9. 纯 SQL 近似的天花板（9/30）

- D2~D9 大量 T=0 用户 pseudo_cate 回退为常数 θ，无法区分个体效应。
- 真·个体化 CATE 必须走 Python 两阶段 nuisance 模型。
- Y 重尾时十分位实证 uplift 排序不稳定（噪声>信号）、AUUC/Qini 名义 lift 为伪影，不可用于汇报。
