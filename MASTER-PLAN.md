# AICam — MASTER PLAN（接手前必讀）

**Repo**: `github.com/AriesHongHuanWu/aicam` ・ **平台**: iPhone 原生（iOS 17+，iOS 18 API 以 `#available` 包）
**產品一句話**: 對標「哆咔（Doka）相機」的 AI 攝影教練 — 即時告訴你站哪裡、怎麼構圖、AI 代調參數、自動抓拍最佳瞬間、拍完自動篩選，外加完整專業手動控制 + RAW。
**北極星指標**: 「每次幫女朋友拍照，她都滿意」— 教練建議命中率與出片率優先於一切花俏功能。
**UI 方向**: 純黑白、有質感、功能齊全但介面不複雜（§9）。
**目標**: 未來可上架 App Store（§13）。

> **狀態（2026-07-21）**: 規劃完成，程式碼 0 行。本文件由 Fable 制定，之後由 Opus session 依 §10 路線圖從 P0 開始逐階段執行。執行者動工前必須讀完本檔。

---

## 1. 硬性決策（已定案，不要重開討論）

| # | 決策 | 理由 |
|---|------|------|
| D1 | **原生 Swift + SwiftUI**，不用 React Native/Expo | RAW、逐帧 AI 分析、手動曝光、Metal 濾鏡預覽全都要貼著 AVFoundation/Metal 寫，RN 每一層都是阻力 |
| D2 | **禁用 ARKit** | ARSession 會接管相機，無法與全手動 AVCaptureSession 並存。「3D 指導」改用 CoreMotion 姿態 + Vision 3D 人體 + LiDAR 深度合成（§5），效果足夠且不犧牲專業控制 |
| D3 | **即時 AI 100% on-device** | 及時性（<100ms 反應）與隱私；雲端（Gemini）只做 P5 的低頻進階建議，不在關鍵路徑上 |
| D4 | **雙層架構：`AICamCore`（純 Swift SPM 套件，無 UIKit）+ `App`（iOS shell）** | 開發機是 Windows、沒有 Xcode → 構圖評分、篩選排序、LUT 解析等純邏輯放 Core，**ubuntu CI 就能 `swift test`**；相機/UI 層只能靠 macOS CI 編譯驗證 |
| D5 | **Session 制儲存** | 拍攝先存 app 沙盒（Session），AI 篩選後一鍵匯出相簿（`addOnly` 權限即可，不需 readWrite）；另提供「即拍即存」開關直存相簿。避免 RAW 大量佔相簿 + 篩選不用要相簿讀取權 |
| D6 | **UI 純黑白** | §9 tokens。不引入彩色 accent；狀態靠白階/閃爍/haptics 表達 |
| D7 | **CI = 編譯器** | 所有編譯在 GitHub Actions；macos runner 產 unsigned IPA 側載測試（同 Hoopilot 既有流程），上架階段才加簽名/TestFlight |
| D8 | **一般/教練模式用 virtual camera（自動切鏡+平滑 zoom）；專業/RAW 模式強制選 physical 鏡頭** | Bayer RAW 只在 physical device 提供；這也是 Halide 的做法 |
| D9 | 不引入第三方大依賴 | 相機、UI、AI 全用系統框架（AVFoundation/Vision/CoreML/CoreImage/Metal/Photos/CoreMotion）。要加依賴需在 commit 訊息說明理由 |

---

## 2. 總功能表（每個功能 × 怎麼實現）

即時性欄：`每帧`=~30fps、`10fps`、`2s`=每 1–2 秒、`拍後`=非即時。難度 1–5。

