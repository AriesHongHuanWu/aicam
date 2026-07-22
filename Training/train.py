#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""train.py — Reframe 模型訓練（MASTER-PLAN §4.3 訓練配方步驟 2）。

用法（一律從 repo 根目錄執行）：
    python Training/train.py --data Training/data/images
    python Training/train.py --data Training/data/images --epochs 2 --batch 32   # smoke

損失（v4 — 動機：v3 margin loss 第 4 輪就飽和到 0.004、val 卡 0.63 過擬合）：
  rank  = softplus(-(s_pos - s_neg)).mean()      # BPR 型，永不完全飽和
  delta = 1.0 × SmoothL1(d_neg/D, gt_neg/D) + 0.3 × SmoothL1(d_pos/D, gt_pos/D)
          D = (0.225, 0.225, 0.598) 各維上限正規化（v3 審查建議：未正規化時
          delta 項只占總損失 ~2%，delta 頭學不動）
其他 v4 反過擬合手段：dataset.augment（對稱增強+pos 微抖動，只在訓練 epoch
開）、AdamW weight_decay 0.01、backbone 學習率 = 0.1×（heads 全速）、
model.py trunk 加 Dropout(0.2)。每 epoch 另印 train pairwise acc 監控泛化差距。

輸出：--out 目錄下 best.pt（val pairwise accuracy 最高，含 model state_dict +
val_acc + args）與 last.pt。
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from contextlib import nullcontext

# 讓「python Training/train.py」不論 cwd 都能 import 同目錄模組
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import torch  # noqa: E402
from torch import nn  # noqa: E402
from torch.utils.data import DataLoader, random_split  # noqa: E402

from dataset import ReframePairDataset  # noqa: E402
from model import ReframeNet  # noqa: E402


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="訓練 ReframeNet（pairwise ranking + delta 回歸）")
    p.add_argument("--data", required=True, help="訓練圖片目錄（fetch_unsplash_lite.py 的 --out）")
    p.add_argument("--out", default=os.path.join("Training", "checkpoints"),
                   help="checkpoint 輸出目錄（預設 Training/checkpoints）")
    p.add_argument("--epochs", type=int, default=8)
    p.add_argument("--batch", type=int, default=64)
    p.add_argument("--lr", type=float, default=3e-4)
    p.add_argument("--val-frac", type=float, default=0.05)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--device", default="auto", help="auto / cuda / cpu")
    p.add_argument("--workers", type=int, default=2, help="DataLoader workers")
    return p.parse_args()


def resolve_device(name: str) -> torch.device:
    if name == "auto":
        if torch.cuda.is_available():
            return torch.device("cuda")
        print("警告：未偵測到 CUDA GPU，改用 CPU 訓練（會非常慢）。")
        return torch.device("cpu")
    dev = torch.device(name)
    if dev.type == "cuda" and not torch.cuda.is_available():
        print("警告：指定 cuda 但不可用，改用 CPU 訓練（會非常慢）。")
        return torch.device("cpu")
    return dev


def split_sizes(n: int, val_frac: float) -> tuple[int, int]:
    """train/val 切分大小 — eval.py 依同一公式重現，勿改動。"""
    n_val = max(1, int(round(n * val_frac)))
    n_val = min(n_val, n - 1)
    return n - n_val, n_val


@torch.no_grad()
def evaluate_pairwise(model: nn.Module, loader: DataLoader, device: torch.device) -> float:
    """val pairwise accuracy = mean(score_pos > score_neg)。全精度、無隨機。"""
    model.eval()
    correct = 0
    total = 0
    for pos, neg, *_ in loader:
        pos = pos.to(device, non_blocking=True)
        neg = neg.to(device, non_blocking=True)
        s_pos, _ = model(pos)
        s_neg, _ = model(neg)
        correct += (s_pos > s_neg).sum().item()
        total += pos.size(0)
    return correct / max(1, total)


