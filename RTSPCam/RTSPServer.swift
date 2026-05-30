import Foundation
import Network
import CoreMedia
import os.log

// MARK: - RTSP Server
final class RTSPServer {
    static let port: UInt16 = 8554
    private var listener: NWListener?
    private var clients: [RTSPClient] = []
    private let queue = DispatchQueue(label: "rtsp.server", qos: .userInteractive)
    private let logger = Logger(subsystem: "RTSPCam", category: "RTSPServer")

    // Stored at server level so new clients immediately get the latest params
    private var latestSPS: Data?
    private var latestPPS: Data?

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }
        listener?.start(queue: queue)
        logger.info("RTSP server listening on port \(Self.port)")
    }

    func stop() {
        listener?.cancel()
        clients.forEach { $0.close() }
        clients.removeAll()
    }

    /// Called by CameraManager when a new keyframe SPS/PPS pair is extracted
    func updateSPSPPS(sps: Data, pps: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.latestSPS = sps
            self.latestPPS = pps
            // Push updated params to all connected clients
            self.clients.forEach {
                $0.sps = sps
                $0.pps = pps
            }
            self.logger.info("SPS/PPS updated (\(sps.count) / \(pps.count) bytes)")
        }
    }

    func sendNAL(_ data: Data, pts: CMTime, isKeyframe: Bool) {
        queue.async { [weak self] in
            self?.clients.forEach { $0.sendNAL(data, pts: pts, isKeyframe: isKeyframe) }
        }
    }

    private func handleNewConnection(_ conn: NWConnection) {
        let client = RTSPClient(connection: conn, serverPort: Self.port)
        // Pass any already-known SPS/PPS so DESCRIBE works immediately
        client.sps = latestSPS
        client.pps = latestPPS
        client.onClose = { [weak self] in
            self?.queue.async {
                self?.clients.removeAll { $0 === client }
            }
        }
        clients.append(client)
        client.start()
        logger.info("New RTSP client. Total: \(self.clients.count)")
    }
}

// MARK: - RTSP Client Session
final class RTSPClient {
    private let connection: NWConnection
    private let serverPort: UInt16
    private let queue = DispatchQueue(label: "rtsp.client", qos: .userInteractive)
    private let logger = Logger(subsystem: "RTSPCam", category: "RTSPClient")

    private var rtpSocket: Int32 = -1
    private var clientRTPPort: UInt16 = 0
    private var clientHost: String = ""
    private var serverRTPPort: UInt16 = 0
    private var rtpSeq: UInt16 = 0
    private var ssrc: UInt32 = UInt32.random(in: 0..<UInt32.max)
    private var playing = false
    private var receivedBuffer = Data()
    private var cseq = 0

    var sps: Data?
    var pps: Data?
    var onClose: (() -> Void)?