| # | 功能 | 關鍵實作（API / 模型 / 演算法） | 即時性 | 難度 | 階段 |
|---|------|--------------------------------|--------|------|------|
| F1 | 即時構圖評分（快門外圈 0–100 分數環） | `AVCaptureVideoDataOutput` 取帧 → Vision 特徵 → `CompositionEngine` 規則加權評分（§4） | 10fps | 4 | P2 |
| F2 | 即時指導（「退後兩步」「蹲低一點」，一次只顯示一條） | 評分成分中最扣分項 → 建議語料表（繁中 ≤10 字）+ 方向箭頭向量 | 10fps | 3 | P2 |
| F3 | 3D 走位指導 overlay（目標框 + 3D 箭頭） | CoreMotion attitude + `VNDetectHumanBodyPose3DRequest` + LiDAR 深度 → 推算建議機位 → SwiftUI Canvas 投影繪製（§5） | 2s | 5 | P2 |
| F4 | 主體識別（人優先；物品/食物/風景 fallback） | `VNDetectFaceRectanglesRequest` + `VNDetectHumanBodyPoseRequest`；無人時 `VNGenerateAttentionBasedSaliencyImageRequest` 取 saliency bbox | 10fps | 3 | P2 |
| F5 | 切邊/切關節/爆頭頂警告 | body pose 關節點距畫面邊緣 < 閾值 → 警告（膝/腳踝/手腕優先）；headroom 比例檢查 | 10fps | 2 | P2 |
| F6 | 光位判斷（順/逆/側光）+ 補光走位建議 | 臉部 bbox 內亮度 vs 全帧直方圖 + 臉左右半亮度差 → 逆光/側光判定 →「請她轉向光 45°」/ AI 自動 EV 補償 | 2s | 3 | P2 |
| F7 | 水平儀 + 歪斜提醒 | `CMMotionManager` gravity（常駐，<1ms）；風景輔以 `VNDetectHorizonRequest` | 每帧 | 1 | P1 |
| F8 | 鏡頭焦段建議（人像建議 2x/3x 壓縮） | 主體距離（深度/pose 估）+ 主體占比 → 規則：半身/特寫距離 <1.5m 建議退後改長焦 | 2s | 2 | P2 |
| F9 | AI 抓拍（睜眼+微笑+手穩+高分 → 自動連拍 3 張） | EAR 睜眼（landmarks）、嘴形微笑、gyro 穩定度、F1 分數 ≥85 全滿足觸發；可關 | 10fps | 3 | P2 |
| F10 | 姿勢卡（pose 剪影疊圖庫） | 內建 JSON+SVG 剪影庫（站/坐/走/回眸…依場景推薦），半透明疊在取景器 | 靜態 | 2 | P5 |
| F11 | 即時 LUT 調色預覽（黑白 6 款 + 彩色 6 款） | `.cube` 解析器（Core）→ `CIColorCube` 33³ → `MTKView`+`CIContext` 濾鏡預覽管線（§6） | 每帧 | 4 | P3 |
| F12 | 場景→調色推薦 top-3 | `VNClassifyImageRequest` 場景標籤 + 直方圖統計 → 規則表（逆光人像→柔膚曲線；夜景→…） | 2s | 2 | P3 |
| F13 | 拍後一鍵 AutoEnhance（膚色保護） | CIFilter chain：曝光/對比 curve、WB、HSL 微調；臉部 mask 保護膚色；強度滑桿 | 拍後 | 3 | P3 |
| F14 | RAW 顯影預設 | `CIRAWFilter`（exposure/temp/tint/localToneMap…）預設檔套用 + 微調 | 拍後 | 3 | P3 |
| F15 | AI 篩選：糊/閉眼/重複自動 reject，精選 top-n | sharpness（Laplacian 變異）+ `VNDetectFaceCaptureQualityRequest` + EAR + 曝光剪裁 + 美學分（iOS18 `CalculateImageAestheticsScoresRequest`；iOS17 fallback NIMA CoreML 或組合分）→ 綜合排序（§7） | 拍後 | 4 | P4 |
| F16 | 相似連拍聚類（每組只留最佳） | `VNGenerateImageFeaturePrintRequest` 特徵距離 < 閾值聚類 | 拍後 | 3 | P4 |
| F17 | Session 回顧 + 一鍵存相簿 | 沙盒 Session 目錄 + SQLite 索引；`PHAssetCreationRequest`（addOnly）匯出；rejects 進站內垃圾桶 7 天自動清 | 拍後 | 2 | P4 |
| F18 | 手動 ISO / 快門 / EV / WB / 對焦 | `setExposureModeCustom(duration:iso:)`、`setExposureTargetBias`、WB 溫度/色調 ↔ `deviceWhiteBalanceGains` 轉換、`setFocusModeLocked(lensPosition:)`；範圍讀 `activeFormat` | 即時 | 3 | P1 |
| F19 | 峰值對焦 / 斑馬紋 / 直方圖 | Sobel 邊緣（Metal fragment）疊白線；亮度 >98% 斑馬；`vImageHistogramCalculation` | 每帧 | 4 | P1 |
| F20 | RAW（Bayer DNG）+ ProRAW | `AVCapturePhotoOutput` `availableRawPhotoPixelFormatTypes`；ProRAW 限 Pro 機型（`isAppleProRAWSupported` gate）；HEIF+DNG 配對存（alternate resource） | 拍照 | 4 | P1 |
| F21 | 多鏡頭矩陣 + per-機型焦段自適應 | `AVCaptureDevice.DiscoverySession` 列舉 constituentDevices → 自動生成該機型焦段列（0.5/1/2*/3/5x；*2x=主鏡裁切）；smooth zoom ramp | 即時 | 3 | P0–P1 |
| F22 | 零快門延遲 + 連拍 + 音量鍵快門 + haptics | iOS17 `isZeroShutterLagEnabled`/`isResponsiveCaptureEnabled`；`AVCaptureEventInteraction`（iOS 17.2）接音量鍵 | 拍照 | 2 | P1 |
| F23 | AI Auto-Pro（AI 直接代調參數） | CoachEngine 寫入 EV/WB/最低快門（防動態糊）→ toast「AI：EV −0.7（逆光保臉）」+ 一鍵還原；全手動模式 AI 只建議不動手 | 2s | 3 | P2 |
| F24 | 前鏡自拍教練 | front TrueDepth path（mirror 座標處理）；教練規則沿用；前鏡無 RAW（gate） | 10fps | 2 | P2 |
| F25 | 低光偵測（提示拿穩/建議夜景） | 以 ISO×快門 推 lux 級別 → 提示 + AI 拉快門下限 | 2s | 1 | P2 |
| F26 | 黑白質感 UI + 分數環快門 | §9 design tokens；SwiftUI；動效 ≤200ms | — | 3 | P0 起貫穿 |
| F27 | 設定中心（格式/網格/聲音/抓拍/即拍即存/LUT 管理） | 設定抽屜 + `@AppStorage`；每項功能都有開關 = 「功能齊全但不複雜」的關鍵 | — | 2 | P1 |
| F28 | 雲端場景建議（Gemini） | 取景帧 downscale → Gemini Flash 場景級建議（3–5s 節流、教練閒置才呼叫）；**經 Cloudflare Worker proxy，不內嵌 key**（上架合規） | 5s | 3 | P5 |
| F29 | 上架配套 | 隱私清單、權限文案、App icon、截圖、TestFlight（§13） | — | 2 | P5 |
| F30 | 效能守護（熱降級） | `ProcessInfo.thermalState` 監聽 → 降 Tier（§3）；教練模式 CPU 預算 <40% | 常駐 | 3 | P2 |

