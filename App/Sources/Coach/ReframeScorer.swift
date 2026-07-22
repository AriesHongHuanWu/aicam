//  ReframeScorer.swift
//  AICam — Reframe 構圖模型上機（A1；v0.3.0 「AI 全面接管」）。
//
//  模型（App/Resources/ReframeModel.mlpackage；Training/export_coreml.py 產出）：
//  - 輸入 "image"：224×224 RGB ImageType。ImageNet 正規化「已烘進模型」
//    （ImageType scale/bias + 模型內除 std）→ Swift 端直接餵 0–255 影像，
//    絕不能再自己做任何正規化。
//  - 輸出 "score"：(1,) 構圖排序分 — pairwise 排序訓練，數值無絕對意義。
//  - 輸出 "delta"：(1,3) 取景差量 (dx, dy, dzoom) = 目前取景相對理想取景的
//    誤差向量；修正指令 = −delta（dx>0 → 往左移、dy>0 → 取景抬高、
//    dzoom>0 → 退後/換廣角）。dzoom 訓練標籤恆 ≥ 0（無「太鬆」負例），
//    負值/小值「不可」解讀成上前。
//
//  前處理對齊（Training/dataset.py 載重不變量）：全帧視窗 squash resize 成
//  224×224（不做 center crop、不保長寬比）— 訓練正例就是完整原始取景
//  squash 後的樣子，上機必須走同一條幾何路徑。
//
//  載入策略（XcodeGen 對 .mlpackage 的兩手準備，無本機編譯無法驗證是哪條）：
//  1) project.yml 把 App/Resources 放在 sources → Xcode 正常會用 Core ML
//     compiler 把 mlpackage 編成 ReframeModel.mlmodelc 進 bundle → 直接載入。
//  2) 若被當 folder resource 原樣拷進 bundle → 找到 mlpackage 後用
//     MLModel.compileModel(at:) 現場編譯一次，把編譯結果搬進
//     Application Support（帶 app 版本的快取路徑）之後重用，不必每次啟動重編。
//  兩條都失敗 → init 回 nil，呼叫端（CoachSession）全程走純規則路徑。
//
//  執行緒模型：score 同步、非執行緒安全（重用單一 input buffer）—
//  契約規定呼叫端已在單一背景 queue（CoachSession 的 analysisQueue）序列呼叫。
//
//  待真機驗證（ANE 延遲目標 <8ms；MASTER-PLAN §4.3b / §4.8）。

import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

final class ReframeScorer {

    private let model: MLModel
    /// CIContext 本身執行緒安全；只用於縮放輸入帧。
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// 模型輸入邊長（export_coreml.py 固定 224）。
    private static let inputSide = 224
    /// 重用的 224×224 BGRA 輸入 buffer（單一背景 queue 序列使用，不需鎖）。
    private var reusableInput: CVPixelBuffer?

    // MARK: - 載入（契約：失敗回 nil，不 crash）

    init?() {
        let config = MLModelConfiguration()
        config.computeUnits = .all   // 優先 ANE

        // 路徑 1：Xcode 已把 mlpackage 編成 mlmodelc 進 bundle
        if let compiledURL = Bundle.main.url(forResource: "ReframeModel", withExtension: "mlmodelc"),
           let loaded = try? MLModel(contentsOf: compiledURL, configuration: config) {
            model = loaded
            return
        }
        // 路徑 2：bundle 裡是原樣 mlpackage → 現場編譯一次 + Application Support 快取
        guard
            let packageURL = Bundle.main.url(forResource: "ReframeModel", withExtension: "mlpackage"),
            let loaded = Self.loadCompilingIfNeeded(packageURL: packageURL, configuration: config)
        else {
            return nil
        }
        model = loaded
    }

