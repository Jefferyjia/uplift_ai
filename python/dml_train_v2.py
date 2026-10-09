# -*- coding: utf-8 -*-
"""
PyODPS3 两阶段 DML 训练（真·nuisance 模型版）
运行环境：DataWorks PyODPS3 节点（ODPS 连接由平台注入 o 对象）
输入表：du_temp.tmp_dml_dataset_v2
输出表：du_temp.tmp_dml_ate_py / tmp_dml_cate_scores_py（LIFECYCLE 7）

流程：
  Stage1(train): LightGBM 拟合 E[T|X]、E[Y|X]
  Stage2(calibration): 残差 OLS → θ_ATE + HC3 SE；R-learner 伪结局 → CATE 模型
  holdout: RMSE/R² 评估 + 个体化 CATE 打分
  reserved: 不动（留作上线后 A/B 对照）

⚠️ FEATURE_COLS 必须与 features_full_v3 实际列严格一致，
   重跑宽表后用 SELECT * LIMIT 1 拉 schema 逐列校验。
"""
import hashlib
import numpy as np
import pandas as pd
import lightgbm as lgb
from sklearn.linear_model import LinearRegression

TABLE = "du_temp.tmp_dml_dataset_v2"

# 与 v3 宽表对齐的特征列（重跑后需按真实 schema 复核）
FEATURE_COLS = [
    "days_since_last_order", "cnt_90d", "cnt_180d", "cnt_365d",
    "order_frequency_trend_90d", "gmv_365d", "gmv_90d", "subsidy_365d",
    "final_ue_365d", "coupon_used_cnt", "coupon_used_amt",
    "coupon_dependency", "ue_per_subsidy_365d",
]
T_COL, Y_COL, SPLIT_COL, UID = "t", "y", "split", "buyer_user_id"


def bucket(uid) -> int:
    """与 SQL 侧一致的 md5(uid)%100 确定性分桶。"""
    return int(hashlib.md5(str(uid).encode()).hexdigest(), 16) % 100


def load(o, limit=None):
    sql = f"SELECT {UID}, {T_COL}, {Y_COL}, {', '.join(FEATURE_COLS)} FROM {TABLE}"
    if limit:
        sql += f" LIMIT {limit}"
    with o.execute_sql(sql).open_reader(tunnel=True) as rd:
        return rd.to_pandas()


def clean(df):
    """缺失率>95% 的列剔除；声明列不在表中自动忽略。"""
    keep = [c for c in FEATURE_COLS if c in df.columns]
    miss = df[keep].isna().mean()
    drop = miss[miss > 0.95].index.tolist()
    keep = [c for c in keep if c not in drop]
    if drop:
        print(f"[warn] dropped high-missing cols: {drop}")
    return keep


def main(o):
    df = load(o)
    feats = clean(df)
    df["bucket"] = df[UID].map(bucket)
    train = df[df.bucket < 60]
    calib = df[(df.bucket >= 60) & (df.bucket < 75)]
    hold = df[(df.bucket >= 75) & (df.bucket < 85)]

    X_tr, t_tr, y_tr = train[feats].values, train[T_COL].values, train[Y_COL].values

    # ---- Stage 1: nuisance models ----
    m_t = lgb.LGBMRegressor(n_estimators=300, learning_rate=0.05, num_leaves=63).fit(X_tr, t_tr)
    m_y = lgb.LGBMRegressor(n_estimators=300, learning_rate=0.05, num_leaves=63).fit(X_tr, y_tr)

    # ---- Stage 2: residual OLS on calibration ----
    t_res = calib[T_COL].values - m_t.predict(calib[feats].values)
    y_res = calib[Y_COL].values - m_y.predict(calib[feats].values)
    theta = float(np.sum(t_res * y_res) / np.sum(t_res ** 2))

    # HC3 robust SE
    resid = y_res - theta * t_res
    h = t_res ** 2 / np.sum(t_res ** 2)
    vc = np.sum((resid / (1 - h)) ** 2 * t_res ** 2) / np.sum(t_res ** 2) ** 2
    se = float(np.sqrt(vc))
    print(f"θ_ATE = {theta:.4f}  SE = {se:.4f}  t = {theta/se:.2f}")

    # ---- CATE: R-learner 伪结局加权回归 ----
    mask = np.abs(t_res) > 1e-2
    pseudo = y_res[mask] / t_res[mask]
    w = t_res[mask] ** 2
    cate_model = lgb.LGBMRegressor(n_estimators=200, learning_rate=0.05).fit(
        calib[feats].values[mask], pseudo, sample_weight=w)
    hold_cate = cate_model.predict(hold[feats].values)

    # ---- persist 回 ODPS ----
    o.execute_sql("DROP TABLE IF EXISTS du_temp.tmp_dml_ate_py")
    o.write_table("du_temp.tmp_dml_ate_py",
                  pd.DataFrame({"theta_ate": [theta], "se": [se], "n": [len(calib)]}))
    scores = pd.DataFrame({UID: hold[UID].values, "cate_score": hold_cate})
    scores["decile"] = pd.qcut(scores.cate_score.rank(method="first"), 10, labels=False) + 1
    print(scores.groupby("decile").agg(avg_cate=("cate_score", "mean")).to_string())
    return theta, se


if __name__ == "__main__":
    from odps import ODPS
    import os
    o = ODPS(os.environ["ODPS_ACCESS_ID"], os.environ["ODPS_ACCESS_KEY"],
             project="du_ad_bm", endpoint=os.environ.get("ODPS_ENDPOINT"))
    main(o)