def main() -> None:
    args = parse_args()
    torch.manual_seed(args.seed)
    device = resolve_device(args.device)
    use_amp = device.type == "cuda"
    os.makedirs(args.out, exist_ok=True)

    dataset = ReframePairDataset(args.data, size=224, seed=args.seed)
    n_train, n_val = split_sizes(len(dataset), args.val_frac)
    split_gen = torch.Generator().manual_seed(args.seed)
    train_set, val_set = random_split(dataset, [n_train, n_val], generator=split_gen)
    print(f"資料：{len(dataset)} 張（train {n_train} / val {n_val}）；device={device.type}")

    loader_gen = torch.Generator().manual_seed(args.seed)
    train_loader = DataLoader(
        train_set, batch_size=args.batch, shuffle=True, generator=loader_gen,
        num_workers=args.workers, pin_memory=use_amp, drop_last=False,
    )
    val_loader = DataLoader(
        val_set, batch_size=args.batch, shuffle=False,
        num_workers=args.workers, pin_memory=use_amp,
    )

    model = ReframeNet(pretrained=True).to(device)
    # v4：backbone 低速微調、heads 全速；weight_decay 拉到 0.01 抗過擬合。
    optimizer = torch.optim.AdamW(
        [
            {"params": model.features.parameters(), "lr": args.lr * 0.1},
            {"params": list(model.trunk.parameters())
                       + list(model.head_score.parameters())
                       + list(model.head_delta.parameters()), "lr": args.lr},
        ],
        weight_decay=0.01,
    )
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    smooth_l1 = nn.SmoothL1Loss()
    # v4：delta 各維以標籤上限正規化（docstring 損失定義）。
    delta_norm = torch.tensor([0.225, 0.225, 0.598], device=device)
    scaler = torch.amp.GradScaler("cuda", enabled=use_amp)

    def amp_ctx():
        if use_amp:
            return torch.autocast(device_type="cuda", dtype=torch.float16)
        return nullcontext()

    def save_ckpt(path: str, epoch: int, val_acc: float) -> None:
        torch.save({
            "model": model.state_dict(),
            "val_acc": float(val_acc),
            "epoch": int(epoch),
            "args": vars(args),
        }, path)

    best_acc = -1.0
    best_path = os.path.join(args.out, "best.pt")
    last_path = os.path.join(args.out, "last.pt")

    for epoch in range(1, args.epochs + 1):
        # 訓練視窗每輪換一批（epoch 混入 RNG 種子）；驗證固定 epoch=0 + 關增強。
        dataset.set_epoch(epoch)
        dataset.augment = True
        model.train()
        t0 = time.time()
        loss_sum = 0.0
        n_seen = 0
        n_rank_ok = 0
        for pos, neg, dpos_gt, dneg_gt in train_loader:
            pos = pos.to(device, non_blocking=True)
            neg = neg.to(device, non_blocking=True)
            dpos_gt = dpos_gt.to(device, non_blocking=True)
            dneg_gt = dneg_gt.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            with amp_ctx():
                s_pos, d_pos = model(pos)
                s_neg, d_neg = model(neg)
                loss = (
                    torch.nn.functional.softplus(-(s_pos - s_neg)).mean()
                    + 1.0 * smooth_l1(d_neg / delta_norm, dneg_gt / delta_norm)
                    + 0.3 * smooth_l1(d_pos / delta_norm, dpos_gt / delta_norm)
                )
            scaler.scale(loss).backward()
            scaler.step(optimizer)
            scaler.update()
            loss_sum += loss.item() * pos.size(0)
            n_rank_ok += (s_pos > s_neg).sum().item()
            n_seen += pos.size(0)
        scheduler.step()
        train_loss = loss_sum / max(1, n_seen)
        train_acc = n_rank_ok / max(1, n_seen)

        dataset.set_epoch(0)
        dataset.augment = False
        val_acc = evaluate_pairwise(model, val_loader, device)
        print(f"epoch {epoch}/{args.epochs}  train_loss={train_loss:.4f}  "
              f"train_acc={train_acc:.4f}  val_pairwise_acc={val_acc:.4f}  "
              f"({time.time() - t0:.0f}s)")

        save_ckpt(last_path, epoch, val_acc)
        if val_acc > best_acc:
            best_acc = val_acc
            save_ckpt(best_path, epoch, val_acc)
            print(f"  ↳ 新 best（val_acc={val_acc:.4f}）→ {best_path}")

    print(f"完成。best val_pairwise_acc={best_acc:.4f}；"
          f"§4.8 門檻 0.85 → 用 Training/eval.py 正式驗收。")


if __name__ == "__main__":
    main()
