//  MetalPreviewView.swift
//  AICam — Metal 即時濾鏡取景器（A3；MASTER-PLAN §6 F11 / v0.3.0 契約）。
//
//  管線：VideoFrameTap.onPreviewFrame（analysisQueue、~30fps、每帧）
//    → Coordinator 存最新 buffer（鎖保護、只留 1 顆）
//    → 主執行緒 setNeedsDisplay（MTKView isPaused + enableSetNeedsDisplay：
//       按需繪製，draw 一律在主執行緒 → recipeProvider 可安全讀 MainActor 狀態）
//    → draw：CIImage → LookEngine.apply（passthrough 在 apply 內原樣返回，
//       零濾鏡成本直畫原帧）→ aspect-fill 變換 → CIContext.render 進 drawable。
//
//  效能設計：
//  - 目標 30fps（相機出帧率）；重繪由「新帧到達」驅動，無帧不畫、不空轉。
//  - CIContext(mtlDevice:) + .cacheIntermediates=false：視訊流每帧內容都不同，
//    快取中繼結果只耗記憶體（WWDC20 Core Image 視訊管線建議）。
//  - 濾鏡鏈 4 級全是 GPU 內建 filter，CI 會 concat 成單一 program；
//    1080p×30fps 預估 GPU 佔用低個位數 ms/帧等級。
//  - passthrough（id=="none"）不建任何 filter → 只剩縮放 + blit。
//
//  失敗契約：Metal device / commandQueue 建立失敗、或繪製時 commandBuffer
//  拿不到（首帧 render 失敗的可觀測形式）→ onFailure() 恰一次（主執行緒 async，
//  不在 SwiftUI view update 當下同步觸發狀態變更）。呼叫端據此退回
//  AVCaptureVideoPreviewLayer 取景器。
//
//  垂直方向注釋（待真機驗證）：CIContext.render(_:to:texture) 走 Apple
//  WWDC20 範例同款寫法，預期直立；若真機上下顛倒，在 draw 內對 image 補
//  .oriented(.downMirrored) 一行即修。
//
//  生命週期：dismantleUIView → detach()（清 onPreviewFrame + 放掉 buffer）；
//  Coordinator.deinit 再保險一次。tap 的回呼弱持 Coordinator，無 retain cycle。

import AICamCore
import CoreImage
import MetalKit
import SwiftUI
import UIKit

struct MetalPreviewView: UIViewRepresentable {

    let tap: VideoFrameTap
    let recipeProvider: () -> LookRecipe
    let onFailure: () -> Void

