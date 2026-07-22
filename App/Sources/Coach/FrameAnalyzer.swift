//  FrameAnalyzer.swift
//  AICam — 教練即時分析（A5）：單帧 CVPixelBuffer → FrameFacts（MASTER-PLAN §3 Tier B）。
//
//  執行緒模型：analyze(...) 只在 VideoFrameTap 的 analysisQueue 上呼叫（serial），
//  Vision request 物件與快取（lastJoints / saliency）皆為該 queue 專屬，不需鎖。
//  CoreMotion 回呼在 motionQueue 寫入 latestGravity（stateLock 保護），分析時讀最新值。
//
//  節奏（~15fps 一次 analyze；提速輪 0.1s → 0.066s）：
//  - 臉 rectangles + landmarks：每次。
//  - body pose：每 3 次一次（~5fps），其餘沿用上次結果；熱降級停用時清空
//    （不留舊關節誤判切邊）。
//  - saliency（無臉時的主體 fallback）：只在「無臉持續 > 1s」後才啟動，
//    之後每 ~1s 一次，結果 2.5s 內有效 — 有人臉的正常拍攝路徑完全不付 saliency 成本。
//  - 場景分類 VNClassifyImageRequest（v0.3.0 F12 調色推薦）：每 ~1s 一次，
//    confidence > 0.3 前 5 個 identifier；兩次之間沿用快取（場景變化慢，
//    ≤1s 陳舊可接受）；perform 失敗清空（誠實：拿不到就空陣列）。
//  - 人像分割（v0.5.0 特效 mask）：僅當 effect.selected != "none" 且
//    effect.liveEnabled 且 look.livePreview（Metal 取景器＝唯一 live mask 消費者）
//    且熱狀態 < serious 時，每 2 次 tick 跑一次
//    SegmentationEngine.liveMask（~7fps）→ MaskStore（MainActor、帶序號防亂序）。
//    特效關閉 = 零 Vision 呼叫零成本（engine 為 lazy，連 request 都不建）；
//    關閉／熱降級／切鏡時發 nil 清空 MaskStore。%2==0 與 body pose（%3==1）
//    每 6 tick 疊一次（tick 4、10…），無法完全錯開，已知取捨。
//    v0.5.0 修正輪：教練分析未啟用（拍照等模式）時另有獨立入口
//    runStandaloneSegmentationIfDue（VideoFrameTap 呼叫、0.15s 節流 ≈ 同節奏）—
//    取景即時特效不再只綁教練模式。
//  - VNDetectFaceCaptureQualityRequest：本檔「沒有」執行（FaceFact.captureQuality
//    恆為 nil，屬 P4 篩選範疇），即時管線不付這筆成本。
//
//  v0.5.0 群組合照（A3）：最大臉無條件保留（單人行為完全不變）；第 2、3 張臉
//  需過 Vision confidence 門檻才進 facts（低信心殘影不得觸發群組模式）。
//  ≥2 臉時 subjectBox = 所有臉框 union 各邊外擴 15% 後 clamp 0…1（整群 = 主體；
//  下游 TargetSolver / GroupGuard / isGroupMode 全以 faces.count ≥ 2 判群組，
//  門檻在本檔一處把關，語意自動一致）。
//
//  座標鐵律：
//  - Vision 輸出 normalized、原點左下、y 向上 → 一律經 VisionCoordinateMapping 轉
//    NormalizedFrame（原點左上、y 向下）。
//  - buffer 已由 connection 轉直立 portrait（videoRotationAngle=90）→ Vision 用 .up。
//  - 前鏡 buffer 已鏡像（與 preview 一致）→ 不再翻 x；NormalizedFrame 的「左」= 螢幕左。
//  - NormalizedFrame（y 向下）與像素列方向一致 → 亮度/直方圖取樣直接乘寬高。
//
//  待真機驗證（EAR / smile 門檻為啟發式，見各函式注釋）。

import AICamCore
import CoreGraphics
import CoreMotion
import CoreVideo
import Foundation
import ImageIO
import Vision

final class FrameAnalyzer {

    // MARK: - Vision requests（重用；analysisQueue 專屬）

    private let faceRectanglesRequest = VNDetectFaceRectanglesRequest()
    private let faceLandmarksRequest = VNDetectFaceLandmarksRequest()
    private let bodyPoseRequest = VNDetectHumanBodyPoseRequest()
    private let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
    /// 場景分類（F12 調色推薦）：每 ~1s 才 perform 一次（見檔頭節奏）。
    private let classifyRequest = VNClassifyImageRequest()
    /// v0.5.0 群組偵測：第 2 張臉起需過的 Vision confidence 門檻。
    /// 最大臉「無條件」保留 — 單人行為完全不變；此門檻只擋「額外」的低信心
    /// 觀測誤觸發群組模式。VNDetectFaceRectanglesRequest 對真臉通常 > 0.9，
    /// 0.5 屬保守（啟發式，待真機驗證）。
    private static let groupFaceMinConfidence: Float = 0.5

