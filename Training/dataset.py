# -*- coding: utf-8 -*-
"""dataset.py — Reframe 弱監督配對資料集 v3（MASTER-PLAN §4.3）。

v2 訓練實測 val pairwise acc ≈ 0.53（丟銅板）— 驗屍結論（Kaggle run v2）：
  (a) 正負例處理管線不對稱（正例 1 次 resize；負例裁切+旋轉+縮放 2 次重採樣）
      → 模型學「處理痕跡」不學構圖，train loss 0.004 / val 53%。
  (b) 正例做 center square crop：3:2 橫幅被砍掉左右 1/3，「專業取景」訊號
      根本沒進正例；scale 0.95 的負例窗與正例幾乎相同卻標反 → 標籤噪音。

v3 構造原則：**兩支样本唯一的差異只能是「取景幾何」本身**：
  正例 pos = 全帧視窗（scale=1、置中）
  負例 neg = 同長寬比隨機視窗：scale U(0.55, 0.90)、位置均勻、無旋轉
  兩者走完全相同的路徑：crop(視窗) → resize((size,size)) squash（同插值、
  同重採樣次數）。squash 造成的變形兩者一致（同 aspect），不構成可作弊差異。
  旋轉整個移除：水平歪斜由 App 層 CoreMotion 規則負責，模型不需要，而旋轉
  插值是 v2 的作弊通道之一。

  ★ 縮放幅度差審查（v3 對抗性審查結論，動這段管線前必讀）：
  疑點：pos 恆縮 ~2.9x（640→224）、neg 只縮 1.6~2.6x，縮放比分佈零重疊 ——
  若銳利度/噪點/JPEG 痕跡隨縮放比變化，標籤直接洩漏（且 dzoom=log(1/scale)
  恰為縮放比之差，delta 頭也能純靠低階痕跡回歸）。
  實證（真實照片 × imgix 模擬管線、內容受控反事實實驗）：判定為**理論性
  通道，實務不成立**——PIL 的 Image.resize 是 antialiased（kernel 支撐隨縮放
  比伸縮 = 輸出座標下濾波器固定），場景內容 MTF 與縮放比無關；實測
  HF/噪點底/方塊梳三特徵的 content-controlled AUC = 0.51/0.55/0.51（≈丟銅板）。
  曾試過「pos 先縮到 (ww,wh) 對齊解析度」補丁：pos 多一層複合濾波反而
  變系統性偏軟（HF AUC 0.505→0.557、均值 −10%）→ 製造新通道，已撤回。
  載重不變量（破壞任一條，上述結論作廢）：
  (1) 兩支都必須走 PIL Image.resize + BILINEAR。換 torch/cv2 的 naive
      bilinear（固定 2x2 kernel、無抗鋸齒）對稱性立刻崩潰 —— 白噪音實驗
      HF 比值恰 = scale，可直接讀出標籤。
  (2) 資料源必須維持低解析縮圖（640px q80；活的感光噪點/JPEG 格已被
      Lanczos 9x 縮小殺掉）。換高解析原檔會讓釘在原圖像素格上的痕跡復活
      成「縮放比讀數」，任何重採樣幾何都救不了，只能靠對稱隨機退化
      （blur/re-JPEG 兩支同分佈）壓制。
  (3) 驗收時 val acc > 0.95 應優先懷疑低階通道復活，而非慶祝。

  ★ v4 追加（動機：v3 實測 val 0.63 但 train loss 0.004 = 逐張過擬合）：
  (1) augment 旗標（預設 False）：train.py 只在訓練 epoch 打開。開啟時 ——
      pos 改為「近全帧微抖動視窗」scale U(0.95, 1.0)、位置在餘裕內均勻
      （仍是好取景，但逐 epoch 像素不同 → 消除 v3 的恆定記憶錨點）；
      光度增強（亮度/對比/飽和、偶爾灰階、偶爾輕模糊）與水平翻轉。
  (2) 增強對稱鐵律：所有光度/翻轉操作「同一組參數、同時套在 pos 與 neg」
      且一律在 resize 之後的輸出空間執行 —— 任何只套一支或參數不同的增強，
      都會變成新的作弊通道（同 v3 審查結論）。翻轉時兩支 delta 的 dx 同步取負。
  (3) augment=False（驗證/評測）：pos = 全帧、無任何增強，且 neg 的 RNG
      消耗順序與 v3 完全一致 → val 數字可與 v3 基線直接比較。

  delta（v4 起 pos/neg 各一）= 該視窗相對理想取景（=全帧）的誤差向量：
      dx = (視窗中心x − 圖中心x) / w        neg ∈ (-0.225, 0.225)；pos 微小
      dy = (視窗中心y − 圖中心y) / h        同上
      dzoom = log(1/scale)                  neg ∈ (0.105, 0.598)；pos ∈ [0, 0.051)
  修正指令 = −delta（README「Swift 介面」節同語意；模型不產生「上前」訊號）。

回傳 (pos_tensor, neg_tensor, delta_pos, delta_neg)；影像為 ImageNet 正規化
float32 (3,size,size)。壞圖 try/except 換下一張。隨機性：numpy Generator 種子
= (seed, epoch, index)，與 worker 數無關可重現；train.py 每輪 set_epoch()，
驗證/評測固定 epoch=0。
"""

from __future__ import annotations

import math
import os

import numpy as np
import torch
from PIL import Image, ImageEnhance, ImageFilter
from torch.utils.data import Dataset

IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
IMAGENET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)
IMAGE_EXTS = (".jpg", ".jpeg", ".png")
MIN_SIDE = 64  # 短邊小於此值視為壞圖
NEG_SCALE_LO = 0.55
NEG_SCALE_HI = 0.90  # 上限 0.90：0.9x 以上的視窗與全帧太像，會變標籤噪音
POS_SCALE_LO = 0.95  # v4：訓練時 pos 為近全帧微抖動視窗（仍與 neg 上限 0.90 有間隙）
AUG_GRAY_P = 0.10
AUG_BLUR_P = 0.15


def _to_tensor(img: Image.Image) -> torch.Tensor:
    """PIL RGB → ImageNet 正規化 float32 tensor (3, H, W)。"""
    arr = np.asarray(img, dtype=np.float32) / 255.0
    arr = (arr - IMAGENET_MEAN) / IMAGENET_STD
    return torch.from_numpy(np.ascontiguousarray(arr.transpose(2, 0, 1)))


def _window(img: Image.Image, box: tuple[int, int, int, int], size: int) -> Image.Image:
    """視窗 → squash resize（PIL）。正負例都必須走這一條路徑（對稱性鐵律）：
    任何只套在其中一支的處理（旋轉/濾波/二次縮放）都是模型的作弊通道。
    這裡的 PIL BILINEAR 是載重不變量：PIL resize 有抗鋸齒（輸出座標下濾波器
    固定），縮放幅度差才不會洩漏標籤 —— 詳見模組 docstring 的審查結論；
    絕不可換成 torch/cv2 的 naive bilinear。"""
    return img.crop(box).resize((size, size), Image.BILINEAR)


def _apply_photometric(img: Image.Image, params: tuple[float, float, float, bool, float]) -> Image.Image:
    """光度增強（v4）。呼叫端保證：同一組 params 套 pos 與 neg 兩支、且在
    resize 之後的輸出空間執行（輸出尺寸相同 → 操作效果對稱，無縮放耦合）。"""
    brightness, contrast, saturation, gray, blur_radius = params
    img = ImageEnhance.Brightness(img).enhance(brightness)
    img = ImageEnhance.Contrast(img).enhance(contrast)
    img = ImageEnhance.Color(img).enhance(saturation)
    if gray:
        img = img.convert("L").convert("RGB")
    if blur_radius > 0:
        img = img.filter(ImageFilter.GaussianBlur(blur_radius))
    return img


class ReframePairDataset(Dataset):
    def __init__(self, img_dir: str, size: int = 224, seed: int | None = None):
        self.img_dir = img_dir
        self.size = int(size)
        self.seed = seed
        self.epoch = 0
        # v4：訓練增強旗標。預設 False（驗證/評測走乾淨路徑），train.py 於
        # 訓練 epoch 設 True、驗證前設回 False（DataLoader 每輪重建 iterator，
        # worker 會拿到當下的 dataset 狀態）。
        self.augment = False
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

        # ---- 負例：同長寬比隨機視窗（唯一差異 = 取景幾何）----
        # RNG 消耗順序鐵律：neg 的三個 draw 永遠最先，之後才是 v4 的 pos 抖動
        # 與增強 draw —— 這讓 augment=False 時 neg 視窗與 v3 基線完全相同。
        n_scale = float(rng.uniform(NEG_SCALE_LO, NEG_SCALE_HI))
        nw = max(1, int(round(w * n_scale)))
        nh = max(1, int(round(h * n_scale)))
        nx0 = int(rng.integers(0, w - nw + 1))
        ny0 = int(rng.integers(0, h - nh + 1))

        # ---- 正例：全帧（乾淨路徑）或近全帧微抖動視窗（v4 訓練路徑）----
        if self.augment:
            p_scale = float(rng.uniform(POS_SCALE_LO, 1.0))
            pw = max(1, int(round(w * p_scale)))
            ph = max(1, int(round(h * p_scale)))
            px0 = int(rng.integers(0, w - pw + 1))
            py0 = int(rng.integers(0, h - ph + 1))
        else:
            p_scale, pw, ph, px0, py0 = 1.0, w, h, 0, 0

        pos_img = _window(img, (px0, py0, px0 + pw, py0 + ph), size)
        neg_img = _window(img, (nx0, ny0, nx0 + nw, ny0 + nh), size)

        # ---- delta：各視窗相對全帧的誤差向量 ----
        def _delta(x0: int, y0: int, ww: int, wh: int, scale: float) -> list[float]:
            return [((x0 + ww / 2.0) - w / 2.0) / w,
                    ((y0 + wh / 2.0) - h / 2.0) / h,
                    math.log(1.0 / scale)]

        d_pos = _delta(px0, py0, pw, ph, p_scale)
        d_neg = _delta(nx0, ny0, nw, nh, n_scale)

        # ---- v4 對稱增強：同一組參數、兩支同套、resize 後執行 ----
        if self.augment:
            params = (
                float(rng.uniform(0.75, 1.25)),                                  # 亮度
                float(rng.uniform(0.80, 1.20)),                                  # 對比
                float(rng.uniform(0.70, 1.30)),                                  # 飽和
                bool(rng.random() < AUG_GRAY_P),                                 # 灰階
                float(rng.uniform(0.3, 1.0)) if rng.random() < AUG_BLUR_P else 0.0,  # 模糊
            )
            pos_img = _apply_photometric(pos_img, params)
            neg_img = _apply_photometric(neg_img, params)
            if rng.random() < 0.5:  # 水平翻轉：兩支同翻、dx 同步取負
                pos_img = pos_img.transpose(Image.FLIP_LEFT_RIGHT)
                neg_img = neg_img.transpose(Image.FLIP_LEFT_RIGHT)
                d_pos[0] = -d_pos[0]
                d_neg[0] = -d_neg[0]

        return (
            _to_tensor(pos_img),
            _to_tensor(neg_img),
            torch.tensor(d_pos, dtype=torch.float32),
            torch.tensor(d_neg, dtype=torch.float32),
        )