---

## 3. 即時 AI 管線（架構核心）

```
AVCaptureSession
 ├─ AVCapturePhotoOutput（拍照：HEIF/DNG，零快門延遲）
 ├─ AVCaptureVideoDataOutput（30fps BGRA，alwaysDiscardsLateVideoFrames=true）
 │     └→ FrameAnalyzer（背景 serial queue，分析前 downscale 到長邊 640）
 │            Tier A（每帧，<5ms）   ：CoreMotion 水平、直方圖/曝光剪裁、穩定度
 │            Tier B（~10fps，<40ms）：臉 bbox+landmarks、2D body pose、saliency、主體追蹤
 │            Tier C（~0.5–1fps）    ：3D body pose、場景分類、光位判定、LUT 推薦、3D 走位計算
 │     └→ CoachState（@Observable struct，最新結果快照）
 └─ AVCaptureDepthDataOutput（LiDAR/dual 有才開，供距離估算）

SwiftUI overlay 以 60fps 讀 CoachState 繪製（分數環、箭頭、警告）— 渲染與分析完全解耦。
```

規則：
- 所有 Vision request 重用、同一 handler 批次執行；分析永不阻塞 preview 或快門。
- 熱降級表：`thermalState == .serious` → Tier B 降 5fps、關 3D pose；`.critical` → 只留 Tier A + 提示。
- Preview：P0–P2 用 `AVCaptureVideoPreviewLayer`（零成本）；P3 起換 `MetalPreviewView`（MTKView+CIContext 套 LUT）。**P0 就要用 protocol `PreviewRenderer` 包住這個 swap 點**，避免 P3 重構。

