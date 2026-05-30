import Foundation
import Network
import os.log

// MARK: - RTSP Server
// Listens on TCP port 8554, handles RTSP handshake (OPTIONS, DESCRIBE, SETUP, PLAY)
// then fires RTP packets over UDP to connected clients.

final class RTSPServer {
    static let port: UInt16 = 8554
    private var listener: NWListener?
    private var clients: [RTSPClient] = []
    private let queue = DispatchQueue(label: "rtsp.server", qos: .userInteractive)
    private let logger = Logger(subsystem: "RTSPCam", category: "RTSPServer")

    // Called by the encoder whenever a new H264 NAL unit is ready
    var onNALUnit: ((_ data: Data, _ pts: CMTime, _ isKeyframe: Bool) -> Void)?

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

    func sendNAL(_ data: Data, pts: CMTime, isKeyframe: Bool) {
        queue.async { [weak self] in
            self?.clients.forEach { $0.sendNAL(data, pts: pts, isKeyframe: isKeyframe) }
        }
    }

    private func handleNewConnection(_ conn: NWConnection) {
        let client = RTSPClient(connection: conn, serverPort: Self.port)
        client.onClose = { [weak self] in
            self?.queue.async {
                self?.clients.removeAll { $0 === client }
            }
        }
        clients.append(client)
        client.start()
        logger.info("New RTSP client connected. Total: \(self.clients.count)")
    }
}

// MARK: - RTSP Client Session
final class RTSPClient {
    private let connection: NWConnection
    private let serverPort: UInt16
    private let queue = DispatchQueue(label: "rtsp.client", qos: .userInteractive)
    private let logger = Logger(subsystem: "RTSPCam", category: "RTSPClient")

    // RTP over UDP
    private var rtpSocket: Int32 = -1
    private var clientRTPPort: UInt16 = 0
    private var clientHost: String = ""
    private var serverRTPPort: UInt16 = 0
    private var rtpSeq: UInt16 = 0
    private var ssrc: UInt32 = UInt32.random(in: 0..<UInt32.max)
    private var playing = false
    private var receivedBuffer = Data()
    private var cseq = 0

