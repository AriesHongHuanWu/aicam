# -*- coding: utf-8 -*-
"""dataset.py — Reframe 弱監督配對資料集（MASTER-PLAN §4.3）。

每張專業照片產生一對樣本：
  正例 pos = 原始取景（短邊 resize 到 size 後 center crop size×size）
  負例 neg = 原圖內隨機視窗（模擬「取景取歪了」）：
             邊長 = min(w,h) × U(0.68, 0.95)，先裁「帶旋轉餘裕的大窗」→
             PIL rotate U(-5°, 5°) → 取內接 side×side 視窗（全為真實像素、
             無 expand=False 補黑角），最後 resize 到 size×size
  delta   = 負例視窗相對原圖的取景差量（免費監督訊號）：
             dx = (視窗中心x − 圖中心x) / w      ∈ 約 [-0.3, 0.3]
             dy = (視窗中心y − 圖中心y) / h      ∈ 約 [-0.3, 0.3]
             dzoom = log(min(w,h) / 視窗邊長)    ∈ 約 [0.05, 0.39]

回傳 (pos_tensor, neg_tensor, delta_tensor)；影像皆為 ImageNet mean/std 正規化的
float32 (3, size, size)。壞圖（截斷/太小/非影像）以 try/except 換下一張索引。

隨機性：全部走可設 seed 的 numpy Generator，種子 = (seed, epoch, index)，
與 DataLoader worker 數量無關、跨執行可重現。train.py 每個 epoch 呼叫
set_epoch(epoch) 讓訓練視窗每輪不同；驗證/評測固定 epoch=0。
"""

from __future__ import annotations

import math
import os

import numpy as np
import torch
from PIL import Image
from torch.utils.data import Dataset

IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
IMAGENET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)
IMAGE_EXTS = (".jpg", ".jpeg", ".png")
MIN_SIDE = 64  # 短邊小於此值視為壞圖


def _to_tensor(img: Image.Image) -> torch.Tensor:
    """PIL RGB → ImageNet 正規化 float32 tensor (3, H, W)。"""
    arr = np.asarray(img, dtype=np.float32) / 255.0
    arr = (arr - IMAGENET_MEAN) / IMAGENET_STD
    return torch.from_numpy(np.ascontiguousarray(arr.transpose(2, 0, 1)))


class ReframePairDataset(Dataset):
    def __init__(self, img_dir: str, size: int = 224, seed: int | None = None):
        self.img_dir = img_dir
        self.size = int(size)
        self.seed = seed
        self.epoch = 0
        if not os.path.isdir(img_dir):
            raise FileNotFoundError(f"找不到圖片目錄：{img_dir}")
        self.files = sorted(
            os.path.join(img_dir, name)
            for name in os.listdir(img_dir)
            if name.lower().endswith(IMAGE_EXTS)
        )
        if not self.files:
            raise RuntimeError(f"{img_dir} 內沒有 {IMAGE_EXTS} 圖片")

    def set_epoch(self, epoch: int) -> None:
        """train.py 每輪呼叫；驗證/評測用預設 0（視窗固定、可重現）。"""
        self.epoch = int(epoch)

    def __len__(self) -> int:
        return len(self.files)

    def _rng(self, index: int) -> np.random.Generator:
        if self.seed is None:
            return np.random.default_rng()
        return np.random.default_rng([int(self.seed), self.epoch, index])

    def __getitem__(self, index: int):
        # 壞圖換下一張索引，最多試 100 張。
        for attempt in range(100):
            i = (index + attempt) % len(self.files)
            try:
                return self._make_pair(i)
            except Exception:  # noqa: BLE001 — 壞圖/截斷檔一律跳過
                continue
        raise RuntimeError(f"連續 100 張圖片都無法讀取（起點 index={index}）")

    def _make_pair(self, i: int):
        size = self.size
        with Image.open(self.files[i]) as raw:
            img = raw.convert("RGB")
        w, h = img.size
        if min(w, h) < MIN_SIDE:
            raise ValueError(f"圖太小：{w}x{h}")

        rng = self._rng(i)

        # ---- 正例：短邊 resize 到 size，再 center crop size×size ----
        scale = size / min(w, h)
        rw = max(size, int(round(w * scale)))
        rh = max(size, int(round(h * scale)))
        resized = img.resize((rw, rh), Image.BILINEAR)
        left = (rw - size) // 2
        top = (rh - size) // 2
        pos_img = resized.crop((left, top, left + size, top + size))

        # ---- 負例：隨機視窗 + 小角度旋轉 ----
        # 先取「帶旋轉餘裕的大窗」→ 旋轉 → 再取內接的 side×side 視窗，
        # 保證視窗內全是真實像素。若先裁再轉（expand=False），角落會補黑 —
        # 模型只要偵測黑角就能分辨正負例，pairwise accuracy 閘門會被假象灌水。
        angle = float(rng.uniform(-5.0, 5.0))
        rad = math.radians(abs(angle))
        margin = math.cos(rad) + math.sin(rad)  # 內接視窗所需外框倍率（≤ ~1.084）
        side = int(round(min(w, h) * float(rng.uniform(0.68, 0.95))))
        side = max(1, min(side, int(min(w, h) / margin)))
        big = min(min(w, h), max(side, int(math.ceil(side * margin))))
        x0 = int(rng.integers(0, w - big + 1))
        y0 = int(rng.integers(0, h - big + 1))
        big_img = img.crop((x0, y0, x0 + big, y0 + big))
        big_img = big_img.rotate(angle, resample=Image.BILINEAR, expand=False)
        off = (big - side) // 2
        neg_img = big_img.crop((off, off, off + side, off + side))
        neg_img = neg_img.resize((size, size), Image.BILINEAR)

        # ---- delta 標籤（負例視窗的取景差量）----
        # 旋轉以大窗中心為圓心，內接視窗中心 = 大窗中心。
        dx = ((x0 + big / 2.0) - w / 2.0) / w
        dy = ((y0 + big / 2.0) - h / 2.0) / h
        dzoom = math.log(min(w, h) / side)
        delta = torch.tensor([dx, dy, dzoom], dtype=torch.float32)

        return _to_tensor(pos_img), _to_tensor(neg_img), delta