    // MARK: - analysisQueue 專屬狀態

    private var analysisCount = 0
    private var lastJoints: [JointFact] = []
    private var lastSaliencyBox: NRect?
    private var lastSaliencyRunAt: Double = -.greatestFiniteMagnitude
    private var lastSaliencyHitAt: Double = -.greatestFiniteMagnitude
    /// 「無臉」狀態的起始時間（media timestamp）；有臉即清空。
    /// saliency 只在無臉持續 > 1s 後才跑（見檔頭節奏注釋）。
    private var noFaceSince: Double?
    /// 場景分類節奏與快取（每 ~1s 一次；兩次之間沿用上次結果）。
    private var lastClassifyAt: Double = -.greatestFiniteMagnitude
    private var lastSceneTags: [String] = []
    /// 上一帧的前後鏡標記：變化 = 座標空間鏡像跳變 → 就地清跨帧快取
    /// （與 scheduleReset 雙保險，不依賴通知時序）。
    private var lastIsFront: Bool?
    /// 人像分割引擎（v0.5.0；lazy = 特效從未啟用時連 request 物件都不建，
    /// 效能守護契約「零成本」）。lazy var 非執行緒安全，但只在 analysisQueue 觸碰。
    private lazy var segmentation = SegmentationEngine()
    /// mask 發布序號（單調遞增、不隨 clearFrameCaches 歸零）：MaskStore.apply
    /// 以此丟棄亂序抵達 MainActor 的舊發布（清空不得被舊 mask 蓋回）。
    private var maskSequence = 0
    /// MaskStore 目前是否持有本分析器發布的 mask（避免特效關閉後每 tick 重複發 nil）。
    private var maskPublished = false
    /// 獨立分割 tick 的節流基準（v0.5.0 修正輪：教練分析未啟用時的即時特效
    /// 路徑；analysisQueue 專屬）。
    private var lastStandaloneSegmentationAt: Double = -.greatestFiniteMagnitude

    // MARK: - 跨執行緒狀態（stateLock 保護）

    private let stateLock = NSLock()
    private var latestGravity: CMAcceleration?
    private var bodyPoseEnabled = true
    private var resetPending = false

    /// 任意執行緒可呼叫（CoachSession 的重置路徑：切鏡/翻鏡/教練模式重啟）。
    /// 實際清快取延到下一次 analyze（analysisQueue 上）執行 — 否則 pose 每 3 次
    /// 才跑一次，重置後最多 2 次分析（~0.13s）會沿用上一個鏡頭座標空間的舊關節，
    /// makeSubjectBox 可能產出錯位主體框餵進剛重置乾淨的導引管線。
    func scheduleReset() {
        stateLock.lock()
        resetPending = true
        stateLock.unlock()
    }