    // SPS/PPS for H264 — set when encoder provides them
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
        if rtpSocket != -1 {
            Darwin.close(rtpSocket)
            rtpSocket = -1
        }
    }

    // MARK: - Receive loop
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.receivedBuffer.append(data) }
            self.parseRTSPRequests()
            if isComplete || error != nil {
                self.close()
                self.onClose?()
            } else {
                self.receive()
            }
        }
    }

    private func parseRTSPRequests() {
        // RTSP requests end with \r\n\r\n
        while let range = receivedBuffer.range(of: Data("\r\n\r\n".utf8)) {
            let requestData = receivedBuffer[..<range.upperBound]
            receivedBuffer = receivedBuffer[range.upperBound...]
            if let text = String(data: requestData, encoding: .utf8) {
                handleRequest(text)
            }
        }
    }

    // MARK: - RTSP Request Handling
    private func handleRequest(_ text: String) {
        let lines = text.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        let method = parts[0]

        // Parse CSeq
        for line in lines {
            if line.lowercased().hasPrefix("cseq:") {
                cseq = Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) ?? cseq
            }
        }

        logger.debug("RTSP \(method)")

        switch method {
        case "OPTIONS":
            sendResponse("""
            RTSP/1.0 200 OK\r
            CSeq: \(cseq)\r
            Public: OPTIONS, DESCRIBE, SETUP, TEARDOWN, PLAY\r
            \r

            """)

        case "DESCRIBE":
            let sdp = buildSDP()
            let sdpData = sdp.data(using: .utf8)!
            sendResponse("""
            RTSP/1.0 200 OK\r
            CSeq: \(cseq)\r
            Content-Type: application/sdp\r
            Content-Length: \(sdpData.count)\r
            \r
            \(sdp)
            """)

        case "SETUP":
            // Parse client_port from Transport header
            for line in lines {
                if line.lowercased().hasPrefix("transport:") {
                    parseTransport(line)
                }
            }
            // Pick a random server RTP port
            serverRTPPort = UInt16.random(in: 5000..<6000) * 2
            openRTPSocket()
            sendResponse("""
            RTSP/1.0 200 OK\r
            CSeq: \(cseq)\r
            Transport: RTP/AVP;unicast;client_port=\(clientRTPPort)-\(clientRTPPort+1);server_port=\(serverRTPPort)-\(serverRTPPort+1)\r
            Session: 1\r
            \r

            """)

        case "PLAY":
            playing = true
            sendResponse("""
            RTSP/1.0 200 OK\r
            CSeq: \(cseq)\r
            Session: 1\r
            \r

            """)

        case "TEARDOWN":
            playing = false
            sendResponse("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n\r\n")
            close()
            onClose?()

        default:
            sendResponse("RTSP/1.0 405 Method Not Allowed\r\nCSeq: \(cseq)\r\n\r\n")
        }
    }

    private func buildSDP() -> String {
        // Encode SPS/PPS as base64 for the SDP if available
        var profileLevel = "42e01e" // baseline 3.0 default
        var spsBase64 = ""
        var ppsBase64 = ""

        if let spsData = sps, let ppsData = pps, spsData.count > 3 {
            profileLevel = String(format: "%02x%02x%02x", spsData[1], spsData[2], spsData[3])
            spsBase64 = spsData.base64EncodedString()
            ppsBase64 = ppsData.base64EncodedString()
        }

        let fmtp = spsBase64.isEmpty
            ? "a=fmtp:96 packetization-mode=1\r\n"
            : "a=fmtp:96 packetization-mode=1;profile-level-id=\(profileLevel);sprop-parameter-sets=\(spsBase64),\(ppsBase64)\r\n"

        return """
        v=0\r
        o=- 0 0 IN IP4 127.0.0.1\r
        s=RTSPCam\r
        t=0 0\r
        m=video 0 RTP/AVP 96\r
        a=rtpmap:96 H264/90000\r
        \(fmtp)a=control:streamid=0\r

        """
    }

    private func parseTransport(_ line: String) {
        // e.g. Transport: RTP/AVP;unicast;client_port=12345-12346
        let components = line.components(separatedBy: ";")
        for part in components {
            if part.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("client_port=") {
                let portPart = part.components(separatedBy: "=").last ?? ""
                let ports = portPart.components(separatedBy: "-")
                clientRTPPort = UInt16(ports.first?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
            }
        }
        // Get client IP from connection
        if case .hostPort(let host, _) = connection.endpoint {
            clientHost = "\(host)"
            // Clean up IPv6 formatting if needed
            if clientHost.hasPrefix("::ffff:") {
                clientHost = String(clientHost.dropFirst(7))
            }
        }
    }

    // MARK: - RTP UDP Socket
    private func openRTPSocket() {
        rtpSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    }

    // MARK: - Send NAL unit as RTP packets
    func sendNAL(_ nalData: Data, pts: CMTime, isKeyframe: Bool) {
        guard playing, rtpSocket != -1, clientRTPPort > 0 else { return }

        // RTP timestamp: 90kHz clock
        let timestamp = UInt32(CMTimeGetSeconds(pts) * 90000)

        // Strip start codes (0x00 0x00 0x00 0x01 or 0x00 0x00 0x01)
        var nal = nalData
        if nal.prefix(4) == Data([0,0,0,1]) { nal = nal.dropFirst(4) }
        else if nal.prefix(3) == Data([0,0,1]) { nal = nal.dropFirst(3) }

        let maxPayload = 1400

        if nal.count <= maxPayload {
            // Single NAL unit packet
            sendRTPPacket(payload: nal, timestamp: timestamp, marker: true)
        } else {
            // Fragmentation Unit A (FU-A)
            let fuIndicator = (nal[0] & 0xe0) | 28  // NRI + type=28
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
                sendRTPPacket(payload: payload, timestamp: timestamp, marker: isLast)
                offset += chunkSize
            }
        }
    }

    private func sendRTPPacket(payload: Data, timestamp: UInt32, marker: Bool) {
        var header = Data(count: 12)
        header[0] = 0x80  // V=2, P=0, X=0, CC=0
        header[1] = (marker ? 0x80 : 0x00) | 96  // M bit + payload type 96
        let seq = rtpSeq
        rtpSeq &+= 1
        header[2] = UInt8((seq >> 8) & 0xff)
        header[3] = UInt8(seq & 0xff)
        header[4] = UInt8((timestamp >> 24) & 0xff)
        header[5] = UInt8((timestamp >> 16) & 0xff)
        header[6] = UInt8((timestamp >> 8) & 0xff)
        header[7] = UInt8(timestamp & 0xff)
        header[8]  = UInt8((ssrc >> 24) & 0xff)
        header[9]  = UInt8((ssrc >> 16) & 0xff)
        header[10] = UInt8((ssrc >> 8)  & 0xff)
        header[11] = UInt8(ssrc & 0xff)

        var packet = header
        packet.append(payload)

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
        let data = text.data(using: .utf8)!
        connection.send(content: data, completion: .idempotent)
    }
}
