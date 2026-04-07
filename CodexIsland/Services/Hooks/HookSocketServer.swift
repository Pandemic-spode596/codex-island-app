//
//  HookSocketServer.swift
//  CodexIsland
//
//  Unix domain socket server for real-time hook events
//  Supports request/response for permission decisions
//

import Foundation
import os.log

/// Logger for hook socket server
private let logger = Logger(subsystem: "com.codexisland", category: "Hooks")

/// Event received from Claude Code hooks
struct HookEvent: Codable, Sendable {
    let sessionId: String
    let provider: SessionProvider
    let cwd: String
    let transcriptPath: String?
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let terminalName: String?
    let terminalWindowId: String?
    let terminalTabId: String?
    let terminalSurfaceId: String?
    let turnId: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let notificationType: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case provider, cwd, event, status, pid, tty
        case terminalName = "terminal_name"
        case terminalWindowId = "terminal_window_id"
        case terminalTabId = "terminal_tab_id"
        case terminalSurfaceId = "terminal_surface_id"
        case transcriptPath = "transcript_path"
        case turnId = "turn_id"
        case tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message
    }

    /// Create a copy with updated toolUseId
    init(sessionId: String, provider: SessionProvider, cwd: String, transcriptPath: String?, event: String, status: String, pid: Int?, tty: String?, terminalName: String?, terminalWindowId: String?, terminalTabId: String?, terminalSurfaceId: String?, turnId: String?, tool: String?, toolInput: [String: AnyCodable]?, toolUseId: String?, notificationType: String?, message: String?) {
        self.sessionId = sessionId
        self.provider = provider
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.terminalName = terminalName
        self.terminalWindowId = terminalWindowId
        self.terminalTabId = terminalTabId
        self.terminalSurfaceId = terminalSurfaceId
        self.turnId = turnId
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.notificationType = notificationType
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        provider = try container.decodeIfPresent(SessionProvider.self, forKey: .provider) ?? .claude
        cwd = try container.decode(String.self, forKey: .cwd)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        event = try container.decode(String.self, forKey: .event)
        status = try container.decode(String.self, forKey: .status)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        tty = try container.decodeIfPresent(String.self, forKey: .tty)
        terminalName = try container.decodeIfPresent(String.self, forKey: .terminalName)
        terminalWindowId = try container.decodeIfPresent(String.self, forKey: .terminalWindowId)
        terminalTabId = try container.decodeIfPresent(String.self, forKey: .terminalTabId)
        terminalSurfaceId = try container.decodeIfPresent(String.self, forKey: .terminalSurfaceId)
        turnId = try container.decodeIfPresent(String.self, forKey: .turnId)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        toolInput = try container.decodeIfPresent([String: AnyCodable].self, forKey: .toolInput)
        toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
        notificationType = try container.decodeIfPresent(String.self, forKey: .notificationType)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(provider, forKey: .provider)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
        try container.encode(event, forKey: .event)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encodeIfPresent(tty, forKey: .tty)
        try container.encodeIfPresent(terminalName, forKey: .terminalName)
        try container.encodeIfPresent(terminalWindowId, forKey: .terminalWindowId)
        try container.encodeIfPresent(terminalTabId, forKey: .terminalTabId)
        try container.encodeIfPresent(terminalSurfaceId, forKey: .terminalSurfaceId)
        try container.encodeIfPresent(turnId, forKey: .turnId)
        try container.encodeIfPresent(tool, forKey: .tool)
        try container.encodeIfPresent(toolInput, forKey: .toolInput)
        try container.encodeIfPresent(toolUseId, forKey: .toolUseId)
        try container.encodeIfPresent(notificationType, forKey: .notificationType)
        try container.encodeIfPresent(message, forKey: .message)
    }

    var sessionPhase: SessionPhase {
        if event == "PreCompact" {
            return .compacting
        }

        switch status {
        case "waiting_for_approval":
            // Note: Full PermissionContext is constructed by SessionStore, not here
            // This is just for quick phase checks
            return .waitingForApproval(PermissionContext(
                toolUseId: toolUseId ?? "",
                toolName: tool ?? "unknown",
                toolInput: toolInput,
                receivedAt: Date()
            ))
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        default:
            return .idle
        }
    }

    /// Whether this event expects a response (permission request)
    nonisolated var expectsResponse: Bool {
        event == "PermissionRequest" && status == "waiting_for_approval"
    }
}

