# 宽表数据字典 —— tmp_rfmc_features_full_v3

> 1.42 亿行 × ~150 特征（本文档列出核心列，完整列以 `SELECT * LIMIT 1` schema 为准）
> 单位：金额类字段底表为「分」，聚合后如需元请 /100。

## 主键与切分
| 列 | 类型 | 说明 |
|---|---|---|
| buyer_user_id | BIGINT | 用户 ID（主键） |
| split | STRING | train/calibration/holdout/reserved（md5%100: <60/<75/<85/else） |
| t | DOUBLE | Treatment：活动日平台补贴（分） |
| y | DOUBLE | Outcome：活动日净 GMV（分） |

## Recency（R）
| 列 | 说明 |
|---|---|
| days_since_last_order | 距末次下单天数 |

## Frequency（F）
| 列 | 说明 |
|---|---|
| cnt_90d / cnt_180d / cnt_365d | 近 90/180/365 天下单次数 |
| order_frequency_trend_90d | (cnt_90d/90)/(cnt_365d/365)，>1 表示近期加速 |

## Monetary（M）
| 列 | 说明 |
|---|---|
| gmv_365d / gmv_90d | 近 365/90 天净 GMV（分） |
| subsidy_365d | 近 365 天累计平台补贴（分） |
| final_ue_365d | BC 表冲销后 UE（分） |
| ue_per_subsidy_365d | gmv_365d / subsidy_365d，补贴效率 |
| gmv_median / gmv_std | ⚠️ 置 NULL（PERCENTILE/STDDEV 空表 bug，见 lessons §3） |

## Coupon（C）
| 列 | 说明 |
|---|---|
| coupon_used_cnt | 核销券数（coupon_status=1） |
| coupon_used_amt | 核销券面额合计（discount_amount） |
| coupon_dependency | 用券订单占比（order_discount_status=2） |

## 缺失率报告（待补）
- [ ] 各特征列缺失率统计
- [ ] T 连续金额的分位数分布（P50/P90/P99）
- 注：days_since_last_collect 无数据源，恒为 NULL
