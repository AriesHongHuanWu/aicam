"""AICam Reframe 模型 — Kaggle GPU 訓練入口（MASTER-PLAN §4.3）。

流程：clone 公開 repo → 抓 Unsplash Lite 圖片 → train → eval（§4.8 門檻）
→ checkpoints 與 attribution manifest 留在 /kaggle/working 供下載。
本機（Windows）以 `kaggle kernels push -p Training/kaggle` 發射。
"""
import os
import shutil
import subprocess
import sys


def run(cmd):
    print(">>", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def gpu_preflight():
    """先跑一個真的 CUDA 卷積再開工 — P100(sm_60) 與新版 torch wheel 不相容，
    metadata 已指定 NvidiaTeslaT4；萬一還是分到不相容 GPU，這裡秒退而不是
    下載 8000 張圖之後才在 train 裡炸。"""
    import torch
    if not torch.cuda.is_available():
        raise SystemExit("PREFLIGHT FAIL: no CUDA device")
    name = torch.cuda.get_device_name(0)
    try:
        x = torch.randn(1, 3, 32, 32, device="cuda")
        w = torch.randn(8, 3, 3, 3, device="cuda")
        torch.nn.functional.conv2d(x, w).sum().item()
    except Exception as e:
        raise SystemExit(f"PREFLIGHT FAIL: GPU {name} incompatible with this torch build: {e}")
    print(f"PREFLIGHT OK: {name}", flush=True)


gpu_preflight()
os.chdir("/kaggle/working")
if os.path.exists("aicam"):
    shutil.rmtree("aicam")
run(["git", "clone", "--depth", "1", "https://github.com/AriesHongHuanWu/aicam.git"])
os.chdir("aicam")

run([sys.executable, "Training/fetch_unsplash_lite.py", "--max", "24000"])
run([
    sys.executable, "Training/train.py",
    "--data", "Training/data/images",
    "--out", "/kaggle/working/checkpoints",
    "--epochs", "12",
    "--batch", "96",
    "--workers", "4",
    "--freeze-backbone",
    "--cross-pair-w", "0.5",
])
run([
    sys.executable, "Training/eval.py",
    "--ckpt", "/kaggle/working/checkpoints/best.pt",
    "--data", "Training/data/images",
])

shutil.copy("Training/data/manifest.csv", "/kaggle/working/manifest.csv")
print("KAGGLE TRAIN DONE")