/// Response to send back to the hook
struct HookResponse: Codable {
    let decision: String // "allow", "deny", or "ask"
    let reason: String?
}

/// Pending permission request waiting for user decision
struct PendingPermission: Sendable {
    let sessionId: String
    let toolUseId: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

/// Callback for hook events
typealias HookEventHandler = @Sendable (HookEvent) -> Void

/// Callback for permission response failures (socket died)
typealias PermissionFailureHandler = @Sendable (_ sessionId: String, _ toolUseId: String) -> Void

enum HookSocketIOError: Error, Equatable {
    case noData
    case timedOut(String)
    case invalidPayload(String)
    case readFailed(Int32)
    case writeFailed(Int32)
}

enum HookSocketIO {
    typealias Writer = (_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int
    typealias Poller = (_ fds: UnsafeMutablePointer<pollfd>?, _ nfds: nfds_t, _ timeout: Int32) -> Int32

    static let defaultTimeout: TimeInterval = 2
    private static let bufferSize = 131072

    static func readEvent(
        from clientSocket: Int32,
        timeout: TimeInterval = defaultTimeout
    ) throws -> HookEvent {
        // Hooks usually send a single JSON document and then close their side of the socket,
        // but writes may arrive in multiple chunks. Keep polling until we can decode a full
        // event, EOF confirms the payload is complete, or the overall timeout expires.
        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let deadline = Date().addingTimeInterval(timeout)
        var didReachEOF = false

        while Date() < deadline {
            var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let remainingMs = max(1, Int32(ceil(deadline.timeIntervalSinceNow * 1000)))
            let pollResult = poll(&pollFd, 1, min(remainingMs, 250))

            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw HookSocketIOError.readFailed(errno)
            }

            if pollResult == 0 {
                if let event = tryDecodeEvent(from: allData) {
                    return event
                }
                continue
            }

            if (pollFd.revents & Int16(POLLERR | POLLNVAL)) != 0 {
                throw HookSocketIOError.readFailed(errno == 0 ? EIO : errno)
            }

            if (pollFd.revents & Int16(POLLIN)) != 0 {
                while true {
                    let bytesRead = read(clientSocket, &buffer, buffer.count)

                    if bytesRead > 0 {
                        allData.append(contentsOf: buffer[0 ..< bytesRead])
                        if let event = tryDecodeEvent(from: allData) {
                            return event
                        }
                        continue
                    }

                    if bytesRead == 0 {
                        didReachEOF = true
                        break
                    }

                    if errno == EINTR {
                        continue
                    }

                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        break
                    }

                    throw HookSocketIOError.readFailed(errno)
                }
            }

            if (pollFd.revents & Int16(POLLHUP)) != 0 {
                didReachEOF = true
            }

            if didReachEOF {
                break
            }
        }

        guard !allData.isEmpty else {
            throw HookSocketIOError.noData
        }

        if let event = tryDecodeEvent(from: allData) {
            return event
        }

        let preview = payloadPreview(for: allData)
        if didReachEOF {
            throw HookSocketIOError.invalidPayload(preview)
        }
        throw HookSocketIOError.timedOut(preview)
    }

    static func writeAll(
        _ data: Data,
        to socket: Int32,
        timeout: TimeInterval = defaultTimeout,
        writer: Writer? = nil,
        poller: Poller? = nil
    ) throws {
        // Permission responses are tiny, but the hook still expects a complete JSON reply on
        // the same socket it used for the request. Treat partial writes and EAGAIN as normal
        // backpressure instead of silently dropping the approval decision.
        let writer = writer ?? defaultWriter
        let poller = poller ?? defaultPoller
        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }

            while offset < data.count {
                let pointer = baseAddress.advanced(by: offset)
                let result = writer(socket, pointer, data.count - offset)

                if result > 0 {
                    offset += result
                    continue
                }

                if result == 0 {
                    throw HookSocketIOError.writeFailed(EPIPE)
                }

                if errno == EINTR {
                    continue
                }

                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitUntilWritable(socket: socket, deadline: deadline, poller: poller)
                    continue
                }