    // MARK: - CoreMotion

    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.arieswu.aicam.coach.motion"
        return queue
    }()

    /// deviceMotion 60Hz 開始更新（CoachSession.setActive(true) 呼叫）。
    func startMotion() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.stateLock.lock()
            self.latestGravity = motion.gravity
            self.stateLock.unlock()
        }
    }

    func stopMotion() {
        motionManager.stopDeviceMotionUpdates()
        stateLock.lock()
        latestGravity = nil
        stateLock.unlock()
    }

    /// 熱降級時停用 body pose（CoachSession 呼叫）。
    func setBodyPoseEnabled(_ enabled: Bool) {
        stateLock.lock()
        bodyPoseEnabled = enabled
        stateLock.unlock()
    }

    // MARK: - 主流程（只在 analysisQueue 呼叫）

    func analyze(pixelBuffer: CVPixelBuffer, timestamp: Double, isFront: Bool) -> FrameFacts {
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)

        stateLock.lock()
        let poseEnabled = bodyPoseEnabled
        let gravity = latestGravity
        let doReset = resetPending
        resetPending = false
        stateLock.unlock()

        // 排程重置（切鏡/翻鏡/重啟）或前後鏡標記變化 → 先清跨帧快取，
        // 不讓上一個鏡頭座標空間的關節/saliency 餵進本帧。
        if doReset || (lastIsFront != nil && lastIsFront != isFront) {
            clearFrameCaches()
        }
        lastIsFront = isFront
        // 快取清空後 analysisCount 從 0 起 → 本帧 analysisCount == 1 → 立即重跑
        // body pose（不留舊關節空窗）。
        analysisCount += 1

        // 防線：整條座標鏈假設 connection 已把 buffer 轉直立 portrait
        // （videoRotationAngle=90）。若某機型/組態不支援 90°（CameraController 是
        // 靜默跳過），buffer 會維持橫向 → Vision 結果整套落在「轉了 90° 的空間」、
        // overlay 畫到完全錯的位置。橫向（寬 > 高）即判定旋轉未生效：誠實回
        // 「無視覺觀測」的 FrameFacts（教練退化為只剩水平儀，而不是給錯座標）。
        guard bufferHeight >= bufferWidth else {
            // 無視覺觀測路徑：mask 也不得殘留（若曾發布過 → 清空一次）
            publishMaskClear()
            let (rollDeg, pitchDeg) = motionAngles(gravity: gravity, isFront: isFront)
            return FrameFacts(
                horizonRollDeg: rollDeg,
                cameraPitchDeg: pitchDeg,
                isFrontCamera: isFront,
                timestamp: timestamp
            )
        }

        // buffer 已直立（connection 轉 90°）→ orientation 一律 .up
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        var requests: [VNRequest] = [faceRectanglesRequest, faceLandmarksRequest]
        // 每 3 次分析跑一次 body pose（15fps 分析 → pose ~5fps；關節相對臉移動慢，夠用）
        let runBodyPose = poseEnabled && analysisCount % 3 == 1
        if runBodyPose {
            requests.append(bodyPoseRequest)
        }
        // perform 失敗（buffer 格式異常/資源壓力）時，重用的 request 物件的 .results
        // 仍保留「上一次成功帧」的觀測 — 不得當成本帧結果（座標可能已過時）。
        // 失敗 = 本帧無視覺觀測，與檔頭「橫向 buffer 誠實回退」同一原則。
        var visionOK = true
        do {
            try handler.perform(requests)
        } catch {
            visionOK = false
        }

        // compactMap-cast 寫法同時相容「typed results」與「[VNObservation]」兩種 SDK 型別
        let rectFaces = visionOK
            ? (faceRectanglesRequest.results ?? []).compactMap { $0 as? VNFaceObservation }
            : []
        let landmarkFaces = visionOK
            ? (faceLandmarksRequest.results ?? []).compactMap { $0 as? VNFaceObservation }
            : []
        // landmarks 請求的觀測自帶 bbox；完全沒有時退回 rectangles 結果
        let sourceFaces = landmarkFaces.isEmpty ? rectFaces : landmarkFaces
        // v0.5.0 群組偵測門檻：面積排序後，最大臉（index 0）無條件保留 —
        // 單人行為完全不變（不論其 confidence，跟過去一樣進 facts）；
        // 第 2 張臉起需 confidence 過門檻才算群組成員。低信心殘影不觸發群組
        // （union 主體框／GroupGuard／isGroupMode 全以 facts.faces.count ≥ 2
        // 判群組 — 門檻在此一處把關，下游語意自動一致）。上限仍為 3 張臉。
        let rankedFaces = sourceFaces.sorted {
            $0.boundingBox.width * $0.boundingBox.height
                > $1.boundingBox.width * $1.boundingBox.height
        }
        var topFaces: [VNFaceObservation] = []
        for (rank, observation) in rankedFaces.enumerated() {
            guard topFaces.count < 3 else { break }
            if rank == 0 || observation.confidence >= Self.groupFaceMinConfidence {
                topFaces.append(observation)
            }
        }

        var faces: [FaceFact] = []
        for (index, observation) in topFaces.enumerated() {
            var fact = faceFact(
                from: observation,
                rectangleCandidates: rectFaces,
                bufferWidth: bufferWidth,
                bufferHeight: bufferHeight
            )
            // 亮度取樣只做主要臉（最大臉；引擎的 primaryFace 也取最大臉）
            if index == 0, let halves = faceHalfBrightness(pixelBuffer: pixelBuffer, box: fact.box) {
                fact.leftBrightness = halves.left
                fact.rightBrightness = halves.right
            }
            faces.append(fact)
        }

        // Body pose：每 3 次一次，其餘沿用；停用時清空快取。
        // perform 失敗帧不讀過期 results — 沿用快取（同非 pose 帧語意）。
        var joints = lastJoints
        if runBodyPose, visionOK {
            joints = extractJoints()
            lastJoints = joints
        } else if !poseEnabled {
            joints = []
            lastJoints = []
        }

        // Saliency：無臉「持續 > 1s」才啟動（短暫掉臉不觸發），之後每 ~1s 跑一次，
        // 取第一個 salient object 當主體 fallback
        if faces.isEmpty {
            if noFaceSince == nil {
                noFaceSince = timestamp
            }
        } else {
            noFaceSince = nil
        }
        if faces.isEmpty,
           let since = noFaceSince, timestamp - since > 1.0,
           timestamp - lastSaliencyRunAt >= 1.0 {
            lastSaliencyRunAt = timestamp
            // perform 失敗 = 本帧無 saliency 觀測；不讀重用 request 的過期 results
            //（既有快取由 2.5s 時效自然淘汰）。
            do {
                try handler.perform([saliencyRequest])
                let salient = (saliencyRequest.results ?? [])
                    .compactMap { $0 as? VNSaliencyImageObservation }
                    .first?.salientObjects?.first
                if let salient {
                    let bb = salient.boundingBox
                    lastSaliencyBox = VisionCoordinateMapping.toNormalizedFrame(
                        visionRect: Double(bb.origin.x),
                        y: Double(bb.origin.y),
                        width: Double(bb.size.width),
                        height: Double(bb.size.height)
                    )
                    lastSaliencyHitAt = timestamp
                }
            } catch {}
        }

        // 場景分類（F12 調色推薦）：每 ~1s 一次（教練管線既有節奏內，不另開 timer）。
        // confidence > 0.3、confidence 高→低排序取前 5 個 identifier。
        // perform 失敗 = 本帧無分類觀測 → 清空快取（誠實原則；不讀重用 request
        // 的過期 results，同檔頭 Vision 失敗處理鐵律）。兩次分類之間沿用上次
        // 結果（場景變化慢，≤1s 陳舊可接受；切鏡/重置由 clearFrameCaches 清）。
        if timestamp - lastClassifyAt >= 1.0 {
            lastClassifyAt = timestamp
            do {
                try handler.perform([classifyRequest])
                lastSceneTags = (classifyRequest.results ?? [])
                    .compactMap { $0 as? VNClassificationObservation }
                    .filter { $0.confidence > 0.3 }
                    .sorted { $0.confidence > $1.confidence }
                    .prefix(5)
                    .map { $0.identifier }
            } catch {
                lastSceneTags = []
            }
        }

        // 人像分割（v0.5.0 特效 mask）：節奏／開關／熱降級判斷見函式注釋。
        // 放在 faces 之後 — personCount 由本帧臉數帶入（契約）。
        runSegmentationIfDue(pixelBuffer: pixelBuffer, timestamp: timestamp, faceCount: faces.count)

        let subjectBox = makeSubjectBox(faces: faces, joints: joints, timestamp: timestamp)
        let histogram = makeHistogram(pixelBuffer: pixelBuffer)
        let (rollDeg, pitchDeg) = motionAngles(gravity: gravity, isFront: isFront)

        return FrameFacts(
            faces: faces,
            joints: joints,
            subjectBox: subjectBox,
            horizonRollDeg: rollDeg,
            cameraPitchDeg: pitchDeg,
            subjectDistanceM: nil,          // P2 尚無深度來源，誠實回 nil
            histogram: histogram,
            sceneTags: lastSceneTags,       // VNClassifyImageRequest（每 ~1s 更新）
            isFrontCamera: isFront,
            timestamp: timestamp
        )
    }

    /// 清跨帧快取（只在 analysisQueue 上呼叫）。analysisCount 歸零 →
    /// 下一帧 analysisCount % 3 == 1 立即重跑 body pose。
    private func clearFrameCaches() {
        analysisCount = 0
        lastJoints = []
        lastSaliencyBox = nil
        lastSaliencyRunAt = -.greatestFiniteMagnitude
        lastSaliencyHitAt = -.greatestFiniteMagnitude
        noFaceSince = nil
        lastClassifyAt = -.greatestFiniteMagnitude
        lastSceneTags = []
        // 切鏡/翻鏡 = mask 座標空間跳變 → 立即清空 MaskStore（不留舊空間 mask
        // 給合成端多畫 1–2 tick 的錯位特效）。maskSequence 不歸零（單調防亂序）。
        publishMaskClear()
    }

    // MARK: - 人像分割（v0.5.0 特效 mask；只在 analysisQueue 呼叫）

    /// 分割節奏守門：
    /// - effect.selected == "none" 或 effect.liveEnabled 關 → 零 Vision 呼叫
    ///   （若曾發布過 mask → 清空一次）。liveEnabled 預設 true（契約）。
    /// - look.livePreview 關（Metal 取景器退回 PreviewLayerView）→ live mask
    ///   無任何消費者（拍照烘焙走 accurateMask）→ 同樣停跑＋清空（v0.5.0 修正輪；
    ///   metalFailed 屬 App 層 @State 無法直讀，罕見路徑不覆蓋）。
    /// - 熱降級 ≥ .serious → 停跑 + 清空（直讀 thermalState，不依賴 MainActor
    ///   通知時序 — 與 CoachPipeline.runModelTickIfDue 同判準）。
    /// - 每 2 次分析 tick 跑一次（15fps 分析 → mask ~7fps；mask 是低頻輔助層，
    ///   合成端拿最近一張即可，取景不因此掉帧）。
    /// - liveMask 失敗（perform throw）→ 沿用已發布 mask（短暫失敗不閃爍；
    ///   長期失敗 = mask 陳舊 — 時效防護在「渲染端」：MetalPreviewView.draw 以
    ///   MaskStore.publishedAt 做 0.5s 時效判定，陳舊 mask 自然熄滅，本處不重複）。
    private func runSegmentationIfDue(pixelBuffer: CVPixelBuffer, timestamp: Double, faceCount: Int) {
        guard segmentationGateOpen() else { return }
        guard analysisCount % 2 == 0 else { return }
        performSegmentation(pixelBuffer: pixelBuffer, timestamp: timestamp, faceCount: faceCount)
    }

    /// v0.5.0 修正輪：教練分析「未啟用」時的獨立分割入口（拍照等模式的取景
    /// 即時特效 — 分割節奏不能只綁在教練 analyze，否則主拍照模式選特效時
    /// MaskStore 永遠拿不到 mask、預覽整條斷路）。VideoFrameTap 在「有預覽
    /// 消費者」的帧上呼叫（analysisQueue — 與 analyze 同 serial queue，
    /// 狀態不跨執行緒）。節流 0.15s ≈ 7fps，與教練路徑同節奏。
    /// faceCount：本路徑無臉部觀測 → 0（MaskStore.personCount 目前無讀取端，
    /// 語意為「最近一次發布時的已知偵測人數」）。
    func runStandaloneSegmentationIfDue(pixelBuffer: CVPixelBuffer, timestamp: Double) {
        guard segmentationGateOpen() else { return }
        guard timestamp - lastStandaloneSegmentationAt >= 0.15 else { return }
        lastStandaloneSegmentationAt = timestamp
        performSegmentation(pixelBuffer: pixelBuffer, timestamp: timestamp, faceCount: 0)
    }

    /// 分割守門共用判定（analysisQueue）：開關／取景器可見性／熱降級。
    /// 任一不滿足 → 清空一次（僅曾發布過時）並回 false。
    private func segmentationGateOpen() -> Bool {
        // @AppStorage 在非 View 不可靠 → 直讀 UserDefaults（CoachPipeline 同慣例）
        let defaults = UserDefaults.standard
        let selected = defaults.string(forKey: "effect.selected") ?? "none"
        let liveEnabled = (defaults.object(forKey: "effect.liveEnabled") as? Bool) ?? true
        let livePreview = (defaults.object(forKey: "look.livePreview") as? Bool) ?? true
        guard selected != "none", liveEnabled, livePreview else {
            publishMaskClear()
            return false
        }
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious, thermal != .critical else {
            publishMaskClear()
            return false
        }
        return true
    }

    /// 實際分割＋發布（analysisQueue；守門通過後呼叫）。
    private func performSegmentation(pixelBuffer: CVPixelBuffer, timestamp: Double, faceCount: Int) {
        guard let mask = segmentation.liveMask(for: pixelBuffer) else { return }

        maskPublished = true
        maskSequence += 1
        let sequence = maskSequence
        // mask buffer 跨執行緒轉手：Vision 每次 perform 產新 buffer、回傳後無人
        // 再寫入 → 實質唯讀轉移（Swift 5 模式 Sendable 僅警告；MaskStore 檔頭注釋）。
        Task { @MainActor in
            MaskStore.shared.apply(
                mask: mask, timestamp: timestamp, personCount: faceCount, sequence: sequence
            )
        }
    }

    /// MaskStore 清空（僅在曾發布過時發一次 nil；analysisQueue 專屬）。
    private func publishMaskClear() {
        guard maskPublished else { return }
        maskPublished = false
        maskSequence += 1
        let sequence = maskSequence
        Task { @MainActor in
            MaskStore.shared.apply(mask: nil, timestamp: 0, personCount: 0, sequence: sequence)
        }
    }

    // MARK: - 臉

    private func faceFact(
        from observation: VNFaceObservation,
        rectangleCandidates: [VNFaceObservation],
        bufferWidth: Int,
        bufferHeight: Int
    ) -> FaceFact {
        let bb = observation.boundingBox
        let box = VisionCoordinateMapping.toNormalizedFrame(
            visionRect: Double(bb.origin.x),
            y: Double(bb.origin.y),
            width: Double(bb.size.width),
            height: Double(bb.size.height)
        )

        // yaw / pitch：landmarks 請求的觀測可能不帶 → 用 IoU 最大的 rectangles 觀測補。
        // Vision yaw 弧度、右手座標系（x 右、y 上）→ 正 yaw = 臉朝畫面右緣，
        // 與 FaceFact 契約一致；前鏡 buffer 已鏡像，語意自動維持螢幕空間。（符號待真機驗證）
        var yawRad = observation.yaw?.doubleValue
        var pitchRad = observation.pitch?.doubleValue
        if yawRad == nil || pitchRad == nil,
           let match = bestIoUMatch(for: observation, in: rectangleCandidates) {
            if yawRad == nil { yawRad = match.yaw?.doubleValue }
            if pitchRad == nil { pitchRad = match.pitch?.doubleValue }
        }

        // landmarks normalizedPoints 是「臉框內」座標（0…1、y 向上）：
        // 像素尺度 = 區域內差值 × 臉框 normalized 尺寸 × buffer 像素尺寸（修正長寬比失真）
        let pxScaleX = Double(bb.size.width) * Double(bufferWidth)
        let pxScaleY = Double(bb.size.height) * Double(bufferHeight)

        var leftEyeOpen: Double?
        var rightEyeOpen: Double?
        var smile: Double?
        if let landmarks = observation.landmarks {
            leftEyeOpen = landmarks.leftEye.flatMap {
                eyeOpenness(region: $0, pxScaleX: pxScaleX, pxScaleY: pxScaleY)
            }
            rightEyeOpen = landmarks.rightEye.flatMap {
                eyeOpenness(region: $0, pxScaleX: pxScaleX, pxScaleY: pxScaleY)
            }
            smile = landmarks.outerLips.flatMap {
                smileAmount(region: $0, pxScaleX: pxScaleX, pxScaleY: pxScaleY)
            }
        }

        return FaceFact(
            box: box,
            leftEyeOpen: leftEyeOpen,
            rightEyeOpen: rightEyeOpen,
            smile: smile,
            yawDeg: yawRad.map { $0 * 180 / .pi },
            pitchDeg: pitchRad.map { $0 * 180 / .pi }
        )
    }

    /// EAR（眼睛縱橫比）→ 睜眼度 0…1。
    /// 眼輪廓點 bbox 的「像素高/寬」比：閉眼 ≲0.12 → 0、睜眼 ≳0.30 → 1、之間線性內插
    /// （Soukupová–Čech EAR ≈0.2 分界的保守外擴；門檻為啟發式，待真機微調）。
    private func eyeOpenness(
        region: VNFaceLandmarkRegion2D, pxScaleX: Double, pxScaleY: Double
    ) -> Double? {
        let points = region.normalizedPoints
        guard points.count >= 4 else { return nil }
        let xs = points.map { Double($0.x) }
        let ys = points.map { Double($0.y) }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let widthPx = (maxX - minX) * pxScaleX
        let heightPx = (maxY - minY) * pxScaleY
        guard widthPx > 0 else { return nil }
        let ear = heightPx / widthPx
        let closedEAR = 0.12
        let openEAR = 0.30
        return min(1, max(0, (ear - closedEAR) / (openEAR - closedEAR)))
    }

    /// 微笑度 0…1（粗略、保守）：嘴角相對外唇點集中心的上揚量 ÷ 嘴寬（皆像素校正）。
    /// landmarks 座標 y 向上 → 嘴角 y 高於中心 = 上揚。r = uplift/width，
    /// 映射 smile = clamp(r / 0.12)：中性 r≈0 → 0、明顯微笑 r≈0.06 → 0.5、大笑 ≥0.12 → 1。
    /// 門檻為啟發式，待真機微調（自動抓拍需 smile > 0.4，寧可低估不誤觸發）。
    private func smileAmount(
        region: VNFaceLandmarkRegion2D, pxScaleX: Double, pxScaleY: Double
    ) -> Double? {
        let points = region.normalizedPoints
        guard points.count >= 4 else { return nil }
        guard let leftCorner = points.min(by: { $0.x < $1.x }),
              let rightCorner = points.max(by: { $0.x < $1.x }) else { return nil }
        let xs = points.map { Double($0.x) }
        guard let minX = xs.min(), let maxX = xs.max() else { return nil }
        let widthPx = (maxX - minX) * pxScaleX
        guard widthPx > 0 else { return nil }
        let centerY = points.reduce(0.0) { $0 + Double($1.y) } / Double(points.count)
        let cornerY = (Double(leftCorner.y) + Double(rightCorner.y)) / 2
        let upliftPx = (cornerY - centerY) * pxScaleY
        let r = upliftPx / widthPx
        return min(1, max(0, r / 0.12))
    }

    /// 同一張臉配對：Vision 空間 bbox IoU 最大且 > 0.2 者。
    private func bestIoUMatch(
        for observation: VNFaceObservation, in candidates: [VNFaceObservation]
    ) -> VNFaceObservation? {
        var best: (observation: VNFaceObservation, iou: CGFloat)?
        for candidate in candidates {
            let iou = Self.iou(observation.boundingBox, candidate.boundingBox)
            if iou > (best?.iou ?? 0.2) {
                best = (candidate, iou)
            }
        }
        return best?.observation
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    // MARK: - Body pose

    private static let jointMap: [VNHumanBodyPoseObservation.JointName: JointName] = [
        .nose: .head, .neck: .neck,
        .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
        .leftElbow: .leftElbow, .rightElbow: .rightElbow,
        .leftWrist: .leftWrist, .rightWrist: .rightWrist,
        .leftHip: .leftHip, .rightHip: .rightHip,
        .leftKnee: .leftKnee, .rightKnee: .rightKnee,
        .leftAnkle: .leftAnkle, .rightAnkle: .rightAnkle
    ]

    /// 第一個人的關節點 → JointFact（confidence 帶過去；< 0.1 的雜訊點不進快照，
    /// 規則層另有自己的 ≥ 0.3 門檻）。
    private func extractJoints() -> [JointFact] {
        guard let observation = (bodyPoseRequest.results ?? [])
            .compactMap({ $0 as? VNHumanBodyPoseObservation })
            .first,
            let points = try? observation.recognizedPoints(.all)
        else { return [] }

        var result: [JointFact] = []
        for (visionName, coreName) in Self.jointMap {
            guard let point = points[visionName], point.confidence > 0.1 else { continue }
            let np = VisionCoordinateMapping.toNormalizedFrame(
                visionPoint: Double(point.location.x),
                y: Double(point.location.y)
            )
            result.append(JointFact(name: coreName, point: np, confidence: Double(point.confidence)))
        }
        return result
    }

    // MARK: - 主體框

    /// 主體框（人優先）：
    /// - v0.5.0 群組（≥2 張過信心門檻的臉）：所有臉框 union 各邊外擴 15% 後
    ///   clamp 0…1（整群 = 主體；TargetSolver 據此把導引錨點換成整群中心）。
    ///   群組時「不」混入關節點 — body pose 只支援單人（見 extractJoints），
    ///   單人骨架拉伸 union 會把整群框偏向其中一人。
    /// - 單人：主要臉框 ∪ 可信關節點（≥0.3）bbox，左右各外擴 2%、下緣 +4%
    ///   （關節點不含腳掌）後 clamp 0…1。只有臉、沒有可信關節時「不」憑空造主體框 —
    ///   引擎的占比規則會自然回「不適用」（誠實原則）。無臉時用 2.5s 內的 saliency 框。
    private func makeSubjectBox(
        faces: [FaceFact], joints: [JointFact], timestamp: Double
    ) -> NRect? {
        if faces.count >= 2 {
            return Self.groupUnionBox(faces: faces)
        }
        if let face = faces.max(by: { $0.box.area < $1.box.area }) {
            let confident = joints.filter { $0.confidence >= 0.3 }
            guard !confident.isEmpty else { return nil }
            var minX = face.box.minX
            var maxX = face.box.maxX
            let minY = face.box.minY
            var maxY = face.box.maxY
            for joint in confident {
                minX = min(minX, joint.point.x)
                maxX = max(maxX, joint.point.x)
                maxY = max(maxY, joint.point.y)
            }
            minX = max(0, minX - 0.02)
            maxX = min(1, maxX + 0.02)
            maxY = min(1, maxY + 0.04)
            guard maxX > minX, maxY > minY else { return nil }
            return NRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        if let box = lastSaliencyBox, timestamp - lastSaliencyHitAt <= 2.5 {
            return box
        }
        return nil
    }

    /// v0.5.0 群組主體框：所有臉框 union，四邊各外擴「union 對應邊長的 15%」
    /// 後 clamp 0…1。外擴理由：臉框只涵蓋頭部 — 15% 把髮頂／肩線一帶納入，
    /// 讓占比（subjectSize）與三分／置中規則拿到更接近「整群人」的框；
    /// 只有臉觀測、沒有全群骨架，任何更大的外擴都是猜身體（誠實原則：
    /// 寧可保守），寬幅合照時也不至於把大片背景吃進主體框。
    private static func groupUnionBox(faces: [FaceFact]) -> NRect {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for face in faces {
            minX = min(minX, face.box.minX)
            minY = min(minY, face.box.minY)
            maxX = max(maxX, face.box.maxX)
            maxY = max(maxY, face.box.maxY)
        }
        let dx = (maxX - minX) * 0.15
        let dy = (maxY - minY) * 0.15
        let x0 = max(0, minX - dx)
        let y0 = max(0, minY - dy)
        let x1 = min(1, maxX + dx)
        let y1 = min(1, maxY + dy)
        return NRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    // MARK: - 像素統計（自寫取樣，不用 vImage 以避 API 風險）

    /// 全帧亮度直方圖：格點取樣 ~4000 點 → LumaHistogram 64 bins（總和 = 1）。
    /// 僅支援 kCVPixelFormatType_32BGRA（記憶體序 B,G,R,A）；其他格式回 nil（成分不適用）。
    private func makeHistogram(pixelBuffer: CVPixelBuffer) -> LumaHistogram? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        let step = max(1, Int((Double(width * height) / 4000.0).squareRoot()))
        var bins = [Double](repeating: 0, count: 64)
        var count = 0.0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let luma = Self.luma(base: base, bytesPerRow: bytesPerRow, x: x, y: y)
                bins[min(63, Int(luma * 64))] += 1
                count += 1
                x += step
            }
            y += step
        }
        guard count > 0 else { return nil }
        for i in 0..<bins.count {
            bins[i] /= count
        }
        return LumaHistogram(bins: bins)
    }

    /// 臉框左右半平均亮度（以「畫面左右」為準；前鏡 buffer 已鏡像 = 螢幕方向）。
    /// NormalizedFrame y 向下與像素列一致 → 直接乘寬高取樣；每半 14×14 ≈ 196 點。
    private func faceHalfBrightness(
        pixelBuffer: CVPixelBuffer, box: NRect
    ) -> (left: Double, right: Double)? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        let x0 = min(max(box.minX, 0), 1)
        let x1 = min(max(box.maxX, 0), 1)
        let y0 = min(max(box.minY, 0), 1)
        let y1 = min(max(box.maxY, 0), 1)
        guard x1 - x0 > 0.01, y1 - y0 > 0.01 else { return nil }
        let midX = (x0 + x1) / 2

        func averageLuma(fromX: Double, toX: Double) -> Double {
            let grid = 14
            var sum = 0.0
            for iy in 0..<grid {
                for ix in 0..<grid {
                    let nx = fromX + (toX - fromX) * (Double(ix) + 0.5) / Double(grid)
                    let ny = y0 + (y1 - y0) * (Double(iy) + 0.5) / Double(grid)
                    let px = min(width - 1, max(0, Int(nx * Double(width))))
                    let py = min(height - 1, max(0, Int(ny * Double(height))))
                    sum += Self.luma(base: base, bytesPerRow: bytesPerRow, x: px, y: py)
                }
            }
            return sum / Double(grid * grid)
        }

        return (left: averageLuma(fromX: x0, toX: midX), right: averageLuma(fromX: midX, toX: x1))
    }

    /// 32BGRA：byte0=B、byte1=G、byte2=R、byte3=A。近似 luma = (0.299R + 0.587G + 0.114B)/255。
    private static func luma(base: UnsafeRawPointer, bytesPerRow: Int, x: Int, y: Int) -> Double {
        let pixel = base.advanced(by: y * bytesPerRow + x * 4)
        let b = Double(pixel.load(fromByteOffset: 0, as: UInt8.self))
        let g = Double(pixel.load(fromByteOffset: 1, as: UInt8.self))
        let r = Double(pixel.load(fromByteOffset: 2, as: UInt8.self))
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
    }

    // MARK: - CoreMotion → 角度

    /// 重力向量 → 水平滾轉 / 相機俯仰。無 motion 資料時回 (0, 0)。
    ///
    /// 推導（裝置座標，portrait：x = 螢幕右、y = 螢幕上、z = 出螢幕朝使用者）：
    /// - 直立持機時 gravity ≈ (0, −1, 0)。
    /// - roll：裝置順時針滾轉 θ（頂端往右倒）→ x 軸轉向下方 → gravity.x = sinθ、
    ///   gravity.y ≈ −cosθ，故 horizonRollDeg = atan2(gx, −gy)；直立 = 0、頂端往右倒為正。
    ///   前鏡不翻：實體傾斜與鏡像無關（鏡像只翻影像 x，不改變重力）。
    /// - pitch：後鏡光軸 = −z。拍天空時螢幕面朝下對著使用者 → gravity 在 +z 分量變正；
    ///   平持（拍地平線）gz ≈ 0；螢幕朝上平放（相機朝地）gz = −1。
    ///   cameraPitchDeg = atan2(gz, √(gx²+gy²))：朝上仰為正（拍天 +90、拍地 −90）。
    ///   前鏡光軸 = +z，方向相反 → 取負。
    private func motionAngles(
        gravity: CMAcceleration?, isFront: Bool
    ) -> (roll: Double, pitch: Double) {
        guard let g = gravity else { return (0, 0) }
        let rollRad = atan2(g.x, -g.y)
        let horizontal = (g.x * g.x + g.y * g.y).squareRoot()
        var pitchRad = atan2(g.z, horizontal)
        if isFront {
            pitchRad = -pitchRad
        }
        return (rollRad * 180 / .pi, pitchRad * 180 / .pi)
    }
}