---

## 4. 構圖引擎規格（`AICamCore/CompositionEngine`，純 Swift 可單測）

輸入（每次評分的事實快照）：
```swift
struct FrameFacts {
  var faces: [FaceFact]          // bbox、landmarks、左右亮度、EAR、笑
  var bodyJoints: [Joint]?       // 2D pose
  var subjectBox: CGRect?        // 主體（人優先，否則 saliency）
  var horizonRollDeg: Double     // CoreMotion
  var pitchDeg: Double
  var subjectDistanceM: Double?  // 深度或 pose 身高先驗估
  var histogram: LumaHistogram
  var sceneTags: [String]
}
```

評分成分（權重存 `ScoringConfig.json`，可調不改碼）：

| 成分 | 權重 | 規則摘要 |
|------|------|----------|
| 三分線對齊 | 20 | 主體中心/眼線貼近三分點；置中構圖在對稱場景（sceneTags）不扣 |
| 頭部空間 headroom | 15 | 臉頂到畫面頂 5–12% 為佳；過多/貼邊扣分 |
| 主體占比 | 15 | 依子模式（全身/半身/特寫，由 bbox 比例自動判定）各有理想區間 |
| 水平 | 10 | \|roll\| < 1.5° 滿分，>4° 重扣 |
| 切邊/切關節 | −25 | 膝/踝/腕關節落在邊緣 3% 內 = 重扣（寧可切大腿不切膝） |
| 視線空間 | 10 | 臉朝向側留白 |
| 光位 | 15 | 順/側光加分；逆光扣分（除非 AI 已補償→不扣，改建議） |
| 背景干擾 | −10 | P3 選配：頭部區域 saliency/邊緣密度過高（頭上長桿） |

輸出：`score: Int(0–100)` + **top-1 建議**（只顯示最扣分項的修正指令，佇列輪播，避免介面吵）+ 箭頭向量 + 抓拍旗標。

建議語料表：繁體中文、≤10 字、動作可執行。例：「退後兩步」「蹲低，從腰部高度拍」「鏡頭抬高一點」「請她往光的方向轉 45°」「拉直水平」「往左移，讓她站在右三分線」。

抓拍（F9）觸發：`score≥85 && eyesOpen && smiling && gyroStable && faceSharp` → 靜音連拍 3 張標記進 Session。

---

## 5. 「3D 指導」設計（誠實邊界）

**能做到**：方向 + 量級的走位指示（左/右/前/後/蹲低/舉高 + 估計步數）、螢幕上投影 3D 箭頭與「目標取景框」，跟著裝置姿態即時旋轉。
**不做**：cm 級 SLAM 定位（D2 禁 ARKit）。UI 文案不得暗示絕對精度。

合成方式：
1. `CMMotionManager` → 相機當前 attitude（roll/pitch/yaw）。
2. `VNDetectHumanBodyPose3DRequest`（iOS17，Tier C）→ 主體相對相機的 3D 位置與身高；LiDAR 機型用 `AVCaptureDepthDataOutput` 精化距離，無 LiDAR 用身高先驗（1.6m）反推。
3. CompositionEngine 給出理想機位差量（Δ高度、Δ距離、Δ方位角）。
4. 疊加層：SwiftUI `Canvas` 手算透視投影畫 3D 箭頭 + 半透明目標框（不需 SceneKit；黑白線框風格正好貼合 UI）。
5. 高度指導：臉部 pitch + 相機 pitch 推「相機高/低於眼線」→「蹲低一點」（女友照鐵則：略低於眼線顯腿長，全身照從腰部高度拍）。

---

## 6. AI 調色規格

