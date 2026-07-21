#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""export_coreml.py — best.pt → Core ML mlpackage（mlprogram、FP16）。

⚠️ 平台限制：coremltools 只支援 macOS / Linux，Windows 本機裝不起來。
   在 Windows 上請走 GitHub Actions 的 model-export workflow：
   1. 先把訓練好的 Training/checkpoints/best.pt commit + push 上 repo
   2. GitHub → Actions → model-export → Run workflow（workflow_dispatch）
   3. 跑完到該 run 的 Artifacts 下載，解兩層 zip 得到完整的
      ReframeModel.mlpackage/ 資料夾（必須整個資料夾一起放）

用法（macOS / Linux / CI，一律從 repo 根目錄執行）：
    python Training/export_coreml.py
    python Training/export_coreml.py --ckpt Training/checkpoints/best.pt \
        --out Training/checkpoints/ReframeModel.mlpackage

輸入前處理（Swift 端不用自己做正規化）：
  Core ML ImageType 收 RGB 影像（0–255），先做 y = x/255 − mean（scale/bias），
  模型內部再除以 per-channel std —— 合起來 = 精確的 ImageNet 正規化，
  與 Training/dataset.py 的訓練前處理逐通道一致（不是常見的 1/(255·0.226) 近似）。

輸出：
  score : (1,)  構圖分（pairwise 排序用，數值無絕對意義）
  delta : (1,3) 取景差量 (dx, dy, dzoom)，語意同 dataset.py 的 delta 標籤
          = 目前取景相對理想取景的誤差向量；App 端修正指令 = −delta：
          dx>0 → 往左移、dy>0 → 取景抬高、dzoom>0 → 退後/換廣角。
          注意 dzoom 訓練標籤恆 ≥ 0（無「太鬆」負例），負/小值不可解讀成上前。
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys

# 讓「python Training/export_coreml.py」不論 cwd 都能 import 同目錄模組
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import torch  # noqa: E402
from torch import nn  # noqa: E402

from model import ReframeNet  # noqa: E402

IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)


class ExportWrapper(nn.Module):
    """收 (x/255 − mean) 的輸入（由 ImageType scale/bias 產生），內部再除以
    per-channel std 完成精確 ImageNet 正規化，然後跑 ReframeNet。"""

    def __init__(self, net: nn.Module):
        super().__init__()
        self.net = net
        self.register_buffer(
            "std", torch.tensor(IMAGENET_STD, dtype=torch.float32).view(1, 3, 1, 1)
        )

    def forward(self, x: torch.Tensor):
        return self.net(x / self.std)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="ReframeNet checkpoint → Core ML mlpackage")
    p.add_argument("--ckpt", default=os.path.join("Training", "checkpoints", "best.pt"),
                   help="checkpoint 路徑（預設 Training/checkpoints/best.pt）")
    p.add_argument("--out",
                   default=os.path.join("Training", "checkpoints", "ReframeModel.mlpackage"),
                   help="mlpackage 輸出路徑")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    try:
        import coremltools as ct
    except ImportError:
        print(
            "找不到 coremltools（Windows 不支援安裝）。\n"
            "請改走 GitHub Actions 的 model-export workflow（見本檔檔頭說明），\n"
            "或在 macOS/Linux 上 `pip install coremltools` 後重跑。",
            file=sys.stderr,
        )
        sys.exit(1)

    if not os.path.isfile(args.ckpt):
        print(
            f"找不到 checkpoint：{args.ckpt}\n"
            "先跑 Training/train.py 產生 best.pt；若是在 CI 上跑，"
            "記得 best.pt 必須先 commit + push 進 repo。",
            file=sys.stderr,
        )
        sys.exit(1)

    ckpt = torch.load(args.ckpt, map_location="cpu", weights_only=True)
    net = ReframeNet(pretrained=False)
    net.load_state_dict(ckpt["model"])
    net.eval()
    wrapper = ExportWrapper(net).eval()

    example = torch.rand(1, 3, 224, 224)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)

    # ImageType：y = scale·x + bias（x ∈ 0–255）→ y = x/255 − mean
    scale = 1.0 / 255.0
    bias = [-m for m in IMAGENET_MEAN]

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.ImageType(
            name="image",
            shape=(1, 3, 224, 224),
            scale=scale,
            bias=bias,
            color_layout=ct.colorlayout.RGB,
        )],
        outputs=[ct.TensorType(name="score"), ct.TensorType(name="delta")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )

    val_acc = ckpt.get("val_acc")
    mlmodel.short_description = (
        "AICam ReframeNet — 構圖評分 + 取景差量 (dx, dy, dzoom)。"
        "MASTER-PLAN §4.3b；weakly-supervised、Unsplash Lite 訓練。"
    )
    if val_acc is not None:
        mlmodel.user_defined_metadata["val_pairwise_acc"] = f"{float(val_acc):.4f}"

    out = args.out
    if os.path.exists(out):
        shutil.rmtree(out)  # mlpackage 是目錄；覆寫前先清掉
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    mlmodel.save(out)

    print(f"完成：{out}")
    if val_acc is not None:
        print(f"（checkpoint val_pairwise_acc={float(val_acc):.4f}；"
              f"§4.8 門檻 0.85，未過閘的模型不得整合進 app）")


if __name__ == "__main__":
    main()
