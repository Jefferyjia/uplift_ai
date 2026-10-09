# RFMC × DML 补贴因果推断项目（CFM Spike）

得物双11周期补贴效率评估：从原始订单表 → RFMC 特征工程 → Double Machine Learning (DML) 因果推断，
估计平台补贴对净 GMV 的平均处理效应（ATE）与异质性处理效应（CATE）。

对应技术任务书：`docs/double11_tech_taskbook.md`（7-Agent E³IR 全栈蓝图）
本仓库落地范围：**Agent #5「Data & CFM Scout」数据管道子任务 + CFM Spike**。

## 目录结构

```
rfmc-dml/
├── README.md                      # 本文件
├── STATUS.md                      # 当前进展快照（每次迭代更新）
├── sql/
│   ├── rebuild_pipeline.sql       # Step 0~8 RFMC 特征工程全链路 CTAS
│   └── dml_pipeline.sql           # DML Step A~F（T/Y、分桶、残差、ATE、CATE）
├── python/
│   ├── dml_train_v2.py            # PyODPS3 LightGBM 两阶段 DML（真训版）
│   ├── causal_forest_train.py     # EconML CausalForestDML 备选
│   └── local_dml.py               # 本地明细版两阶段 DML + AUUC/Qini
└── docs/
    ├── double11_tech_taskbook.md  # 技术任务书（13 章）
    ├── CFM_Spike_handover.md      # 交接文档
    ├── data_dictionary.md         # 宽表数据字典
    └── lessons_learned.md         # 踩坑记录（沙箱重启/LIFECYCLE/空表级联等）
```

## 核心结论（最新一次跑通，SQL 近似版）

- **θ_ATE ≈ 26.9**（SQL 全局去均值 OLS，基于 features_full_v3 完整特征）
- 对比第一版（缺 UE/趋势特征）的 53.78，补齐特征后控制混杂更充分，估计减半属合理结果
- 真·两阶段 LightGBM DML（本地明细版）曾产出 θ_ATE = 18.16（SE=1.36, t=13.3）
  —— 控制 150 维混杂后较 SQL 朴素估计再降 32%，即选择偏差被剥离的量

## 关键口径

| 项 | 定义 |
|---|---|
| Treatment T | 活动日当天 SUM(subord_plateform_buyer_discount_amt)（单位：分） |
| Outcome Y | 活动日当天 SUM(net_gmv)（支付 - 退款，单位：分） |
| 特征快照 | 截止活动日前一天，回溯 365 天（时间隔离防泄漏） |
| 未在活动日下单用户 | T=0, Y=0（自然对照组） |
| 四套切分 | md5(user_id)%100: train[0,60) calib[60,75) holdout[75,85) reserved[85,100) |

## 远端表（MaxCompute du_temp，LIFECYCLE 7 天自动回收）

重头表 `tmp_rfmc_features_full_v3`（1.42 亿行 × ~150 特征）、
`tmp_dml_dataset_v2`（1.42 亿行训练集）为最贵产物，优先复用。

## ⚠️ 持续迭代注意事项（务必阅读 docs/lessons_learned.md）

1. **沙箱重启会清空 /workspace**：代码必须及时 push 到本仓库，不要只留在沙箱本地。
2. **临时表 LIFECYCLE 7 天过期**：超过一周未重跑，中间表会被回收，需按断点续跑机制补建。
3. **"运行成功 ≠ 有数据"**：每步 CTAS 后必须 COUNT 实测行数非零再放行下游。
