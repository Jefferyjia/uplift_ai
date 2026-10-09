# 项目进展快照

> 最后更新：2026-10-09（本文件每次迭代必须更新，作为跨沙箱重启的唯一进度锚点）

## 一、远端表存活状态（2026-10-09 COUNT 实测）

| 表 | 行数 | 状态 |
|---|---|---|
| `du_temp.tmp_rfmc_base_orders` | 730,967,141 | ✅ 存活 |
| `du_temp.tmp_rfmc_features_full_v3` | 141,910,565 | ✅ 存活（最重产物） |
| `du_temp.tmp_dml_dataset_v2` | 141,910,565 | ✅ 存活（训练集） |
| `du_temp.tmp_dml_ty` | 1,521,834 | ✅ 存活（活动日 T/Y） |
| `du_temp.tmp_rfmc_monetary_v2` | — | ❌ LIFECYCLE 已回收 |
| `du_temp.tmp_dml_train_flat` | — | ❌ 已回收 |
| `du_temp.tmp_dml_ate_v3` | — | ❌ 不存在（需重算） |
| `du_temp.tmp_dml_cate_scores_v2` | — | ❌ 不存在（需重算） |

**结论**：数据管道层核心表存活，DML 结果层（ATE/CATE）丢失需重算。
因宽表+dataset 仍在，重建成本从"整链 2~3 小时"降为"仅补 DML 层 30~50 分钟"。

## 二、按技术任务书完成度

### Agent #5 数据管道子任务 —— ~85%
- [x] RFMC 特征工程 Step 0~8（10 CTAS 全通）
- [x] 四套切分（哈希分桶 60/15/10/15）
- [x] holdout 严格随机、时间隔离无泄漏
- [x] 干净数据集（1.42 亿行 × ~150 特征）
- [ ] 独立数据字典文档（SQL 即口径，未整理成册）
- [ ] 面额档位样本量/缺失率报告（当前 T 为连续金额非档位）

### CFM Spike —— 核心打通，模型层待固化
- [x] DML ATE 估计（SQL 近似 θ=26.9；本地两阶段 θ=18.16）
- [x] CATE 十分位打分
- [x] coupon_status / order_discount_status 枚举实测（1=核销 / 2=核销）
- [ ] LightGBM 两阶段真训固化（脚本就绪，依赖 PyODPS3 环境或明细拉取）
- [ ] AUUC/Qini 评估（受 Y 重尾影响，名义 lift 为伪影，不可汇报）

### 其余 6 个 Agent（#1/#2/#3/#4/#6/#7）—— 未启动
属 2 个月工期蓝图后续阶段，与当前数据管道任务不同层。

## 三、本轮（10/9）待办

1. **代码资产 Git 化**（进行中）：把 SQL/Python/文档推到 GitHub，杜绝沙箱重启丢失。
2. 恢复 galaxy-cli 登录态（沙箱重启后已失效）。
3. 复用存活 dataset_v2 重算 DML Step E（θ_ATE）+ Step F（CATE），落新表。
4. 决定基准日：沿用 10/8 批次（活动日 20261007）还是推进到最新分区。

## 四、历史里程碑

| 日期 | 事件 |
|---|---|
| 09/18 | RFMC 特征工程 10 CTAS 首次全通 |
| 09/20 | DML Step A~F 首版跑通，θ_ATE=53.78（旧宽表） |
| 09/21 | 枚举实测修正 coupon_status/order_discount_status；Celeborn shuffle 故障 |
| 09/29 | LIFECYCLE 过期整链重建；发现 PERCENTILE 致空表级联 bug 并修复；θ_ATE=26.894 |
| 09/30 | 本地明细版真·两阶段 DML：θ_ATE=18.16（t=13.3），treated 24 片分片拉齐零截断 |
| 10/08 | 沙箱重启+LIFECYCLE 双灾，整链重建至 Step1 |
| 10/09 | 沙箱再次重启；盘点确认宽表/dataset 存活，启动代码 Git 化 |