    init(connection: NWConnection, serverPort: UInt16) {
        self.connection = connection
        self.serverPort = serverPort
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    func close() {
        connection.cancel()
        if rtpSocket != -1 { Darwin.close(rtpSocket); rtpSocket = -1 }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.receivedBuffer.append(data) }
            self.parseRTSPRequests()
            if isComplete || error != nil { self.close(); self.onClose?() }
            else { self.receive() }
        }
    }

    private func parseRTSPRequests() {
        while let range = receivedBuffer.range(of: Data("\r\n\r\n".utf8)) {
            let requestData = receivedBuffer[..<range.upperBound]
            receivedBuffer = receivedBuffer[range.upperBound...]
            if let text = String(data: requestData, encoding: .utf8) { handleRequest(text) }
        }
    }

    private func handleRequest(_ text: String) {
        let lines = text.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        let method = parts[0]
        for line in lines {
            if line.lowercased().hasPrefix("cseq:") {
                cseq = Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) ?? cseq
            }
        }
        logger.debug("RTSP \(method)")
        switch method {
        case "OPTIONS":
            sendResponse("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nPublic: OPTIONS, DESCRIBE, SETUP, TEARDOWN, PLAY\r\n\r\n")

        case "DESCRIBE":
            // If SPS/PPS aren't ready yet (camera just started), wait up to 2s for them.
            // This avoids sending an SDP without sprop-parameter-sets which crashes ffmpeg.
            if sps == nil {
                let deadline = DispatchTime.now() + .milliseconds(2000)
                let waitResult = DispatchSemaphore(value: 0)
                // Poll every 50ms
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(50))
                timer.setEventHandler { [weak self] in
                    if self?.sps != nil { waitResult.signal(); timer.cancel() }
                }
                timer.resume()
                _ = waitResult.wait(timeout: deadline)
                timer.cancel()
            }
            let sdp = buildSDP()
            let len = sdp.data(using: .utf8)!.count
            sendResponse("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nContent-Type: application/sdp\r\nContent-Length: \(len)\r\n\r\n\(sdp)")

        case "SETUP":
            for line in lines { if line.lowercased().hasPrefix("transport:") { parseTransport(line) } }
            serverRTPPort = UInt16.random(in: 5000..<6000) * 2
            openRTPSocket()
            sendResponse("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nTransport: RTP/AVP;unicast;client_port=\(clientRTPPort)-\(clientRTPPort+1);server_port=\(serverRTPPort)-\(serverRTPPort+1)\r\nSession: 1\r\n\r\n")

        case "PLAY":
            playing = true
            sendResponse("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nSession: 1\r\nRTP-Info: url=rtsp://\(clientHost)/live/streamid=0;seq=\(rtpSeq);rtptime=0\r\n\r\n")

        case "TEARDOWN":
            playing = false
            sendResponse("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n\r\n")
            close(); onClose?()

        default:
            sendResponse("RTSP/1.0 405 Method Not Allowed\r\nCSeq: \(cseq)\r\n\r\n")
        }
    }

    private func buildSDP() -> String {
        // Default Baseline profile-level-id for iPhone 11 H264
        var profileLevel = "42e01f"  // Baseline 3.1 — widely compatible
        var fmtp: String

        if let spsData = sps, let ppsData = pps, spsData.count > 3 {
            // We have real SPS/PPS — embed them so receivers get parameters immediately
            profileLevel = String(format: "%02x%02x%02x", spsData[1], spsData[2], spsData[3])
            let spsBase64 = spsData.base64EncodedString()
            let ppsBase64 = ppsData.base64EncodedString()
            fmtp = "a=fmtp:96 packetization-mode=1;profile-level-id=\(profileLevel);sprop-parameter-sets=\(spsBase64),\(ppsBase64)\r\n"
        } else {
            // No SPS/PPS yet — include profile-level-id so ffmpeg at least knows the codec.
            // sprop-parameter-sets will come in-band with the first keyframe.
            fmtp = "a=fmtp:96 packetization-mode=1;profile-level-id=\(profileLevel)\r\n"
        }

        return """
        v=0\r
        o=- 0 0 IN IP4 127.0.0.1\r
        s=RTSPCam\r
        c=IN IP4 0.0.0.0\r
        t=0 0\r
        m=video 0 RTP/AVP 96\r
        a=rtpmap:96 H264/90000\r
        \(fmtp)a=control:streamid=0\r
        a=framerate:30\r
        \r

        """
    }

    private func parseTransport(_ line: String) {
        for part in line.components(separatedBy: ";") {
            if part.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("client_port=") {
                let portPart = part.components(separatedBy: "=").last ?? ""
                clientRTPPort = UInt16(portPart.components(separatedBy: "-").first?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
            }
        }
        if case .hostPort(let host, _) = connection.endpoint {
            clientHost = "\(host)"
            if clientHost.hasPrefix("::ffff:") { clientHost = String(clientHost.dropFirst(7)) }
        }
    }

    private func openRTPSocket() {
        rtpSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    }

    func sendNAL(_ nalData: Data, pts: CMTime, isKeyframe: Bool) {
        guard playing, rtpSocket != -1, clientRTPPort > 0 else { return }

        // FIX: prepend SPS+PPS NALs before every keyframe so the receiver can always re-sync
        if isKeyframe, let spsData = sps, let ppsData = pps {
            let startCode = Data([0x00, 0x00, 0x00, 0x01])
            var spsNAL = startCode; spsNAL.append(spsData)
            var ppsNAL = startCode; ppsNAL.append(ppsData)
            let ts = UInt32(CMTimeGetSeconds(pts) * 90000)
            sendRawNAL(spsNAL, timestamp: ts, marker: false)
            sendRawNAL(ppsNAL, timestamp: ts, marker: false)
        }

        let timestamp = UInt32(CMTimeGetSeconds(pts) * 90000)
        sendRawNAL(nalData, timestamp: timestamp, marker: true)
    }

    private func sendRawNAL(_ nalData: Data, timestamp: UInt32, marker: Bool) {
        var nal = nalData
        if nal.prefix(4) == Data([0,0,0,1]) { nal = nal.dropFirst(4) }
        else if nal.prefix(3) == Data([0,0,1]) { nal = nal.dropFirst(3) }

        let maxPayload = 1400
        if nal.count <= maxPayload {
            sendRTPPacket(payload: nal, timestamp: timestamp, marker: marker)
        } else {
            // FU-A fragmentation
            let fuIndicator: UInt8 = (nal[0] & 0xe0) | 28
            let nalHeader = nal[0]
            var offset = 1
            let totalBytes = nal.count - 1
            while offset <= totalBytes {
                let isFirst = offset == 1
                let chunkSize = min(maxPayload - 2, totalBytes - offset + 1)
                let isLast = (offset + chunkSize - 1) >= totalBytes
                var fuHeader: UInt8 = nalHeader & 0x1f
                if isFirst { fuHeader |= 0x80 }
                if isLast  { fuHeader |= 0x40 }
                var payload = Data([fuIndicator, fuHeader])
                payload.append(nal[offset..<(offset + chunkSize)])
                sendRTPPacket(payload: payload, timestamp: timestamp, marker: isLast && marker)
                offset += chunkSize
            }
        }
    }

    private func sendRTPPacket(payload: Data, timestamp: UInt32, marker: Bool) {
        var header = Data(count: 12)
        header[0] = 0x80
        header[1] = (marker ? 0x80 : 0x00) | 96
        let seq = rtpSeq; rtpSeq &+= 1
        header[2] = UInt8((seq >> 8) & 0xff); header[3] = UInt8(seq & 0xff)
        header[4] = UInt8((timestamp >> 24) & 0xff); header[5] = UInt8((timestamp >> 16) & 0xff)
        header[6] = UInt8((timestamp >> 8) & 0xff);  header[7] = UInt8(timestamp & 0xff)
        header[8]  = UInt8((ssrc >> 24) & 0xff); header[9]  = UInt8((ssrc >> 16) & 0xff)
        header[10] = UInt8((ssrc >> 8)  & 0xff); header[11] = UInt8(ssrc & 0xff)
        var packet = header; packet.append(payload)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(clientRTPPort)
        inet_pton(AF_INET, clientHost, &addr.sin_addr)
        packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(rtpSocket, buf.baseAddress, packet.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func sendResponse(_ text: String) {
        connection.send(content: text.data(using: .utf8)!, completion: .idempotent)
    }
}
