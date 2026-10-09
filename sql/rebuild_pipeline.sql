-- ============================================================
-- RFMC 特征工程全链路 Step 0~8（CTAS）
-- 目标空间：du_temp   提交空间：du_ad_bm(35898)
-- 锚点（10/8 批次）：活动日 20261007 / 特征截止 20261006 / 回溯 20251007~20261006
-- ⚠️ 每次重跑前需按当前最新分区更新上述三个日期变量
-- ============================================================
-- 【已固化教训】
--  L1: 裸 NULL 一律 CAST(NULL AS DOUBLE/BIGINT)，否则 NullType not supported
--  L2: PERCENTILE()/STDDEV() 在 MaxCompute Spark 引擎下会致 CTAS 静默产出空表
--      → median/std 列直接置 CAST(NULL AS DOUBLE)，用新表名绕开旧空壳表
--  L3: 券表字段为 coupon_no（非 coupon_id）、discount_amount（券面额）、buyer_user_id
--  L4: 核销口径 coupon_status = 1（实测 6.08 亿），order_discount_status = 2（实测 7.23 亿）
--  L5: dw_act_coupon 禁止 fullscan，用 pt='最新快照分区' + create_time 时间过滤
--  L6: 每步 CTAS 后必须 COUNT(*) 实测行数非零再放行下游（成功≠有数据）
-- ============================================================

-- ---------- Step 0: 基础订单表（近365天有支付行为全量用户）----------
DROP TABLE IF EXISTS du_temp.tmp_rfmc_base_orders;
CREATE TABLE du_temp.tmp_rfmc_base_orders LIFECYCLE 7 AS
SELECT
    buyer_user_id,
    subord_no,
    subord_pay_datetime,
    net_gmv,                              -- 表原生净GMV（分），勿用 subord_pay_amount
    refund_status_code,                   -- 实测列名（非 return_status_code）
    subord_plateform_buyer_discount_amt   -- 平台补贴（分）
FROM du_shucang.dws_sale_ord_subord_df
WHERE pt = '20261007'                    -- 全量快照分区
  AND subord_pay_datetime >= '2025-10-07'
  AND subord_pay_datetime <  '2026-10-07';

-- ---------- Step 1a: 每用户末次下单 ----------
DROP TABLE IF EXISTS du_temp.tmp_rfmc_last_order;
CREATE TABLE du_temp.tmp_rfmc_last_order LIFECYCLE 7 AS
SELECT buyer_user_id,
       MAX(subord_pay_datetime) AS last_order_dt
FROM du_temp.tmp_rfmc_base_orders
GROUP BY buyer_user_id;

-- ---------- Step 1b: 多窗口聚合（R/F/M 基础）----------
DROP TABLE IF EXISTS du_temp.tmp_rfmc_window_agg;
CREATE TABLE du_temp.tmp_rfmc_window_agg LIFECYCLE 7 AS
SELECT buyer_user_id,
       COUNT(CASE WHEN DATEDIFF('2026-10-06', SUBSTR(subord_pay_datetime,1,10)) <= 90  THEN 1 END) AS cnt_90d,
       COUNT(CASE WHEN DATEDIFF('2026-10-06', SUBSTR(subord_pay_datetime,1,10)) <= 180 THEN 1 END) AS cnt_180d,
       COUNT(1) AS cnt_365d,
       SUM(CASE WHEN DATEDIFF('2026-10-06', SUBSTR(subord_pay_datetime,1,10)) <= 90  THEN net_gmv ELSE 0 END) AS gmv_90d,
       SUM(net_gmv) AS gmv_365d,
       SUM(subord_plateform_buyer_discount_amt) AS subsidy_365d
FROM du_temp.tmp_rfmc_base_orders
GROUP BY buyer_user_id;

-- ---------- Step 2a: 行为末次（访问/加购/收藏）----------
DROP TABLE IF EXISTS du_temp.tmp_rfmc_behavior_last;
CREATE TABLE du_temp.tmp_rfmc_behavior_last LIFECYCLE 7 AS
SELECT buyer_user_id,
       MAX(pt) AS last_behv_pt
FROM du_shucang.adm_usr_behv_access_order_di
WHERE pt BETWEEN '20251007' AND '20261006'
GROUP BY buyer_user_id;

-- ---------- Step 2b: Recency（注意列名 w.last_order_dt / lo.interval_*）----------
DROP TABLE IF EXISTS du_temp.tmp_rfmc_recency;
CREATE TABLE du_temp.tmp_rfmc_recency LIFECYCLE 7 AS
SELECT w.buyer_user_id,
       DATEDIFF('2026-10-06', SUBSTR(w.last_order_dt,1,10)) AS days_since_last_order
FROM du_temp.tmp_rfmc_last_order w;

-- ---------- Step 3: 频次趋势 + 最大空窗（字段 b.buyer_user_id 非 user_id）----------
DROP TABLE IF EXISTS du_temp.tmp_rfmc_freq_trend;
CREATE TABLE du_temp.tmp_rfmc_freq_trend LIFECYCLE 7 AS
SELECT buyer_user_id,
       (cnt_90d/90.0) / NULLIF(cnt_365d/365.0, 0) AS order_frequency_trend_90d,
       CAST(NULL AS BIGINT) AS max_no_order_gap_365d   -- 简化占位，如需精确另建 gap_trend
