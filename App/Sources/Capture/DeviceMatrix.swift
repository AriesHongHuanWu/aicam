//  DeviceMatrix.swift
//  AICam — 鏡頭矩陣（A2：相機層）。MASTER-PLAN §8 / F21 / D8。
//
//  D8：一般/教練模式用 virtual camera（自動切鏡 + 平滑 zoom），
//  所以後鏡優先挑 virtual device：Triple → DualWide → Dual → Wide。
//  焦段表由 constituentDevices + virtualDeviceSwitchOverVideoZoomFactors 推得：
//  - 有超廣角時 videoZoomFactor 1.0 = 超廣角 = 「0.5x」；第一個 switchover = 主鏡 = 「1x」；
//    其後的 switchover 為長焦，標籤 = factor / 主鏡 factor（如 6/2 = 3 → 「3x」）。
//  - 無超廣角（wide+tele 的 Dual）時 1.0 = 「1x」，switchover 直接當標籤（2x/3x）。
//  - 單鏡 / 前鏡 = 只有「1x」。
//  註：iPhone 14 Pro 之後主鏡感光元件裁切的「2x」不在 P0 焦段表
//（需要 format 的 secondaryNativeResolutionZoomFactors，留給 P1 專業控制階段）。

import AVFoundation

/// 一顆可選焦段（A2 擁有定義；A3 的 LensBar 直接吃這個）。
struct LensOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String  // "0.5x" "1x" "2x" "3x" "5x"
    let zoomFactor: CGFloat  // 要設到 device.videoZoomFactor 的值
}

enum DeviceMatrix {

    /// 依 MASTER-PLAN §8 優先序挑本機最佳鏡頭。
    /// 後鏡：Triple → DualWide → Dual → Wide；前鏡：TrueDepth → Wide。
    static func bestDevice(front: Bool) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = front
            ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: front ? .front : .back
        )
        for type in types {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) {
                return device
            }
        }
        return discovery.devices.first
    }

    /// 從當前 device 產生本機焦段表。
    static func lensOptions(for device: AVCaptureDevice) -> [LensOption] {
        guard device.position == .back,
              device.isVirtualDevice,
              device.constituentDevices.count > 1
        else {
            return [LensOption(id: "1x", label: "1x", zoomFactor: 1.0)]
        }

        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors
            .map { CGFloat($0.doubleValue) }
            .sorted()
        let hasUltraWide = device.constituentDevices.contains {
            $0.deviceType == .builtInUltraWideCamera
        }

        var options: [LensOption] = []
        if hasUltraWide {
            // 1.0 = 超廣角視角 = 0.5x
            options.append(LensOption(id: "0.5x", label: "0.5x", zoomFactor: 1.0))
            // 第一個 switchover 切到主鏡 = 1x（讀不到時取 2.0 慣例值）
            let wideFactor = switchOvers.first ?? 2.0
            options.append(LensOption(id: "1x", label: "1x", zoomFactor: wideFactor))
            // 其後為長焦：顯示倍率 = factor / 主鏡 factor
            for factor in switchOvers.dropFirst() where wideFactor > 0 {
                let label = displayLabel(factor / wideFactor)
                options.append(LensOption(id: label, label: label, zoomFactor: factor))
            }
        } else {
            // 無超廣角：1.0 就是主鏡
            options.append(LensOption(id: "1x", label: "1x", zoomFactor: 1.0))
            for factor in switchOvers {
                let label = displayLabel(factor)
                options.append(LensOption(id: label, label: label, zoomFactor: factor))
            }
        }

        // 防禦：異常 switchover 陣列導致標籤撞名時去重（id 必須唯一）
        var seen = Set<String>()
        return options.filter { seen.insert($0.id).inserted }
    }

    /// 預設鏡位 = 1x（找不到就取第一顆）。
    static func defaultLens(in options: [LensOption]) -> LensOption? {
        options.first { $0.label == "1x" } ?? options.first
    }

    /// 慣例標籤：整數 → 「3x」；非整數 → 一位小數「2.5x」。
    private static func displayLabel(_ multiplier: CGFloat) -> String {
        let rounded = (multiplier * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))x"
        }
        return String(format: "%.1fx", Double(rounded))
    }
}
