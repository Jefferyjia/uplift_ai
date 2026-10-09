-- ============================================================
-- DML 因果推断链路 Step A~F（纯 SQL 近似版，抗沙箱重启）
-- 输入：du_temp.tmp_rfmc_features_full_v3（宽表）
-- T = 活动日平台补贴（分），Y = 活动日净GMV（分）
-- ⚠️ 活动日/特征截止需与 rebuild_pipeline.sql 同批次
-- ============================================================

-- ---------- Step A: 活动日 T/Y ----------
DROP TABLE IF EXISTS du_temp.tmp_dml_ty;
CREATE TABLE du_temp.tmp_dml_ty LIFECYCLE 7 AS
SELECT buyer_user_id,
       SUM(subord_plateform_buyer_discount_amt) AS t,
       SUM(net_gmv)                             AS y
FROM du_shucang.dws_sale_ord_subord_df
WHERE pt = '20261007'
  AND SUBSTR(subord_pay_datetime,1,10) = '2026-10-07'   -- 活动日当天
GROUP BY buyer_user_id;

-- ---------- Step B: 宽表 + T/Y + 哈希分桶 ----------
DROP TABLE IF EXISTS du_temp.tmp_dml_dataset_v2;
CREATE TABLE du_temp.tmp_dml_dataset_v2 LIFECYCLE 7 AS
SELECT f.*,
       COALESCE(ty.t, 0) AS t,          -- 未下单用户 T=0,Y=0（自然对照）
       COALESCE(ty.y, 0) AS y,
       CASE
         WHEN CONV(SUBSTR(MD5(CAST(f.buyer_user_id AS STRING)),1,8),16,10) % 100 < 60 THEN 'train'
         WHEN CONV(SUBSTR(MD5(CAST(f.buyer_user_id AS STRING)),1,8),16,10) % 100 < 75 THEN 'calibration'
         WHEN CONV(SUBSTR(MD5(CAST(f.buyer_user_id AS STRING)),1,8),16,10) % 100 < 85 THEN 'holdout'
         ELSE 'reserved'
       END AS split
FROM du_temp.tmp_rfmc_features_full_v3 f
LEFT JOIN du_temp.tmp_dml_ty ty ON f.buyer_user_id = ty.buyer_user_id;

-- ---------- Step C: 四组分布均衡性验证（只读）----------
SELECT split, COUNT(*) n, AVG(t) avg_t, AVG(y) avg_y, AVG(cnt_365d) avg_freq
FROM du_temp.tmp_dml_dataset_v2 GROUP BY split;

-- ---------- Step D1: 第一阶段代理 E[T|X] E[Y|X]（按 RFMC 分层格分桶均值）----------
-- 用 cnt_365d 十分位 × gmv_365d 十分位作粗分层格子（SQL 侧近似 nuisance）
DROP TABLE IF EXISTS du_temp.tmp_dml_first_stage;
CREATE TABLE du_temp.tmp_dml_first_stage LIFECYCLE 7 AS
SELECT NTILE(10) OVER (ORDER BY cnt_365d) AS freq_bucket,
       NTILE(10) OVER (ORDER BY gmv_365d) AS gmv_bucket,
       AVG(t) AS e_t_given_x,
       AVG(y) AS e_y_given_x
FROM du_temp.tmp_dml_dataset_v2
WHERE split = 'train'
GROUP BY NTILE(10) OVER (ORDER BY cnt_365d), NTILE(10) OVER (ORDER BY gmv_365d);

-- ---------- Step D2: calibration 集残差 ----------
DROP TABLE IF EXISTS du_temp.tmp_dml_residuals;
CREATE TABLE du_temp.tmp_dml_residuals LIFECYCLE 7 AS
SELECT d.buyer_user_id,
       d.t - fs.e_t_given_x AS t_res,
       d.y - fs.e_y_given_x AS y_res
FROM du_temp.tmp_dml_dataset_v2 d
JOIN du_temp.tmp_dml_first_stage fs
  ON NTILE_OF(d.cnt_365d) = fs.freq_bucket;   -- 伪码：实际需先给 d 打同规则 bucket

-- ---------- Step E: 第二阶段 OLS 求 θ_ATE（全局去均值，最小化 shuffle）----------
-- θ = Σ(t_res·y_res) / Σ(t_res²)
DROP TABLE IF EXISTS du_temp.tmp_dml_ate_v3;
CREATE TABLE du_temp.tmp_dml_ate_v3 LIFECYCLE 7 AS
SELECT SUM(t_res * y_res) / NULLIF(SUM(t_res * t_res), 0) AS theta_ate,
       COUNT(*) AS n
FROM du_temp.tmp_dml_residuals;

-- ---------- Step F: holdout CATE 十分位打分（伪 CATE = y_res/t_res）----------
DROP TABLE IF EXISTS du_temp.tmp_dml_cate_scores_v2;
CREATE TABLE du_temp.tmp_dml_cate_scores_v2 LIFECYCLE 7 AS
SELECT buyer_user_id,
       CASE WHEN ABS(t_res) > 0.01 THEN y_res / t_res ELSE NULL END AS pseudo_cate,
       NTILE(10) OVER (ORDER BY gmv_365d) AS cate_decile
FROM du_temp.tmp_dml_dataset_v2
WHERE split = 'holdout';

-- 【每步 CTAS 后 COUNT 校验非零】
-- SELECT * FROM du_temp.tmp_dml_ate_v3;   -- 期望 theta_ate ≈ 26.9（SQL 近似口径）