- **LUT 引擎**（Core，可單測）：`.cube` 解析 → 33³ float 表 → `CIColorCube(WithColorSpace)`。內建 12 款**自製**曲線生成 LUT（黑白系：Noir/Silver/Fade/HighKey/Grain/Street；彩色系：Portrait Soft/Teal-Orange/Film Warm/Clean/Night/Food）。不抄名牌 LUT，自己命名。
- **即時預覽**：`MetalPreviewView`（MTKView + CIContext）對預覽帧套 LUT，60fps；拍照時同一 LUT 烘進 HEIF、RAW 永遠存原始。
- **推薦**（F12）：Tier C 場景標籤 + 直方圖 → 規則表推 top-3，UI 上一排三個縮圖點按即換。
- **拍後 AutoEnhance**（F13）：曝光/對比 S-curve → WB → HSL 微調 → 臉部 mask 膚色保護（色相鎖定 ±8°）→ 強度滑桿 0–100%。
- **RAW 顯影**（F14）：`CIRAWFilter` 參數預設檔（每款 LUT 附對應 RAW 顯影參數）。
- P3 選配進階：小型 CoreML 模型**預測調色參數**（不預測像素，體積小、可解釋、好除錯）。

---

## 7. AI 篩選（Culling）規格

- **Session 模型**：一次拍攝 = 一個 Session（沙盒目錄 + SQLite 索引：檔名、時間、分數、狀態）。
- **每張分數**：sharpness（Laplacian 變異，luma 1024px 縮圖上算）、`VNDetectFaceCaptureQualityRequest`（Apple 專為選片設計）、睜眼 EAR、微笑、曝光剪裁比例、美學分（iOS18 `CalculateImageAestheticsScoresRequest`；iOS17 fallback：NIMA CoreML（MobileNetV2 backbone，Apache 授權轉檔）或退回組合分）。
- **聚類**：`VNGenerateImageFeaturePrintRequest` `computeDistance` < 閾值 → 同組（連拍/重複），每組選最佳，其餘標「相似」。
- **UI**：進「回顧」→ 自動標好「精選 n 張 / 相似 m 張 / 建議捨棄 k 張」；swipe keep/reject 覆核；「存入相簿」一鍵匯出精選（addOnly）；rejects 進垃圾桶 7 天。
- **效能目標**：100 張（含 RAW 配對）< 30 秒，背景批次、可中斷續跑。

---

## 8. 相機控制矩陣

- **探索**：啟動時 `DiscoverySession`（builtInTripleCamera / DualWide / Wide + front TrueDepth）→ 生成本機焦段表（如 15PM: 0.5/1/2/5x；15: 0.5/1/2x）→ UI 鏡頭列自動適配（F21，回答「不同手機不同焦距」）。
- **手動參數**（F18）全走 `AVCaptureDevice` lock 寫入，範圍讀 `activeFormat`（minISO/maxISO、min/maxExposureDuration）；WB 提供 K 溫度 + tint 雙滑桿（gains 換算）。
- **監看**（F19）：直方圖（vImage）、斑馬紋（Metal >98% luma）、峰值對焦（Sobel 白邊）、水平儀 — 各自可開關。
- **快門**（F22）：零延遲 + responsive capture、長按連拍、音量鍵（`AVCaptureEventInteraction`）、haptic 三段（半按對焦模擬/擊發/抓拍）。
- **RAW**（F20）：格式選單 HEIF / HEIF+DNG / ProRAW（機型 gate）；DNG 與 HEIF 以 `PHAssetCreationRequest` alternate resource 配對存；容量警示條。
- **AI 代操**（F23）：教練/拍照模式下 AI 可直接調 EV、WB、最低快門；每次調整顯示 toast + 撤銷；專業模式 AI 降為建議 chip（點了才套用）。

---

## 9. UI 規格（黑白質感、克制）

Design tokens（`App/Sources/DesignSystem/Tokens.swift`）：
- 色：`bg #000000`、`fg #FFFFFF`、`gray1 #EBEBF0`、`gray2 #8E8E93`、`gray3 #3A3A3C`、hairline `#FFFFFF` 20% 0.5pt。無彩色 accent。
- 字：SF Pro（介面）+ SF Mono（參數數字）；圓角 2pt（方正硬朗）；動效 150–200ms ease-out；全程 haptics。
- 取景器全幅置中；**上緣**一條狀態列（格式/RAW/閃燈/教練開關）；**下緣**：相簿縮圖｜快門（外圈=構圖分數環，分數以環白量呈現）｜鏡頭焦段列。
- **模式只有 4 個**（左右滑切換）：`拍照`（乾淨，AI 默默代調）→ `教練`（overlay 全開）→ `專業`（手動 dial 浮出，AI 只建議）→ `回顧`（Session 篩選）。
- 教練 overlay 同時最多顯示：分數環 + 一條建議 + 必要箭頭。其餘（光位、直方圖、3D 框）長按取景器才展開 — 「功能齊全但不複雜」的執行手段。
- 專業 dial 仿 Halide：參數 chip 橫列（ISO/S/EV/WB/F），點一顆展開單一滑桿，永遠只佔底部 88pt。
- 設定抽屜（齒輪）：格式、網格、聲音、抓拍、即拍即存、LUT 管理、教練細項開關。

