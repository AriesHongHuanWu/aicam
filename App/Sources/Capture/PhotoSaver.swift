//  PhotoSaver.swift
//  AICam — 存相簿（A2：相機層）。MASTER-PLAN D5：只申請 addOnly，不碰 readWrite。

import Photos

enum PhotoSaver {

    /// 把拍好的照片原始 data（HEIF/JPEG）以 addOnly 權限寫入系統相簿。
    /// 回傳是否成功（未授權 / 寫入失敗都回 false，P0 靜默不擋拍照流程）。
    static func save(photoData: Data) async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else { return false }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: photoData, options: nil)
            }
            return true
        } catch {
            return false
        }
    }
}
