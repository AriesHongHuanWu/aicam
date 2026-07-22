//  PhotoCaptureDelegate.swift
//  AICam — 單次拍照 delegate + 拍後影像處理（A2：相機層）。
//
//  AVCapturePhotoOutput 只弱持有 delegate：呼叫端（CaptureSessionService）
//  必須把本物件存進 dictionary（key = settings.uniqueID）強持有，
//  didFinishCaptureFor 回呼後才移除。
//
//  P0 流程：didFinishProcessingPhoto 取 fileDataRepresentation()（HEIF 或 JPEG）
//  → didFinishCaptureFor 收尾，把 data 交回 completion（保證恰好呼叫一次）。
//  後續（存相簿 / 縮圖 / 1280px JPEG / v0.3.0 Look 烘焙 / v0.5.0 特效烘焙）
//  由 CameraController 統籌。

import AVFoundation
import UIKit
import AICamCore

/// 一次 capturePhoto 的 delegate。completion 恰好呼叫一次；失敗時給 nil。
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {

    private let completion: @Sendable (Data?) -> Void
    private var photoData: Data?
    private var didFinish = false

    init(completion: @escaping @Sendable (Data?) -> Void) {
        self.completion = completion
        super.init()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil else { return }
        photoData = photo.fileDataRepresentation()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        // AVFoundation 對同一 delegate 的回呼是序列化的，didFinish 不需額外鎖。
        guard !didFinish else { return }
        didFinish = true
        completion(photoData)
    }
}

// MARK: - 拍後影像處理

/// 拍後衍生物：UI 縮圖（~200px）與教練 / 導演層用的 ~1280px JPEG。
/// UIImage 實務上不可變；標 @unchecked Sendable 讓它能安全跨 Task 邊界。
struct ProcessedPhoto: @unchecked Sendable {
    let thumbnail: UIImage?
    let coachJPEG: Data?
}

enum CapturedPhotoProcessor {

    /// 從原始拍照 data（HEIF/JPEG）產生縮圖與 1280px JPEG。
    /// 可在任意背景執行緒呼叫（UIGraphicsImageRenderer 是執行緒安全的）。
    static func process(_ data: Data) -> ProcessedPhoto {
        guard let image = UIImage(data: data) else {
            return ProcessedPhoto(thumbnail: nil, coachJPEG: nil)
        }
        let thumbnail = downscale(image, longestSide: 200)
        let coach = downscale(image, longestSide: 1280)
        return ProcessedPhoto(
            thumbnail: thumbnail,
            coachJPEG: coach?.jpegData(compressionQuality: 0.85)
        )
    }

    /// Look＋特效烘焙（v0.3.0 Look；v0.5.0 擴充分割特效）：
    /// 原始拍照 data（HEIF/JPEG）→ 帶 Look（＋特效）的 JPEG。
    /// quality 0.92（存相簿等級）；失敗回 nil，呼叫端 fallback 存原檔（照片永不丟失）。
    /// recipe 可為 passthrough（v0.5.0 修正輪：Look=原色但特效已選的組合 —
    /// LookEngine 對 passthrough 原樣返回，特效照套）；
    /// keepOriginal 邏輯不在本層 — 呼叫端依回傳值沿用既有存檔分支。
    ///
    /// 特效選擇讀 UserDefaults "effect.selected"（與 AppStorage 同 key；
    /// 未設定或未知 id 一律視為「無」）：
    /// - 特效 = 無 → 走既有 LookEngine.renderJPEG，行為與 v0.3.0 完全相同
    ///   （不建 SegmentationEngine、不跑分割 — 特效未啟用零成本鐵律）。
    /// - 特效 ≠ 無 → EffectCompositor.bake（合成次序鐵律：Look 先全域 →
    ///   特效以 mask 分域）；mask 由 SegmentationEngine.accurateMask 供應
    ///   （.accurate 人像分割，無人時 iOS 17 任意主體 fallback；再無 mask →
    ///   bake 內只落 Look，特效靜默略過）。
    ///
    /// 效能：本函式恆在拍照處理背景 queue（CameraController.capturePhoto 的
    /// Task.detached）執行，特效路徑含 .accurate 分割 ~1–2s（契約允許）。
    /// 執行緒：無共享可變狀態；SegmentationEngine 每次烘焙新建（一次性
    /// .accurate request，非逐帧路徑，重用無收益）。
    static func bakeLook(into data: Data, recipe: LookRecipe) -> Data? {
        let effectID = UserDefaults.standard.string(forKey: "effect.selected")
            ?? EffectRecipe.none.id
        guard let effect = EffectRecipe.byID(effectID),
              effect.id != EffectRecipe.none.id
        else {
            // 特效未啟用（或未知 id 防呆）：與 v0.3.0 完全同路徑、零額外成本。
            return LookEngine.renderJPEG(from: data, recipe: recipe, quality: 0.92)
        }
        // 特效烘焙失敗（解碼/輸出錯誤）→ 降級試純 Look；再失敗回 nil =
        // 呼叫端存原檔（既有 fallback 鏈不變，照片永不丟失）。
        return EffectCompositor.bake(
            jpeg: data,
            look: recipe,
            effect: effect,
            maskProvider: { SegmentationEngine().accurateMask(forJPEG: data) },
            quality: 0.92
        ) ?? LookEngine.renderJPEG(from: data, recipe: recipe, quality: 0.92)
    }

    /// 等比縮到長邊 = longestSide（原圖較小則原尺寸重繪）。
    /// draw(in:) 會把 EXIF orientation 烘進像素，輸出一律為直立影像。
    static func downscale(_ image: UIImage, longestSide: CGFloat) -> UIImage? {
        let width = image.size.width
        let height = image.size.height
        let longest = max(width, height)
        guard longest > 0 else { return nil }

        let scale = min(1, longestSide / longest)
        let target = CGSize(
            width: max(1, (width * scale).rounded(.down)),
            height: max(1, (height * scale).rounded(.down))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
