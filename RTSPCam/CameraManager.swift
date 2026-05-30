import AVFoundation
import VideoToolbox
import CoreMedia
import os.log

final class CameraManager: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var fps: Double = 0
    @Published var resolution: String = ""
    @Published var bitrateMbps: Double = 0

    var onNAL: ((_ data: Data, _ pts: CMTime, _ isKeyframe: Bool) -> Void)?
    var onSPSPPS: ((_ sps: Data, _ pps: Data) -> Void)?
    var onPreviewLayer: ((_ layer: AVCaptureVideoPreviewLayer) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInteractive)
    private var encoder: VTCompressionSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    private var frameCount = 0
    private var lastFPSTime = CACurrentMediaTime()
    private var bytesSent = 0
    private var lastBitrateTime = CACurrentMediaTime()

    var targetBitrate: Int = 4_000_000
    var targetFPS: Int32 = 30

    private let logger = Logger(subsystem: "RTSPCam", category: "Camera")

    func start() {
        sessionQueue.async { [weak self] in
            self?.configureSession()
            self?.session.startRunning()
            DispatchQueue.main.async { self?.isRunning = true }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            self?.destroyEncoder()
            DispatchQueue.main.async { self?.isRunning = false }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720  // 720p — more reliable on iPhone 11

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            logger.error("No camera found")
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            logger.error("Camera input error: \(error)")
            session.commitConfiguration()
            return
        }

        configureFrameRate(device: device, fps: targetFPS)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(output) { session.addOutput(output) }

        if let conn = output.connection(with: .video) {
            if #available(iOS 17.0, *) {
                conn.videoRotationAngle = 90
            } else {
                conn.videoOrientation = .portrait
            }
        }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer
        DispatchQueue.main.async { [weak self] in
            guard let self, let layer = self.previewLayer else { return }
            self.onPreviewLayer?(layer)
        }

        session.commitConfiguration()
        DispatchQueue.main.async { self.resolution = "1280×720" }
        setupEncoder(width: 1280, height: 720)
    }

    private func configureFrameRate(device: AVCaptureDevice, fps: Int32) {
        try? device.lockForConfiguration()
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    private func setupEncoder(width: Int32, height: Int32) {
        destroyEncoder()
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encoderOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            logger.error("Failed to create VT session: \(status)")
            return
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: targetFPS as CFNumber)
        // Force a keyframe every 2 seconds so SPS/PPS refresh often
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Int32(targetFPS * 2) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        logger.info("H264 encoder ready (\(width)x\(height) @ \(self.targetFPS)fps)")
    }

    private func destroyEncoder() {
        guard let enc = encoder else { return }
        VTCompressionSessionInvalidate(enc)
        encoder = nil
    }

    private let encoderOutputCallback: VTCompressionOutputCallback = { refcon, _, status, flags, sampleBuffer in
        guard status == noErr, let refcon, let sampleBuffer,
              CMSampleBufferIsValid(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let manager = Unmanaged<CameraManager>.fromOpaque(refcon).takeUnretainedValue()

        // FIX: correct keyframe check via sample buffer attachment (VTEncodeInfoFlags.notSync is not public API)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let dependsOnOthers = attachments?.first?[kCMSampleAttachmentKey_DependsOnOthers] as? Bool
        let isKeyframe = dependsOnOthers != true
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            manager.extractSPSPPS(from: formatDesc)
        }

        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &dataLength, dataPointerOut: &dataPointer)
        if let ptr = dataPointer, dataLength > 0 {
            manager.parseAVCC(Data(bytes: ptr, count: dataLength), pts: pts, isKeyframe: isKeyframe)
        }

        manager.bytesSent += dataLength
        let now = CACurrentMediaTime()
        if now - manager.lastBitrateTime >= 1.0 {
            let mbps = Double(manager.bytesSent * 8) / ((now - manager.lastBitrateTime) * 1_000_000)
            manager.bytesSent = 0
            manager.lastBitrateTime = now
            DispatchQueue.main.async { manager.bitrateMbps = mbps }
        }
    }

    private func extractSPSPPS(from format: CMFormatDescription) {
        var spsOut: UnsafePointer<UInt8>?
        var spsLen = 0
        var ppsOut: UnsafePointer<UInt8>?
        var ppsLen = 0
        var nalSize: Int32 = 0

        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: &spsOut, parameterSetSizeOut: &spsLen,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: &nalSize)
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsOut, parameterSetSizeOut: &ppsLen,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

        if let s = spsOut, let p = ppsOut {
            let sps = Data(bytes: s, count: spsLen)
            let pps = Data(bytes: p, count: ppsLen)
            // Fire on main thread for observers, and also notify server directly
            DispatchQueue.main.async { [weak self] in self?.onSPSPPS?(sps, pps) }
        }
    }

    private func parseAVCC(_ data: Data, pts: CMTime, isKeyframe: Bool) {
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        var offset = 0
        while offset + 4 <= data.count {
            let length = data.withUnsafeBytes { buf -> Int in
                Int(CFSwapInt32BigToHost(buf.baseAddress!.advanced(by: offset).load(as: UInt32.self)))
            }
            offset += 4
            guard offset + length <= data.count else { break }
            var nal = startCode
            nal.append(data[offset..<(offset + length)])
            onNAL?(nal, pts, isKeyframe)
            offset += length
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let enc = encoder,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(enc, imageBuffer: pixelBuffer,
                                        presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
        frameCount += 1
        let now = CACurrentMediaTime()
        if now - lastFPSTime >= 1.0 {
            let fps = Double(frameCount) / (now - lastFPSTime)
            frameCount = 0; lastFPSTime = now
            DispatchQueue.main.async { [weak self] in self?.fps = fps }
        }
    }
}