    init(
        tap: VideoFrameTap,
        recipeProvider: @escaping () -> LookRecipe,
        onFailure: @escaping () -> Void
    ) {
        self.tap = tap
        self.recipeProvider = recipeProvider
        self.onFailure = onFailure
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(tap: tap, recipeProvider: recipeProvider, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.backgroundColor = .black
        view.isOpaque = true

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            // Metal 不可用（模擬器極舊組態/資源耗盡）：回報一次，
            // view 維持純黑（呼叫端收到 onFailure 後應換回 layer 取景器）。
            context.coordinator.reportFailure()
            return view
        }

        view.device = device
        // CIContext.render 需要對 drawable texture 寫入 → 不能 framebufferOnly
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        // 按需繪製：只有新帧 setNeedsDisplay 才畫（相機 30fps 驅動，不用內建計時器）
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        context.coordinator.attach(view: view, device: device, commandQueue: commandQueue)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MTKViewDelegate {

        private let tap: VideoFrameTap
        private let recipeProvider: () -> LookRecipe
        private let onFailure: () -> Void

        private var ciContext: CIContext?
        private var commandQueue: MTLCommandQueue?
        private weak var mtkView: MTKView?
        private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

        /// 最新帧（鎖保護：analysisQueue 寫、主執行緒 draw 讀；只留 1 顆 pool buffer，
        /// 與 VideoFrameTap.latestPixelBuffer 同款策略）。
        private let bufferLock = NSLock()
        private var latestBuffer: CVPixelBuffer?

        /// 只在主執行緒觸碰（makeUIView / draw 都在主執行緒）→ 不需鎖。
        private var hasFailed = false

        /// 重用 filter 鏈（v0.3.0 修正輪）：以 recipe.id 快取已建好的 CIFilter，
        /// 每帧只換 inputImage — 30fps 下不再每帧新建最多 4 顆 filter。
        /// 僅在 draw（主執行緒序列）使用，不需鎖。
        private let lookChain = CachedLookChain()

        init(
            tap: VideoFrameTap,
            recipeProvider: @escaping () -> LookRecipe,
            onFailure: @escaping () -> Void
        ) {
            self.tap = tap
            self.recipeProvider = recipeProvider
            self.onFailure = onFailure
            super.init()
        }

        deinit {
            // 保險：dismantleUIView 未被呼叫的路徑也要清回呼（nil = 零成本契約）。
            // 擁有者比對版：view 重建時舊 Coordinator 的 ARC 延遲 deinit 可能晚於
            // 新 Coordinator attach — 無條件清空會抹掉新回呼（預覽靜默凍結）。
            tap.clearPreviewFrameHandler(owner: self)
        }

        func attach(view: MTKView, device: MTLDevice, commandQueue: MTLCommandQueue) {
            mtkView = view
            self.commandQueue = commandQueue
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            // 弱持 self：tap 存活期比本 view 長（CameraController 持有），
            // 強捕獲會讓 Coordinator 永不釋放。帶擁有者設定：detach/deinit 只清
            // 自己的回呼，不誤傷後繼 Coordinator（時序防護見 VideoFrameTap 注釋）。
            tap.setPreviewFrameHandler({ [weak self] buffer in
                self?.ingest(buffer)
            }, owner: self)
        }

        func detach() {
            tap.clearPreviewFrameHandler(owner: self)
            bufferLock.lock()
            latestBuffer = nil
            bufferLock.unlock()
        }

        func reportFailure() {
            guard !hasFailed else { return }
            hasFailed = true
            // async：不在 SwiftUI view update / draw 當下同步改呼叫端狀態
            let callback = onFailure
            DispatchQueue.main.async {
                callback()
            }
        }

        /// analysisQueue（每帧、契約：不受分析節流影響）。
        private func ingest(_ buffer: CVPixelBuffer) {
            bufferLock.lock()
            latestBuffer = buffer
            bufferLock.unlock()
            // 每帧主執行緒 async setNeedsDisplay（契約）；同一 runloop 內多次
            // setNeedsDisplay 由系統合併，30fps 不會堆積
            DispatchQueue.main.async { [weak self] in
                self?.mtkView?.setNeedsDisplay()
            }
        }

        // MARK: - MTKViewDelegate（主執行緒）

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            bufferLock.lock()
            let buffer = latestBuffer
            bufferLock.unlock()
            guard let buffer, let ciContext, let commandQueue else { return }
            guard let drawable = view.currentDrawable else { return }
            let size = view.drawableSize
            guard size.width > 0, size.height > 0 else { return }

            var image = CIImage(cvPixelBuffer: buffer)
            // 相機 buffer extent 原點恆為 (0,0)；防禦性歸零讓後面縮放數學成立
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { return }
            if extent.origin != .zero {
                image = image.transformed(
                    by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
                )
            }

            // 套 Look（passthrough 在 apply 內原樣返回 → 直畫原帧）；
            // draw 在主執行緒 → recipeProvider 可安全讀 MainActor / @Observable 狀態。
            // 走 CachedLookChain：與 LookEngine.apply 同語意，filter 依 recipe.id 重用
            image = lookChain.apply(recipeProvider(), to: image)

            // aspect-fill 縮放：取兩軸放大比的「較大者」→ 短邊貼齊 drawable、
            // 長邊超出，置中後由 render bounds 裁掉超出部分（與
            // AVCaptureVideoPreviewLayer 的 .resizeAspectFill 同語意）。
            // offset = (drawable 尺寸 − 縮放後尺寸) / 2，超出軸為負值 = 置中裁切。
            let scale = max(size.width / extent.width, size.height / extent.height)
            let offsetX = (size.width - extent.width * scale) / 2
            let offsetY = (size.height - extent.height * scale) / 2
            image = image
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                // 首帧（或任何一帧）拿不到 commandBuffer = 裝置 GPU 不可用 →
                // 失敗契約：回報一次，呼叫端退回 layer 取景器
                reportFailure()
                return
            }
            // aspect-fill 蓋滿整個 bounds → 不需先清背景
            ciContext.render(
                image,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: CGRect(origin: .zero, size: size),
                colorSpace: colorSpace ?? CGColorSpaceCreateDeviceRGB()
            )
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