    /// mlpackage → 編譯 → 快取到 Application Support/ReframeModel/v{版本}-{build}/。
    /// 快取存在且可載入 → 直接用；損壞 → 清掉重編；舊版本快取 best-effort 清理。
    private static func loadCompilingIfNeeded(
        packageURL: URL, configuration: MLModelConfiguration
    ) -> MLModel? {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
        let cacheRoot = support.appendingPathComponent("ReframeModel", isDirectory: true)
        let cacheDir = cacheRoot.appendingPathComponent("v\(version)-\(build)", isDirectory: true)
        let cachedURL = cacheDir.appendingPathComponent("ReframeModel.mlmodelc", isDirectory: true)

        // 快取命中
        if fm.fileExists(atPath: cachedURL.path) {
            if let loaded = try? MLModel(contentsOf: cachedURL, configuration: configuration) {
                return loaded
            }
            try? fm.removeItem(at: cachedURL)   // 快取損壞 → 重編
        }

        // 編譯一次（同步版在 iOS 16+ 標記 deprecated，仍可用；init 在背景 queue
        // 被 lazy 觸發，不佔主執行緒 — 見 CoachSession 的載入時機注釋）
        guard let compiled = try? MLModel.compileModel(at: packageURL) else { return nil }

        // 舊版本快取 best-effort 清理（換版後不留孤兒目錄）
        if let entries = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent != cacheDir.lastPathComponent {
                try? fm.removeItem(at: entry)
            }
        }

        do {
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: cachedURL)
            try fm.moveItem(at: compiled, to: cachedURL)
            return try MLModel(contentsOf: cachedURL, configuration: configuration)
        } catch {
            // 搬移/建目錄失敗（磁碟滿等）→ 退而載入臨時編譯結果（本次可用、下次重編）
            return try? MLModel(contentsOf: compiled, configuration: configuration)
        }
    }

    // MARK: - 推論（契約）

    /// 對單帧評分（同步；呼叫端已在背景 queue）。內部把 buffer squash 縮放為
    /// 224×224 再餵模型。失敗（縮放/推論/輸出形狀異常/非有限值）一律回 nil。
    /// score01 = sigmoid(raw/2.0)：「相對分校準，非絕對品質」— pairwise 排序分
    /// 壓進 0…1 顯示域用，數值本身不代表照片好壞的絕對度量。
    func score(_ buffer: CVPixelBuffer) -> (score01: Double, delta: SIMD3<Double>)? {
        predict(image: CIImage(cvPixelBuffer: buffer))
    }

    /// 便利入口：JPEG 資料 → 解碼 → 同一條推論路徑。
    /// v0.3.0 修正輪後主路徑已改直餵 buffer（VideoFrameTap.latestAnalysisBuffer
    /// → score(_:)），本入口目前無呼叫端 — 保留供離線評測/測試用。
    func score(jpegData: Data) -> (score01: Double, delta: SIMD3<Double>)? {
        guard let image = CIImage(data: jpegData) else { return nil }
        return predict(image: image)
    }

    private func predict(image: CIImage) -> (score01: Double, delta: SIMD3<Double>)? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite,
              let input = makeInputBuffer() else { return nil }

        let side = CGFloat(Self.inputSide)
        // 全帧 squash resize（與 Training/dataset.py 對齊：不 center crop、不保長寬比）
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: side / extent.width, y: side / extent.height))
            .clampedToExtent()   // 浮點縮放的 sub-pixel 邊緣防呆（render bounds 裁回 224×224）
        ciContext.render(
            scaled,
            to: input,
            bounds: CGRect(x: 0, y: 0, width: side, height: side),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        do {
            // 正規化已烘進模型 → 直接餵 0–255 影像（BGRA buffer 由 Core ML 依
            // ImageType 的 RGB color layout 自行轉換）
            let provider = try MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: input)]
            )
            let output = try model.prediction(from: provider)
            guard
                let scoreArray = output.featureValue(for: "score")?.multiArrayValue,
                let deltaArray = output.featureValue(for: "delta")?.multiArrayValue,
                scoreArray.count >= 1, deltaArray.count >= 3
            else { return nil }

            // MLMultiArray Int subscript = 線性索引：(1,3) 依序 dx, dy, dzoom
            let raw = scoreArray[0].doubleValue
            let dx = deltaArray[0].doubleValue
            let dy = deltaArray[1].doubleValue
            let dzoom = deltaArray[2].doubleValue
            guard raw.isFinite, dx.isFinite, dy.isFinite, dzoom.isFinite else { return nil }

            // 相對分校準，非絕對品質（見函式注釋）
            let score01 = 1.0 / (1.0 + exp(-raw / 2.0))
            return (score01, SIMD3<Double>(dx, dy, dzoom))
        } catch {
            return nil
        }
    }

    /// 重用的 224×224 BGRA 輸入 buffer（IOSurface-backed，利於 ANE 餵入）。
    private func makeInputBuffer() -> CVPixelBuffer? {
        if let reusableInput { return reusableInput }
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.inputSide, Self.inputSide,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        reusableInput = buffer
        return buffer
    }
}
