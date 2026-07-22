# Training — Reframe 構圖模型訓練管線

對應 **MASTER-PLAN §4.3（L2 學習構圖層）/ F31**。純 Python，在整合者本機
（Windows、RTX 5060 8GB、Python 3.12、torch 2.12）執行；CoreML 轉檔走
GitHub Actions（Windows 裝不了 coremltools，見下方〈CoreML 匯出〉）。

## 這條管線在學什麼

Weakly-supervised（免人工標註）：

- **正例** = 專業照片的**完整原始取景**（全帧視窗，不做 center crop —— v2 的
  center crop 會砍掉橫幅左右 1/3，構圖訊號根本進不了正例）。v4 起訓練 epoch
  改用近全帧微抖動視窗 scale U(0.95, 1.0)（消除 v3 恆定 pos 的逐張記憶錨點，
  與負例上限 0.90 保留間隙）；驗證/評測仍用乾淨全帧
- **負例** = 同一張圖內的**同長寬比**隨機視窗（scale U(0.55, 0.90)、位置均勻、
  **無旋轉**）—— 模擬「取景取偏了／太緊」；歪斜由 App 層 CoreMotion 規則負責
- 兩支走**完全相同**的 crop → squash resize（PIL BILINEAR）路徑：同插值、同
  重採樣次數。「正例縮得多（~2.9x）、負例縮得少（1.6~2.6x）」的縮放幅度差
  已做過對抗性審查：PIL resize 有抗鋸齒（輸出座標下濾波器固定），實測
  content-controlled AUC ≈ 0.5，判定不構成作弊通道 —— 但**不可**換成
  torch/cv2 的 naive bilinear，也**不可**換高解析資料源（細節與載重不變量
  見 `dataset.py` docstring）
- **免費監督訊號** = 擾動量本身：視窗中心相對圖中心的偏移 `(dx, dy)`（相對
  w、h 的比例）與 `dzoom = log(1/scale)`（neg ∈ (0.105, 0.598)；v4 起 pos/neg
  各回傳一支 delta，pos 的在 0 附近）
- **v4 對稱增強**（只在訓練 epoch 開）：光度（亮度/對比/飽和/偶爾灰階/偶爾輕
  模糊）與水平翻轉，**同一組參數同時套 pos 與 neg、在 resize 後輸出空間執行**；
  翻轉時兩支 delta 的 dx 同步取負。任何只套一支的增強都是作弊通道（已用
  內容受控 AUC 實測對稱性 ≈ 0.5，見 `dataset.py` docstring）

模型 `ReframeNet` = MobileNetV3-Small（ImageNet 預訓練）+ 共享 trunk + 兩顆頭：

- `score`：構圖分（pairwise ranking：原始取景 > 擾動視窗；數值無絕對意義，只用於排序/差值）
- `delta`：取景差量回歸 `(dx, dy, dzoom)` = **目前取景相對理想取景的偏移（誤差向量）**
  → App 端的修正指令 = **−delta**：dx > 0（框偏右）→ 相機往左移；
  dy > 0（框偏下）→ 取景抬高；dzoom > 0（取景比理想更緊）→ 退後或換廣角

損失（v4）= `softplus(-(score_pos - score_neg)).mean()`（BPR 型，不飽和）
　　 + `1.0 × SmoothL1(delta_neg_pred/D, delta_neg_gt/D)`
　　 + `0.3 × SmoothL1(delta_pos_pred/D, delta_pos_gt/D)`，`D = (0.225, 0.225, 0.598)`
　　（各維以標籤上限正規化；未正規化時 delta 項僅占總損失 ~2%，delta 頭學不動）

v4 其他抗過擬合手段（動機：v3 實測 val 0.63 / train loss 0.004 = 逐張過擬合）：
trunk Dropout(0.2)、AdamW weight_decay 0.01、backbone 學習率 0.1×（heads 全速）、
每 epoch 印 train pairwise acc 監控泛化差距。

## 檔案總覽

| 檔案 | 作用 |
|------|------|
| `fetch_unsplash_lite.py` | 下載 Unsplash Lite 資料集 zip → 平行抓 640px 縮圖 → 寫 `data/manifest.csv`（attribution） |
| `dataset.py` | `ReframePairDataset`：每張圖產 (正例, 負例, delta) 三元組；全程可設 seed 重現 |
| `model.py` | `ReframeNet`（MobileNetV3-Small backbone + score/delta 雙頭） |
| `train.py` | 訓練主程式；存 `checkpoints/best.pt`（val acc 最高）與 `last.pt` |
| `eval.py` | §4.8 離線評測閘門：重現 val 切分 → pairwise accuracy → GATE PASS/FAIL |
| `export_coreml.py` | `best.pt` → `ReframeModel.mlpackage`（mlprogram、FP16；只能在 macOS/Linux/CI 跑） |
| `DATA-MANIFEST.md` | 資料來源與授權登記（§4.9 紅線）— 新增任何資料源前必讀必登記 |
| `.github/workflows/model-export.yml` | CI 轉檔 workflow（workflow_dispatch 手動觸發） |

## 環境需求

