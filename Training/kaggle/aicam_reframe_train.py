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


os.chdir("/kaggle/working")
if os.path.exists("aicam"):
    shutil.rmtree("aicam")
run(["git", "clone", "--depth", "1", "https://github.com/AriesHongHuanWu/aicam.git"])
os.chdir("aicam")

run([sys.executable, "Training/fetch_unsplash_lite.py", "--max", "8000"])
run([
    sys.executable, "Training/train.py",
    "--data", "Training/data/images",
    "--out", "/kaggle/working/checkpoints",
    "--epochs", "10",
    "--batch", "96",
    "--workers", "4",
])
run([
    sys.executable, "Training/eval.py",
    "--ckpt", "/kaggle/working/checkpoints/best.pt",
    "--data", "Training/data/images",
])

shutil.copy("Training/data/manifest.csv", "/kaggle/working/manifest.csv")
print("KAGGLE TRAIN DONE")