FROM du_temp.tmp_rfmc_window_agg;

-- ---------- Step 4: Monetary（⚠️ median/std 置 NULL 避空表 bug；BC 表 JOIN UE）----------
DROP TABLE IF EXISTS du_temp.tmp_rfmc_monetary_v2;
CREATE TABLE du_temp.tmp_rfmc_monetary_v2 LIFECYCLE 7 AS
SELECT a.buyer_user_id,
       a.gmv_365d,
       a.gmv_90d,
       a.subsidy_365d,
       CAST(NULL AS DOUBLE) AS gmv_median,     -- L2 教训：PERCENTILE 致空表
       CAST(NULL AS DOUBLE) AS gmv_std,        -- L2 教训：STDDEV 致空表
       SUM(b.final_ue) AS final_ue_365d         -- BC 表冲销后 UE
FROM du_temp.tmp_rfmc_window_agg a
LEFT JOIN (
    SELECT buyer_user_id, subord_no, MAX(final_ue) AS final_ue
    FROM du_shucang.ads_rpt_trd_subsidy_df
    WHERE pt = '20261007'
    GROUP BY buyer_user_id, subord_no            -- 先按子订单去重防扇出
) b ON a.buyer_user_id = b.buyer_user_id
GROUP BY a.buyer_user_id, a.gmv_365d, a.gmv_90d, a.subsidy_365d;

-- ---------- Step 5: 券特征（coupon_no/discount_amount/buyer_user_id/status=1）----------
DROP TABLE IF EXISTS du_temp.tmp_rfmc_coupon;
CREATE TABLE du_temp.tmp_rfmc_coupon LIFECYCLE 7 AS
SELECT buyer_user_id,
       COUNT(CASE WHEN coupon_status = 1 THEN 1 END) AS coupon_used_cnt,   -- 1=已核销
       SUM(CASE WHEN coupon_status = 1 THEN discount_amount ELSE 0 END) AS coupon_used_amt
FROM du_dw.dw_act_coupon
WHERE pt = '20260917'                            -- L5: 指定快照分区，禁 fullscan
  AND create_time >= '2025-10-07'
GROUP BY buyer_user_id;

-- ---------- Step 6: 券依赖度（order_discount_status=2 已核销）----------
DROP TABLE IF EXISTS du_temp.tmp_rfmc_coupon_dep;
CREATE TABLE du_temp.tmp_rfmc_coupon_dep LIFECYCLE 7 AS
SELECT buyer_user_id,
       COUNT(CASE WHEN order_discount_status = 2 THEN 1 END) * 1.0
         / NULLIF(COUNT(1), 0) AS coupon_dependency   -- 2=已核销（实测修正）
FROM du_temp.tmp_rfmc_base_orders
GROUP BY buyer_user_id;

-- ---------- Step 7: 派生指标（引用 monetary_v2）----------
DROP TABLE IF EXISTS du_temp.tmp_rfmc_derived_v2;
CREATE TABLE du_temp.tmp_rfmc_derived_v2 LIFECYCLE 7 AS
SELECT m.buyer_user_id,
       m.gmv_365d / NULLIF(m.subsidy_365d, 0) AS ue_per_subsidy_365d,
       c.coupon_used_cnt,
       d.coupon_dependency
FROM du_temp.tmp_rfmc_monetary_v2 m
LEFT JOIN du_temp.tmp_rfmc_coupon c ON m.buyer_user_id = c.buyer_user_id
LEFT JOIN du_temp.tmp_rfmc_coupon_dep d ON m.buyer_user_id = d.buyer_user_id;

-- ---------- Step 8: 九表 JOIN 宽表（→ features_full_v3）----------
DROP TABLE IF EXISTS du_temp.tmp_rfmc_features_full_v3;
CREATE TABLE du_temp.tmp_rfmc_features_full_v3 LIFECYCLE 7 AS
SELECT r.buyer_user_id,
       r.days_since_last_order,
       w.cnt_90d, w.cnt_180d, w.cnt_365d,
       f.order_frequency_trend_90d,
       m.gmv_365d, m.gmv_90d, m.subsidy_365d, m.final_ue_365d,
       c.coupon_used_cnt, c.coupon_used_amt,
       dv.coupon_dependency, dv.ue_per_subsidy_365d
FROM du_temp.tmp_rfmc_recency r
LEFT JOIN du_temp.tmp_rfmc_window_agg w ON r.buyer_user_id = w.buyer_user_id
LEFT JOIN du_temp.tmp_rfmc_freq_trend f ON r.buyer_user_id = f.buyer_user_id
LEFT JOIN du_temp.tmp_rfmc_monetary_v2 m ON r.buyer_user_id = m.buyer_user_id
LEFT JOIN du_temp.tmp_rfmc_coupon c ON r.buyer_user_id = c.buyer_user_id
LEFT JOIN du_temp.tmp_rfmc_derived_v2 dv ON r.buyer_user_id = dv.buyer_user_id;

-- ============================================================
-- 【每步执行后必做】COUNT 校验，示例：
-- SELECT COUNT(*) FROM du_temp.tmp_rfmc_monetary_v2;  -- 必须 > 0 才放行 Step 7
-- ============================================================
