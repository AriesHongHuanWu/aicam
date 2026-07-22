# -*- coding: utf-8 -*-
"""model.py — ReframeNet（MASTER-PLAN §4.3b）。

MobileNetV3-Small backbone（ImageNet 預訓練，torchvision 內建、Apache 相容授權）
+ 共享 trunk + 兩顆頭：
  head_score : 構圖分（純量；pairwise ranking 訓練，數值本身無絕對意義）
  head_delta : 取景差量回歸 (dx, dy, dzoom)，語意同 dataset.py 的 delta 標籤

forward(x) → (score, delta)
  x     : (N, 3, 224, 224)，ImageNet 正規化
  score : (N,)   — 已 squeeze(-1)
  delta : (N, 3)
"""

from __future__ import annotations

import torch
from torch import nn
from torchvision.models import MobileNet_V3_Small_Weights, mobilenet_v3_small

FEATURE_DIM = 576  # mobilenet_v3_small.features 輸出通道數


class ReframeNet(nn.Module):
    def __init__(self, pretrained: bool = True, freeze_backbone: bool = False):
        """freeze_backbone=True（v5）：features 全凍結（requires_grad=False）。
        動機：v4 實測 train_acc 0.99/val 0.55 = 模型用 backbone 容量「背每張
        訓練圖的版面」而非學通用構圖；凍結後只剩小 head 可訓練，記憶路徑
        被封死。注意：凍結時 train.py 必須每個 epoch 在 model.train() 後補
        model.features.eval()，否則 BatchNorm running stats 仍會被訓練資料
        污染（見 train.py）。"""
        super().__init__()
        weights = MobileNet_V3_Small_Weights.IMAGENET1K_V1 if pretrained else None
        self.features = mobilenet_v3_small(weights=weights).features
        self.frozen_backbone = bool(freeze_backbone)
        if self.frozen_backbone:
            self.features.requires_grad_(False)
        self.pool = nn.AdaptiveAvgPool2d(1)
        self.trunk = nn.Sequential(
            nn.Linear(FEATURE_DIM, 256),
            nn.ReLU(inplace=True),
            nn.Dropout(0.2),  # v4：抗過擬合（v3 train loss 0.004 / val 0.63）
        )
        self.head_score = nn.Linear(256, 1)
        self.head_delta = nn.Linear(256, 3)

    def forward(self, x: torch.Tensor):
        feat = self.pool(self.features(x)).flatten(1)  # (N, 576)
        t = self.trunk(feat)                           # (N, 256)
        score = self.head_score(t).squeeze(-1)         # (N,)
        delta = self.head_delta(t)                     # (N, 3)
        return score, delta