---

## 10. 階段路線圖（Opus 逐段執行；每段結束 = commit + push + CI 綠燈）

### P0 骨架 — 「能拍照存相簿的黑白 app」
| 任務 | 內容 |
|------|------|
| 專案腳手架 | XcodeGen `project.yml`（CI 裡 generate）、§11 目錄、`AICamCore` SPM 空套件 + 一個示範測試 |
| CaptureService | session 建立、權限、`AVCaptureVideoPreviewLayer`（包在 `PreviewRenderer` protocol 後）、HEIF 拍照、存相簿（addOnly）、前後鏡切換、virtual camera zoom |
| UI shell | tokens、4 模式左右滑空殼、快門/縮圖/焦段列 |
| CI | `core-test.yml`（ubuntu swift test）+ `ios-build.yml`（macos：xcodegen → xcodebuild unsigned → IPA artifact） |
| **驗收** | CI 綠；IPA 可側載；真機能拍能存相簿 |

### P1 專業控制
F7、F18–F22、F27。**驗收**：全手動可用；DNG 能在 Lightroom 打開且與 HEIF 配對；斑馬/峰值/直方圖即時；音量鍵快門。

### P2 教練核心（本產品靈魂）
F1–F9、F23–F25、F30 + §3 管線 + §4 引擎（含 unit tests）+ §5 3D 指導。**驗收**：真機教練模式穩 30fps、分數環與建議合理、抓拍能抓到睜眼笑容、熱降級生效、AI 代調有 toast 可還原。

### P3 AI 調色
F11–F14 + `MetalPreviewView` 替換。**驗收**：LUT 預覽 60fps 不掉帧；推薦符合場景；AutoEnhance 膚色不跑掉；RAW 顯影預設可用。

### P4 AI 篩選
F15–F17。**驗收**：100 張 <30s；糊片/閉眼全進建議捨棄；相似組只留最佳；匯出相簿正確（含 RAW 配對）。

### P5 上架與進階
F10、F28、F29：pose 卡庫、Gemini 建議（Cloudflare Worker proxy）、App icon/截圖/隱私清單、TestFlight。**用戶決策點**：Apple Developer Program（US$99/年）才能 TestFlight/上架。

---

## 11. Repo 結構

```
aicam/
├── project.yml                  # XcodeGen（CI 內 generate，不 commit xcodeproj）
├── App/Sources/
│   ├── App/                     # entry、AppState、模式切換
│   ├── Capture/                 # CaptureService、DeviceMatrix、PhotoSaver
│   ├── Preview/                 # PreviewRenderer protocol、Layer 版、Metal 版(P3)
│   ├── Coach/                   # FrameAnalyzer、CoachState、overlay 視圖、3D 指導
│   ├── ProControls/             # dial、監看（直方圖/斑馬/峰值）
│   ├── Review/                  # Session 瀏覽、篩選 UI、匯出
│   ├── ColorLab/                # LUT 預覽、AutoEnhance、RAW 顯影
│   ├── Settings/
│   └── DesignSystem/            # Tokens、共用元件
├── Core/                        # SPM: AICamCore（純 Swift，無 UIKit — ubuntu 可測）
│   ├── Sources/AICamCore/       # CompositionEngine、ScoringConfig、SuggestionCatalog、
│   │                            # CullingRanker、CubeLUTParser、LightPositionRule
│   └── Tests/AICamCoreTests/
├── Assets/                      # LUTs(.cube)、pose 剪影、App icon
├── .github/workflows/           # core-test.yml、ios-build.yml
├── MASTER-PLAN.md               # 本檔
└── README.md
```

---

