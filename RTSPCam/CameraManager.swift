import AVFoundation
import VideoToolbox
import CoreMedia
import os.log

// MARK: - Camera Manager
// Captures camera frames, encodes to H264 using VideoToolbox (hardware),
// then fires callbacks with raw NAL units for the RTSP server.

final class CameraManager: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var fps: Double = 0
    @Published var resolution: String = ""
    @Published var bitrateMbps: Double = 0

    // Callbacks
    var onNAL: ((_ data: Data, _ pts: CMTime, _ isKeyframe: Bool) -> Void)?
    var onSPSPPS: ((_ sps: Data, _ pps: Data) -> Void)?
    var onPreviewLayer: ((_ layer: AVCaptureVideoPreviewLayer) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInteractive)
    private var videoOutput: AVCaptureVideoDataOutput?
    private var encoder: VTCompressionSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    // Stats
    private var frameCount = 0
    private var lastFPSTime = CACurrentMediaTime()
    private var bytesSent = 0
    private var lastBitrateTime = CACurrentMediaTime()

    // Config
    var targetBitrate: Int = 4_000_000   // 4 Mbps default
    var targetFPS: Int32 = 30
    var useWideCamera: Bool = false

    private let logger = Logger(subsystem: "RTSPCam", category: "Camera")

    // MARK: - Start
    func start() {
        sessionQueue.async { [weak self] in
            self?.configureSession()
            self?.session.startRunning()
            DispatchQueue.main.async {
                self?.isRunning = true
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            self?.destroyEncoder()
            DispatchQueue.main.async {
                self?.isRunning = false
            }
        }
    }

    // MARK: - Session Setup
    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        // Input
        let cameraPosition: AVCaptureDevice.Position = .back
        guard let device = bestCamera(position: cameraPosition) else {
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

        // Configure frame rate
        configureFrameRate(device: device, fps: targetFPS)

        // Output
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        videoOutput = output

        // Set video orientation
        if let conn = output.connection(with: .video) {
            conn.videoRotationAngle = 90 // portrait
        }

        // Preview layer (created on main thread)
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer
        DispatchQueue.main.async { [weak self] in
            guard let self, let layer = self.previewLayer else { return }
            self.onPreviewLayer?(layer)
        }

        session.commitConfiguration()

        // Resolution string
        DispatchQueue.main.async { [weak self] in
            self?.resolution = "1920×1080"
        }

        // Start encoder
        setupEncoder(width: 1920, height: 1080)
    }

    private func bestCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // Prefer dual wide, fall back to wide angle
        if useWideCamera,
           let d = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position) {
            return d
        }
        if let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            return d
        }
        return AVCaptureDevice.default(for: .video)
    }

    private func configureFrameRate(device: AVCaptureDevice, fps: Int32) {
        try? device.lockForConfiguration()
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        for format in device.formats {
            let ranges = format.videoSupportedFrameRateRanges
            if ranges.contains(where: { $0.maxFrameRate >= Double(fps) }) {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                break
            }
        }
        device.unlockForConfiguration()
    }

    // MARK: - VideoToolbox H264 Encoder
    private func setupEncoder(width: Int32, height: Int32) {
        destroyEncoder()

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
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
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: targetFPS as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Int32(targetFPS * 2) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)

        // Enable hardware encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, value: kCFBooleanTrue)

        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        logger.info("H264 encoder ready (\(width)x\(height) @ \(self.targetFPS)fps, \(self.targetBitrate/1000)kbps)")
    }

    private func destroyEncoder() {
        guard let enc = encoder else { return }
        VTCompressionSessionInvalidate(enc)
        encoder = nil
    }

    // MARK: - Encoder Output Callback (C function)
    private let encoderOutputCallback: VTCompressionOutputCallback = { refcon, _, status, flags, sampleBuffer in
        guard status == noErr,
              let refcon,
              let sampleBuffer,
              CMSampleBufferIsValid(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let manager = Unmanaged<CameraManager>.fromOpaque(refcon).takeUnretainedValue()
        let isKeyframe = !((flags.contains(.frameDropped)) || (flags.contains(.notSync)))
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Extract SPS/PPS from keyframe format description
        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            manager.extractSPSPPS(from: formatDesc)
        }

        // Get raw NAL data
        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)

        if let ptr = dataPointer, dataLength > 0 {
            let rawData = Data(bytes: ptr, count: dataLength)
            // Parse AVCC format (4-byte length prefix) → convert to Annex B
            manager.parseAVCC(rawData, pts: pts, isKeyframe: isKeyframe)
        }

        // Bitrate stats
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
        var nalSize = 0

        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &spsOut, parameterSetSizeOut: &spsLen, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &nalSize)
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1, parameterSetPointerOut: &ppsOut, parameterSetSizeOut: &ppsLen, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

        if let s = spsOut, let p = ppsOut {
            let sps = Data(bytes: s, count: spsLen)
            let pps = Data(bytes: p, count: ppsLen)
            DispatchQueue.main.async { [weak self] in
                self?.onSPSPPS?(sps, pps)
            }
        }
    }

    // Convert AVCC (length-prefixed) to Annex B (start-code-prefixed) NALs
    private func parseAVCC(_ data: Data, pts: CMTime, isKeyframe: Bool) {
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        var offset = 0
        while offset + 4 <= data.count {
            let length = data.withUnsafeBytes { buf -> Int in
                let ptr = buf.baseAddress!.advanced(by: offset)
                return Int(CFSwapInt32BigToHost(ptr.load(as: UInt32.self)))
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

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let enc = encoder,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(enc, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)

        // FPS counter
        frameCount += 1
        let now = CACurrentMediaTime()
        if now - lastFPSTime >= 1.0 {
            let fps = Double(frameCount) / (now - lastFPSTime)
            frameCount = 0
            lastFPSTime = now
            DispatchQueue.main.async { [weak self] in self?.fps = fps }
        }
    }
}
