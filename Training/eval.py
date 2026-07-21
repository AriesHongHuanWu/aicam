#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""eval.py — Reframe 模型 §4.8 離線評測閘門（pairwise accuracy ≥ 0.85）。

用法（一律從 repo 根目錄執行）：
    python Training/eval.py --data Training/data/images
    python Training/eval.py --data Training/data/images --ckpt Training/checkpoints/best.pt

行為：
 1. 載入 checkpoint（train.py 存的 best.pt / last.pt，內含 model state_dict +
    val_acc + args）。
 2. 用「與訓練完全相同」的 seed 與 val_frac（預設從 checkpoint 的 args 讀出，
    也可用 --seed / --val-frac 覆寫）重現 train/val 切分 —— split_sizes 公式與
    torch.Generator(seed) 都沿用 train.py，保證 val 集一致。
 3. 對 val 切分算 pairwise accuracy = mean(score_pos > score_neg)，
    印「GATE PASS/FAIL（門檻 0.85）」。
 4. exit code：PASS = 0、FAIL = 1（可直接接 CI / script 判斷）。

注意：這只是 §4.8 的第 1 關（離線 held-out pairwise）。第 2 關（真機 50 張
實拍盲測命中 ≥7/10）與 blend-vs-純規則 ablation 是另外的人工流程，不在本腳本內。
"""

from __future__ import annotations

import argparse
import os
import sys

# 讓「python Training/eval.py」不論 cwd 都能 import 同目錄模組
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import torch  # noqa: E402
from torch.utils.data import DataLoader, random_split  # noqa: E402

from dataset import ReframePairDataset  # noqa: E402
from model import ReframeNet  # noqa: E402
from train import evaluate_pairwise, resolve_device, split_sizes  # noqa: E402

GATE_THRESHOLD = 0.85


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Reframe §4.8 離線評測（pairwise gate 0.85）")
    p.add_argument("--ckpt", default=os.path.join("Training", "checkpoints", "best.pt"),
                   help="checkpoint 路徑（預設 Training/checkpoints/best.pt）")
    p.add_argument("--data", required=True,
                   help="圖片目錄（必須與訓練時的 --data 相同才能重現同一 val 切分）")
    p.add_argument("--batch", type=int, default=64)
    p.add_argument("--device", default="auto", help="auto / cuda / cpu")
    p.add_argument("--workers", type=int, default=2, help="DataLoader workers")
    p.add_argument("--seed", type=int, default=None,
                   help="切分 seed（預設 = checkpoint 訓練時的 seed）")
    p.add_argument("--val-frac", type=float, default=None,
                   help="val 比例（預設 = checkpoint 訓練時的 val_frac）")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    if not os.path.isfile(args.ckpt):
        print(f"找不到 checkpoint：{args.ckpt}（先跑 Training/train.py）", file=sys.stderr)
        sys.exit(1)

    ckpt = torch.load(args.ckpt, map_location="cpu", weights_only=True)
    train_args = ckpt.get("args") or {}
    seed = args.seed if args.seed is not None else int(train_args.get("seed", 42))
    val_frac = (args.val_frac if args.val_frac is not None
                else float(train_args.get("val_frac", 0.05)))

    device = resolve_device(args.device)

    # ---- 重現 train.py 的 val 切分（同 dataset seed、同 split_sizes、同 Generator）----
    dataset = ReframePairDataset(args.data, size=224, seed=seed)
    dataset.set_epoch(0)  # 與 train.py 驗證時一致：視窗固定、可重現
    n_train, n_val = split_sizes(len(dataset), val_frac)
    split_gen = torch.Generator().manual_seed(seed)
    _train_set, val_set = random_split(dataset, [n_train, n_val], generator=split_gen)

    model = ReframeNet(pretrained=False)
    model.load_state_dict(ckpt["model"])
    model.to(device)

    val_loader = DataLoader(
        val_set, batch_size=args.batch, shuffle=False,
        num_workers=args.workers, pin_memory=(device.type == "cuda"),
    )

    acc = evaluate_pairwise(model, val_loader, device)

    ckpt_acc = ckpt.get("val_acc")
    print(f"checkpoint：{args.ckpt}"
          + (f"（訓練時 val_acc={float(ckpt_acc):.4f}）" if ckpt_acc is not None else ""))
    print(f"val 切分：{n_val} 張（總 {len(dataset)}、seed={seed}、val_frac={val_frac}）")
    print(f"val pairwise accuracy = {acc:.4f}")

    if acc >= GATE_THRESHOLD:
        print(f"GATE PASS（門檻 {GATE_THRESHOLD:.2f}）— 可進行 CoreML 匯出與整合；"
              f"依 MASTER-PLAN §16 把分數寫進 commit 訊息。")
        sys.exit(0)
    print(f"GATE FAIL（門檻 {GATE_THRESHOLD:.2f}）— 依 §4.8 不達標不上線；"
          f"調整資料量 / epochs / lr 後重訓。")
    sys.exit(1)


if __name__ == "__main__":
    main()