- Python 3.10+（整合者本機 = 3.12）；**依賴只有 torch、torchvision、Pillow、numpy**
  （其餘全是標準庫；刻意不用 requests/pandas/tqdm）
- GPU 訓練需 CUDA 版 torch（照 pytorch.org 對應你 CUDA 版本的指令安裝）；
  無 GPU 會自動退 CPU 並警告（非常慢，只適合 smoke）
- **所有指令一律從 repo 根目錄執行**（路徑都是相對 repo 根）

## Smoke run（先跑通，約 10–20 分鐘）

```bash
# 1) 抓 300 張（zip 若已在本地：加 --zip Training/data/unsplash-lite.zip）
python Training/fetch_unsplash_lite.py --max 300

# 2) 短訓練（CPU 也跑得動的規模）
python Training/train.py --data Training/data/images --epochs 2 --batch 32

# 3) 評測閘門（smoke 的 acc 沒有參考價值，只確認流程通）
python Training/eval.py --data Training/data/images
```

## 全量 run（RTX 5060 8GB）

```bash
# 1) 抓 5000 張（可中斷續傳；再跑一次會跳過已下載的）
python Training/fetch_unsplash_lite.py

# 2) 全量訓練（預設 --epochs 8 --batch 64 --lr 3e-4 --seed 42）
#    8GB VRAM 跑 batch 64 @ 224px 綽綽有餘；OOM 就 --batch 32
python Training/train.py --data Training/data/images

# 3) 正式評測
python Training/eval.py --data Training/data/images
```

想加大資料量：`python Training/fetch_unsplash_lite.py --max 20000`（Lite 共 25k 張）。

## §4.8 評測門檻（不達標不上線）

`eval.py` 執行 §4.8 第 1 關：**held-out val 切分上 pairwise accuracy ≥ 0.85** ——
即模型把「專業原始取景」排在「擾動視窗」前面的比例。輸出
`GATE PASS / GATE FAIL（門檻 0.85）`；exit code PASS=0、FAIL=1。

- 可重現性：`eval.py` 從 checkpoint 內存的 `args` 讀回訓練時的 `seed` 與
  `val_frac`，用與 `train.py` 完全相同的 `split_sizes` 公式 +
  `torch.Generator(seed)` 重現同一 val 集；負例視窗固定 `epoch=0` 生成。
  **前提：`--data` 目錄內容要與訓練時一致**（檔案增減會改變切分）。
- §4.8 第 2、3 關（真機 50 張盲測命中 ≥7/10、blend vs 純規則 ablation）是
  人工流程，不在本腳本範圍。
- MASTER-PLAN §16：換模型必須把評測分數寫進 commit 訊息。

## CoreML 匯出（Windows 走 CI）

coremltools 不支援 Windows。流程：

1. `Training/checkpoints/best.pt` commit + push 進 repo（MobileNetV3-Small
   checkpoint 約 10–20MB，可直接進 git）
2. GitHub → **Actions → model-export → Run workflow**
3. 跑完到該 run 的 **Artifacts** 下載：解壓 artifact 得到
   `ReframeModel.mlpackage.zip`，再解壓一次得到**完整的
   `ReframeModel.mlpackage/` 資料夾**（mlpackage 必須是帶 `.mlpackage`
   副檔名的整個資料夾才有效，勿散放內容物）
   → 之後由 P5 整合階段放進 `Assets/` 接上 App

模型介面（Swift 端）：輸入 `image` = 224×224 RGB（ImageType，**正規化已烘進
模型**，餵原始像素即可）；輸出 `score`（排序用純量）與 `delta`（`(dx, dy, dzoom)`，
座標語意同 `dataset.py`：x 向右、y 向下、相對整張圖的比例；dzoom 為 log 比例）。

**方向鐵則**：`delta` 是「目前取景 − 理想取景」的誤差向量，App 端要下的修正指令
= **−delta**（dx > 0 → 往左移、dy > 0 → 取景抬高、dzoom > 0 → 退後／換廣角）。
照著 delta 原方向下指令會恰好反向。

**dzoom 限制**：訓練負例永遠是「比整張照片更緊的視窗」，dzoom 標籤恆 ≥ 0 —
模型從未看過「取景太鬆」的例子，**不會產生可靠的負 dzoom**。App 端只在
dzoom 大於門檻時當作「退後／換廣角」訊號；小值或負值一律忽略，
**絕不解讀成「上前／換長焦」**。

## 疑難排解

- **DataLoader 在 Windows 卡住/報 spawn 錯**：加 `--workers 0`。
- **下載大量 fail**：Unsplash 圖床偶發限流；重跑同指令即可續傳（已存在的會跳過）。
- **Lite zip 連結 404**：官方連結更換時去 <https://unsplash.com/data> 拿新連結，
  下載後用 `--zip 路徑` 指定本地檔。
- **CUDA OOM**：`--batch 32`（或 16）。

## 資料授權

見 `Training/DATA-MANIFEST.md`（§4.9 紅線：shipped 模型只准可商用資料；
research-only 資料集只准離線評測）。`Training/data/`（zip 與圖片）**不要 commit 進
repo** —— 重佈 Unsplash 圖片不在授權範圍內，manifest.csv 才是要留的紀錄。