                throw HookSocketIOError.writeFailed(errno)
            }
        }
    }

    private static func tryDecodeEvent(from data: Data) -> HookEvent? {
        guard !data.isEmpty else {
            return nil
        }
        return try? JSONDecoder().decode(HookEvent.self, from: data)
    }

    private static func waitUntilWritable(socket: Int32, deadline: Date, poller: Poller) throws {
        while Date() < deadline {
            var pollFd = pollfd(fd: socket, events: Int16(POLLOUT | POLLERR | POLLHUP), revents: 0)
            let remainingMs = max(1, Int32(ceil(deadline.timeIntervalSinceNow * 1000)))
            let pollResult = poller(&pollFd, 1, min(remainingMs, 250))

            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw HookSocketIOError.writeFailed(errno)
            }

            if pollResult == 0 {
                continue
            }

            if (pollFd.revents & Int16(POLLOUT)) != 0 {
                return
            }

            if (pollFd.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
                throw HookSocketIOError.writeFailed(errno == 0 ? EPIPE : errno)
            }
        }

        throw HookSocketIOError.timedOut("Timed out waiting for socket to become writable")
    }

    private static func payloadPreview(for data: Data) -> String {
        let prefix = data.prefix(512)
        let text = String(decoding: prefix, as: UTF8.self)
        if data.count > prefix.count {
            return "\(text)…"
        }
        return text
    }

    private static func defaultWriter(fd: Int32, buffer: UnsafeRawPointer, count: Int) -> Int {
        write(fd, buffer, count)
    }

    private static func defaultPoller(fds: UnsafeMutablePointer<pollfd>?, nfds: nfds_t, timeout: Int32) -> Int32 {
        poll(fds, nfds, timeout)
    }
}

/// Unix domain socket server that bridges hook events into the app process.
/// Non-permission events are fire-and-forget, but permission requests keep their client socket
/// open until the UI sends a decision or the request is explicitly cancelled.
class HookSocketServer {
    static let shared = HookSocketServer()
    static let socketPath = "/tmp/codex-island.sock"

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private var permissionFailureHandler: PermissionFailureHandler?
    private let queue = DispatchQueue(label: "com.codexisland.socket", qos: .userInitiated)

    /// Pending permission requests indexed by resolved toolUseId.
    /// The stored socket is the return channel back to the original hook process, so entries
    /// must stay alive until we answer, the tool completes elsewhere, or the session stops waiting.
    private var pendingPermissions: [String: PendingPermission] = [:]
    private let permissionsLock = NSLock()

    /// Cache tool_use_id values from PreToolUse so a later PermissionRequest can be mapped back
    /// to the concrete tool execution. The hook protocol does not guarantee tool_use_id is echoed
    /// on the permission event, so we use a FIFO queue per "session + tool + normalized input".
    private var toolUseIdCache: [String: [String]] = [:]
    private let cacheLock = NSLock()

    private init() {}