## 12. CI / 打包

- `core-test.yml`：ubuntu + swift-actions/setup-swift（Swift 5.10+）→ `swift test --package-path Core`。push 到任何 branch 都跑，幾十秒內完。
- `ios-build.yml`：`macos-15`（Xcode 16.x）→ `brew install xcodegen` → `xcodegen generate` → `xcodebuild -scheme AICam -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO` → 打 `Payload/` zip 成 unsigned IPA 上傳 artifact → AltStore/SideStore 側載（Hoopilot 同款流程）。
- 上架階段（P5）：手動簽名或 fastlane + App Store Connect API key → TestFlight。

---

## 13. 上架檢查清單（P5 執行）

權限文案：`NSCameraUsageDescription`（必）、`NSPhotoLibraryAddUsageDescription`（addOnly，不聲明 readWrite）、不用麥克風就不聲明。`PrivacyInfo.xcprivacy`（無追蹤、無指紋 API）。Gemini 走 proxy 不內嵌 key。內容分級 4+。出口合規＝標準加密豁免。App 名暫定 **AICam**（上架前查重，備選 LensCoach / 構圖教練）。審查風險低（相機工具類、無 UGC）。

---

## 14. 風險與陷阱（寫 code 前先讀）

| 陷阱 | 對策 |
|------|------|
| ARKit 與 AVCaptureSession 互斥 | D2：不用 ARKit，§5 合成方案 |
| `AVCaptureVideoPreviewLayer` 不能套濾鏡 | P0 就用 `PreviewRenderer` protocol 包住，P3 換 Metal 版不動呼叫端 |
| Bayer RAW 在 virtual device 拿不到 | D8：RAW 時強制 physical 鏡頭並鎖自動切鏡 |
| ProRAW 只有 Pro 機型 | capability gate，非 Pro 隱藏選項 |
| 熱衰減：教練模式連續分析 5–10 分鐘必發熱 | §3 熱降級表 + CPU 預算 40%；Tier C 頻率寧低勿高 |
| iOS 18-only Vision API（美學分） | `#available(iOS 18)` + fallback（NIMA 或組合分） |
| RAW 容量爆炸（ProRAW 一張 ~75MB） | Session 制 + 垃圾桶自動清 + 容量條警示 |
| 前鏡無 RAW、無 LiDAR | 功能 gate，UI 不出現不可用選項 |
| 分析結果座標系混亂（Vision 正規化 vs UIKit vs 感光元件方向） | Core 內統一定義 `NormalizedFrame` 座標型別 + 轉換函式 + 單元測試鎖住 |
| 中文教練文案超框 | 語料 ≤10 字硬規則，Core 測試檢查 |

---

## 15. 真機驗證清單（CI 驗不了，需用戶 iPhone 實測）

每階段完成後產「真機測試腳本」給用戶：P0 拍照/存相簿/切鏡；P1 DNG 進 Lightroom 檢查、手動參數生效；P2 30fps 流暢度、發熱、抓拍準度、建議合理性（**拿女友實拍 20 張回報**）；P3 LUT 預覽流暢度、膚色；P4 拿 50 張實拍跑篩選看準度。**執行者不得宣稱「已在真機驗證」，只能標「待真機驗證」。**

---

## 16. 給 Opus 的執行鐵律

1. 動工前讀完本檔；§1 已定案決策不重開。
2. 一次一個階段，完成 = CI 綠 + push，不跨階段偷跑；commit 訊息標階段（如 `P1: manual exposure + RAW`）。
3. 本機是 Windows、無 Xcode：**以 CI 錯誤訊息迭代**；寫碼時自查 API availability（base iOS 17）。
4. `AICamCore` 的每個模組必附 unit test（ubuntu CI 要跑得過）— 構圖評分、語料選擇、LUT 解析、篩選排序全都可純邏輯測。
5. 教練文案一律繁體中文；UI 恪守 §9 黑白 tokens，不加彩色。
6. 誠實原則：3D 指導不吹精度；未真機驗證的功能一律標註「待真機驗證」。
7. 效能預算：教練模式 CPU <40%、預覽 ≥30fps；超標先降 Tier 頻率，不砍功能。
8. 不引入第三方依賴（D9）；要加先在 commit 訊息寫理由。
