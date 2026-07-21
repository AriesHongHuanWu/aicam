#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fetch_unsplash_lite.py — 下載 Unsplash Research Dataset Lite 並抓取訓練圖片。

用法（一律從 repo 根目錄執行）：
    python Training/fetch_unsplash_lite.py                  # 下載 zip + 抓 5000 張
    python Training/fetch_unsplash_lite.py --max 300        # smoke run
    python Training/fetch_unsplash_lite.py --zip path/to/unsplash-lite.zip   # 用已下載的 zip

流程：
 1. 下載 Lite zip（或用 --zip 指定的本地檔跳過下載）。
 2. 從 zip 內的 photos.tsv000（TSV）讀出 photo_id / photo_image_url / photographer_username。
 3. ThreadPoolExecutor(8) 平行下載前 --max 張縮圖（URL 加 w=640&q=80）到 --out。
    已存在的檔案直接跳過（可中斷續傳）；單檔失敗只記錄不中斷；每 200 張印一次進度。
 4. 寫 manifest（photo_id,url,photographer_username）供 MASTER-PLAN §4.9 attribution。

依賴：只用 Python 標準庫（urllib / zipfile / csv / concurrent.futures / argparse）。
"""

from __future__ import annotations

import argparse
import csv
import io
import os
import sys
import time
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib import error as urlerror
from urllib import request as urlrequest

DATASET_URL = (
    "https://unsplash-datasets.s3.amazonaws.com/lite/latest/"
    "unsplash-research-dataset-lite-latest.zip"
)
DATA_PAGE = "https://unsplash.com/data"
USER_AGENT = "AICam-Training/1.0 (python-urllib; research pipeline)"
TSV_NAME = "photos.tsv000"
DEFAULT_ZIP = os.path.join("Training", "data", "unsplash-research-dataset-lite-latest.zip")
DEFAULT_OUT = os.path.join("Training", "data", "images")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="下載 Unsplash Lite 資料集圖片（Reframe 訓練用）")
    p.add_argument("--zip", default=None,
                   help="已下載好的 dataset zip 路徑（提供則跳過下載）")
    p.add_argument("--max", type=int, default=5000, help="最多下載幾張圖（預設 5000）")
    p.add_argument("--out", default=DEFAULT_OUT,
                   help=f"圖片輸出目錄（預設 {DEFAULT_OUT}）")
    p.add_argument("--manifest", default=None,
                   help="manifest.csv 輸出路徑（預設 = --out 的上一層/manifest.csv，"
                        "即 Training/data/manifest.csv）")
    p.add_argument("--timeout", type=int, default=30, help="單張圖 HTTP timeout 秒數")
    return p.parse_args()


def download_dataset_zip(dest: str, timeout: int) -> str:
    """下載 Lite zip 到 dest（已存在就沿用）。404 時提示去官網拿新連結。"""
    if os.path.isfile(dest) and os.path.getsize(dest) > 0:
        print(f"[zip] 已存在，跳過下載：{dest}")
        return dest
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    part = dest + ".part"
    print(f"[zip] 下載中：{DATASET_URL}")
    req = urlrequest.Request(DATASET_URL, headers={"User-Agent": USER_AGENT})
    try:
        with urlrequest.urlopen(req, timeout=timeout) as resp, open(part, "wb") as fh:
            total = resp.headers.get("Content-Length")
            total = int(total) if total else None
            done = 0
            last_report = 0
            while True:
                chunk = resp.read(1024 * 1024)
                if not chunk:
                    break
                fh.write(chunk)
                done += len(chunk)
                if done - last_report >= 50 * 1024 * 1024:  # 每 50MB 報一次
                    last_report = done
                    if total:
                        print(f"[zip]   {done / 1e6:.0f} / {total / 1e6:.0f} MB")
                    else:
                        print(f"[zip]   {done / 1e6:.0f} MB")
    except urlerror.HTTPError as exc:
        if os.path.isfile(part):
            os.remove(part)
        if exc.code == 404:
            print(
                "[zip] 404：官方連結可能已更換。\n"
                f"      請到 {DATA_PAGE} 取得最新 Lite 下載連結，"
                "下載後用 --zip 指定本地檔再跑一次。",
                file=sys.stderr,
            )
        else:
            print(f"[zip] HTTP {exc.code}：{exc.reason}", file=sys.stderr)
        sys.exit(1)
    except urlerror.URLError as exc:
        if os.path.isfile(part):
            os.remove(part)
        print(f"[zip] 下載失敗：{exc}。可自行下載後用 --zip 指定本地檔。", file=sys.stderr)
        sys.exit(1)
    os.replace(part, dest)
    print(f"[zip] 完成：{dest}（{os.path.getsize(dest) / 1e6:.0f} MB）")
    return dest


def read_photo_rows(zip_path: str, limit: int) -> list[dict]:
    """從 zip 內的 photos.tsv000 讀前 limit 筆 (photo_id, url, photographer_username)。"""
    rows: list[dict] = []
    with zipfile.ZipFile(zip_path) as zf:
        member = None
        for name in zf.namelist():
            if os.path.basename(name) == TSV_NAME:
                member = name
                break
        if member is None:
            print(f"[tsv] zip 內找不到 {TSV_NAME}；zip 內容：{zf.namelist()[:10]} ...",
                  file=sys.stderr)
            sys.exit(1)
        with zf.open(member) as raw:
            text = io.TextIOWrapper(raw, encoding="utf-8", newline="")
            reader = csv.DictReader(text, delimiter="\t")
            for row in reader:
                photo_id = (row.get("photo_id") or "").strip()
                url = (row.get("photo_image_url") or "").strip()
                if not photo_id or not url:
                    continue
                rows.append({
                    "photo_id": photo_id,
                    "url": url,
                    "photographer_username": (row.get("photographer_username") or "").strip(),
                })
                if len(rows) >= limit:
                    break
    print(f"[tsv] 取得 {len(rows)} 筆照片資料")
    return rows


def thumb_url(url: str) -> str:
    """加上縮圖參數（已含 ? 就用 & 接）。"""
    sep = "&" if "?" in url else "?"
    return f"{url}{sep}w=640&q=80"


def download_one(row: dict, out_dir: str, timeout: int) -> tuple[str, dict, str]:
    """回傳 (status, row, message)；status ∈ {ok, skip, fail}。"""
    dest = os.path.join(out_dir, row["photo_id"] + ".jpg")
    if os.path.isfile(dest) and os.path.getsize(dest) > 0:
        return ("skip", row, "")
    url = thumb_url(row["url"])
    last_err = ""
    for attempt in range(2):  # 每張最多試 2 次
        try:
            req = urlrequest.Request(url, headers={"User-Agent": USER_AGENT})
            with urlrequest.urlopen(req, timeout=timeout) as resp:
                data = resp.read()
            if len(data) < 512:
                raise ValueError(f"回應過小（{len(data)} bytes）")
            part = dest + ".part"
            with open(part, "wb") as fh:
                fh.write(data)
            os.replace(part, dest)
            return ("ok", row, "")
        except Exception as exc:  # noqa: BLE001 — 單檔失敗記錄後續跑
            last_err = str(exc)
            if attempt == 0:
                time.sleep(1.0)
    return ("fail", row, last_err)


def main() -> None:
    args = parse_args()
    out_dir = args.out
    os.makedirs(out_dir, exist_ok=True)

    if args.zip:
        zip_path = args.zip
        if not os.path.isfile(zip_path):
            print(f"[zip] 找不到 --zip 指定的檔案：{zip_path}", file=sys.stderr)
            sys.exit(1)
        print(f"[zip] 使用本地 zip：{zip_path}")
    else:
        zip_path = download_dataset_zip(DEFAULT_ZIP, timeout=args.timeout)

    rows = read_photo_rows(zip_path, args.max)
    if not rows:
        print("[tsv] 沒有可下載的照片列", file=sys.stderr)
        sys.exit(1)

    ok = skip = fail = done = 0
    succeeded: list[dict] = []
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(download_one, row, out_dir, args.timeout) for row in rows]
        for fut in as_completed(futures):
            status, row, msg = fut.result()
            done += 1
            if status == "ok":
                ok += 1
                succeeded.append(row)
            elif status == "skip":
                skip += 1
                succeeded.append(row)
            else:
                fail += 1
                print(f"[fail] {row['photo_id']}: {msg}")
            if done % 200 == 0 or done == len(rows):
                print(f"[進度] {done}/{len(rows)}  新下載={ok}  已存在={skip}  失敗={fail}")

    # manifest（只記錄實際存在於磁碟上的圖；url 記原始 photo_image_url 供 attribution）
    manifest_path = args.manifest
    if manifest_path is None:
        parent = os.path.dirname(os.path.normpath(out_dir))
        manifest_path = os.path.join(parent or ".", "manifest.csv")
    os.makedirs(os.path.dirname(manifest_path) or ".", exist_ok=True)
    succeeded.sort(key=lambda r: r["photo_id"])
    with open(manifest_path, "w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["photo_id", "url", "photographer_username"])
        for row in succeeded:
            writer.writerow([row["photo_id"], row["url"], row["photographer_username"]])
    print(f"[manifest] 寫入 {len(succeeded)} 筆 → {manifest_path}")
    print(f"[完成] 新下載={ok} 已存在={skip} 失敗={fail}；圖片目錄：{out_dir}")


if __name__ == "__main__":
    main()