    /// Start the socket server
    func start(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler? = nil) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent, onPermissionFailure: onPermissionFailure)
        }
    }

    private func startServer(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler?) {
        guard serverSocket < 0 else { return }

        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure

        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        chmod(Self.socketPath, 0o777)

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(Self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    /// Stop the socket server
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(Self.socketPath)

        permissionsLock.lock()
        for (_, pending) in pendingPermissions {
            close(pending.clientSocket)
        }
        pendingPermissions.removeAll()
        permissionsLock.unlock()
    }

    /// Respond to a pending permission request by toolUseId
    func respondToPermission(toolUseId: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponse(toolUseId: toolUseId, decision: decision, reason: reason)
        }
    }

    /// Respond to permission by sessionId (finds the most recent pending for that session)
    func respondToPermissionBySession(sessionId: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponseBySession(sessionId: sessionId, decision: decision, reason: reason)
        }
    }

    /// Cancel all pending permissions for a session (when Claude stops waiting)
    func cancelPendingPermissions(sessionId: String) {
        queue.async { [weak self] in
            self?.cleanupPendingPermissions(sessionId: sessionId)
        }
    }

    /// Check if there's a pending permission request for a session
    func hasPendingPermission(sessionId: String) -> Bool {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.contains { $0.sessionId == sessionId }
    }

    /// Get the pending permission details for a session (if any)
    func getPendingPermission(sessionId: String) -> (toolName: String?, toolId: String?, toolInput: [String: AnyCodable]?)? {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        guard let pending = pendingPermissions.values.first(where: { $0.sessionId == sessionId }) else {
            return nil
        }
        return (pending.event.tool, pending.toolUseId, pending.event.toolInput)
    }

    /// Cancel a specific pending permission by toolUseId (when tool completes via terminal approval)
    func cancelPendingPermission(toolUseId: String) {
        queue.async { [weak self] in
            self?.cleanupSpecificPermission(toolUseId: toolUseId)
        }
    }

    private func cleanupSpecificPermission(toolUseId: String) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            return
        }
        permissionsLock.unlock()

        logger.debug("Tool completed externally, closing socket for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
        close(pending.clientSocket)
    }

    private func cleanupPendingPermissions(sessionId: String) {
        permissionsLock.lock()
        let matching = pendingPermissions.filter { $0.value.sessionId == sessionId }
        for (toolUseId, pending) in matching {
            logger.debug("Cleaning up stale permission for \(sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
            close(pending.clientSocket)
            pendingPermissions.removeValue(forKey: toolUseId)
        }
        permissionsLock.unlock()
    }

    // MARK: - Tool Use ID Cache

    /// Encoder with sorted keys for deterministic cache keys
    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Generate cache key from event properties
    private func cacheKey(sessionId: String, toolName: String?, toolInput: [String: AnyCodable]?) -> String {
        let inputStr: String
        if let input = toolInput,
           let data = try? Self.sortedEncoder.encode(input),
           let str = String(data: data, encoding: .utf8) {
            inputStr = str
        } else {
            inputStr = "{}"
        }
        return "\(sessionId):\(toolName ?? "unknown"):\(inputStr)"
    }

    /// Cache tool_use_id from PreToolUse event (FIFO queue per key)
    private func cacheToolUseId(event: HookEvent) {
        guard let toolUseId = event.toolUseId else { return }

        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        if toolUseIdCache[key] == nil {
            toolUseIdCache[key] = []
        }
        toolUseIdCache[key]?.append(toolUseId)
        cacheLock.unlock()

        logger.debug("Cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
    }

    /// Pop and return cached tool_use_id for PermissionRequest (FIFO)
    private func popCachedToolUseId(event: HookEvent) -> String? {
        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard var queue = toolUseIdCache[key], !queue.isEmpty else {
            return nil
        }

        let toolUseId = queue.removeFirst()

        if queue.isEmpty {
            toolUseIdCache.removeValue(forKey: key)
        } else {
            toolUseIdCache[key] = queue
        }

        logger.debug("Retrieved cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
        return toolUseId
    }

    /// Clean up cache entries for a session (on session end)
    private func cleanupCache(sessionId: String) {
        cacheLock.lock()
        let keysToRemove = toolUseIdCache.keys.filter { $0.hasPrefix("\(sessionId):") }
        for key in keysToRemove {
            toolUseIdCache.removeValue(forKey: key)
        }
        cacheLock.unlock()

        if !keysToRemove.isEmpty {
            logger.debug("Cleaned up \(keysToRemove.count) cache entries for session \(sessionId.prefix(8), privacy: .public)")
        }
    }

    // MARK: - Private

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        handleClient(clientSocket)
    }

    private func handleClient(_ clientSocket: Int32) {
        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        let event: HookEvent
        do {
            event = try HookSocketIO.readEvent(from: clientSocket)
        } catch HookSocketIOError.noData {
            close(clientSocket)
            return
        } catch HookSocketIOError.timedOut(let preview) {
            logger.warning("Timed out waiting for complete hook event: \(preview, privacy: .public)")
            close(clientSocket)
            return
        } catch HookSocketIOError.invalidPayload(let preview) {
            logger.warning("Failed to parse hook event payload: \(preview, privacy: .public)")
            close(clientSocket)
            return
        } catch HookSocketIOError.readFailed(let code) {
            logger.error("Failed to read hook event: errno \(code)")
            close(clientSocket)
            return
        } catch {
            logger.error("Unexpected hook socket read failure: \(error.localizedDescription, privacy: .public)")
            close(clientSocket)
            return
        }

        logger.debug("Received: \(event.event, privacy: .public) for \(event.sessionId.prefix(8), privacy: .public)")

        if event.event == "PreToolUse" {
            cacheToolUseId(event: event)
        }

        if event.event == "SessionEnd" {
            cleanupCache(sessionId: event.sessionId)
        }

        if event.expectsResponse {
            // PermissionRequest is the only request/response exchange on this socket. We resolve
            // the tool_use_id first, then retain the socket so SessionStore/UI can answer later.
            let toolUseId: String
            if let eventToolUseId = event.toolUseId {
                toolUseId = eventToolUseId
            } else if let cachedToolUseId = popCachedToolUseId(event: event) {
                toolUseId = cachedToolUseId
            } else {
                logger.warning("Permission request missing tool_use_id for \(event.sessionId.prefix(8), privacy: .public) - no cache hit")
                close(clientSocket)
                eventHandler?(event)
                return
            }

            logger.debug("Permission request - keeping socket open for \(event.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")

            let updatedEvent = HookEvent(
                sessionId: event.sessionId,
                provider: event.provider,
                cwd: event.cwd,
                transcriptPath: event.transcriptPath,
                event: event.event,
                status: event.status,
                pid: event.pid,
                tty: event.tty,
                terminalName: event.terminalName,
                terminalWindowId: event.terminalWindowId,
                terminalTabId: event.terminalTabId,
                terminalSurfaceId: event.terminalSurfaceId,
                turnId: event.turnId,
                tool: event.tool,
                toolInput: event.toolInput,
                toolUseId: toolUseId,  // Use resolved toolUseId
                notificationType: event.notificationType,
                message: event.message
            )

            let pending = PendingPermission(
                sessionId: event.sessionId,
                toolUseId: toolUseId,
                clientSocket: clientSocket,
                event: updatedEvent,
                receivedAt: Date()
            )
            permissionsLock.lock()
            pendingPermissions[toolUseId] = pending
            permissionsLock.unlock()

            eventHandler?(updatedEvent)
            return
        } else {
            close(clientSocket)
        }

        eventHandler?(event)
    }

    private func sendPermissionResponse(toolUseId: String, decision: String, reason: String?) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            logger.debug("No pending permission for toolUseId: \(toolUseId.prefix(12), privacy: .public)")
            return
        }
        permissionsLock.unlock()

        let response = HookResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            logger.error("Failed to encode permission response for toolUseId: \(toolUseId.prefix(12), privacy: .public)")
            close(pending.clientSocket)
            permissionFailureHandler?(pending.sessionId, toolUseId)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        do {
            try HookSocketIO.writeAll(data, to: pending.clientSocket)
            logger.debug("Write succeeded: \(data.count) bytes")
        } catch HookSocketIOError.timedOut(let message) {
            logger.error("Timed out writing permission response: \(message, privacy: .public)")
            // Once the socket write fails, the originating hook will not receive a decision, so
            // SessionStore must clear the pending approval from app state on the failure callback.
            permissionFailureHandler?(pending.sessionId, toolUseId)
        } catch HookSocketIOError.writeFailed(let code) {
            logger.error("Write failed with errno: \(code)")
            permissionFailureHandler?(pending.sessionId, toolUseId)
        } catch {
            logger.error("Unexpected permission response failure: \(error.localizedDescription, privacy: .public)")
            permissionFailureHandler?(pending.sessionId, toolUseId)
        }

        close(pending.clientSocket)
    }

    private func sendPermissionResponseBySession(sessionId: String, decision: String, reason: String?) {
        permissionsLock.lock()
        let matchingPending = pendingPermissions.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.receivedAt > $1.receivedAt }
            .first

        guard let pending = matchingPending else {
            permissionsLock.unlock()
            logger.debug("No pending permission for session: \(sessionId.prefix(8), privacy: .public)")
            return
        }

        pendingPermissions.removeValue(forKey: pending.toolUseId)
        permissionsLock.unlock()

        let response = HookResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            logger.error("Failed to encode permission response for session: \(sessionId.prefix(8), privacy: .public)")
            close(pending.clientSocket)
            permissionFailureHandler?(sessionId, pending.toolUseId)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(sessionId.prefix(8), privacy: .public) tool:\(pending.toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        var writeSuccess = false
        do {
            try HookSocketIO.writeAll(data, to: pending.clientSocket)
            logger.debug("Write succeeded: \(data.count) bytes")
            writeSuccess = true
        } catch HookSocketIOError.timedOut(let message) {
            logger.error("Timed out writing permission response: \(message, privacy: .public)")
        } catch HookSocketIOError.writeFailed(let code) {
            logger.error("Write failed with errno: \(code)")
        } catch {
            logger.error("Unexpected permission response failure: \(error.localizedDescription, privacy: .public)")
        }

        close(pending.clientSocket)

        if !writeSuccess {
            permissionFailureHandler?(sessionId, pending.toolUseId)
        }
    }
}

// MARK: - AnyCodable for tool_input

/// Type-erasing codable wrapper for heterogeneous values
/// Used to decode JSON objects with mixed value types
