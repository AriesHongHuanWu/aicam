# DATA-MANIFEST — 訓練資料來源與授權登記

> MASTER-PLAN §4.9 紅線：**上架 app 內的模型只准用可商用授權資料訓練**；
> AVA / GAICD / CADB 等 research-only 資料集**最多用於離線評測**，永不進
> shipped 模型。任何新資料源使用前必須先在本檔登記（來源、授權、用途、
> 是否進 shipped 模型），違反紅線的資料一律不准用。

## 登記表

| # | 來源 | 授權 | 用途 | 進 shipped 模型？ | 登記日 |
|---|------|------|------|-------------------|--------|
| 1 | Unsplash Research Dataset **Lite**（~25,000 張） | Unsplash Dataset 條款（Lite 版官方明示可商用；以官方條款原文為準） | ReframeNet 訓練 + held-out 評測 | ✅ 准 | 2026-07-22 |

（新增資料源時往下加列；research-only 的「進 shipped 模型？」一律填 ❌。）

## 來源 1：Unsplash Research Dataset Lite

- **取得**：<https://unsplash.com/data>（條款與文件：<https://github.com/unsplash/datasets>）
- **抓取方式**：`Training/fetch_unsplash_lite.py` 讀 zip 內 `photos.tsv000`，
  以 `photo_image_url` 下載 640px 縮圖（不 scrape 網站、不繞過 API）。

### 條款要點（摘要；以官方 TERMS 原文為準）

1. **Lite 版可商業使用**；Full 版（~4.8M 張）僅限非商業研究 —— 本專案**只用 Lite**。
2. 圖片本身受 Unsplash License 規範：可免費使用（含商業用途），但
   **不得用這批圖片建立與 Unsplash 競爭的圖庫/相片服務**。本專案用途 =
   訓練構圖評分模型（產物是 learned weights，非圖片集合），在條款範圍內。
3. **不重散佈資料集**：`Training/data/` 下的 zip 與圖片檔不 commit 進 repo、
   不打包進 app、不在 app 內展示資料集圖片。App 隨附的只有訓練出來的模型權重。

### Attribution 義務（§4.9）

- `Training/data/manifest.csv`（由 `fetch_unsplash_lite.py` 產生）記錄每張
  實際使用圖片的 `photo_id, url, photographer_username` —— 這是資料來源的
  完整 provenance 紀錄，**manifest.csv 要進 repo 保存**。
- Unsplash 要求在發表/發佈使用其資料集的成果時註明出處：對外文件（App Store
  說明、技術文章、開源 README）提及模型時，註明
  「構圖模型使用 Unsplash Dataset (Lite) 訓練」；需列攝影師名單時以
  manifest.csv 為準。

## 紅線重申（給未來 session）

- ❌ AVA、GAICD、CADB、FLMS、CPC 等學術構圖/美學資料集 = **research-only**：
  只准拿來做離線 benchmark 對照，**嚴禁**混進任何會隨 app 出貨的模型的
  訓練資料（含 fine-tune、蒸餾的 teacher 資料）。
- ❌ 未在本檔登記的資料一律不准餵進訓練。
- ✅ 可商用備選：Pexels（依其 License 自查後登記再用）。
- 換模型上線前必過 §4.8 評測（`Training/eval.py` gate 0.85 + 真機盲測），
  分數寫進 commit 訊息（MASTER-PLAN §16）。
