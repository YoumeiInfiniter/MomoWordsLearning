import Foundation

public struct ServerSentEvent: Equatable, Sendable {
    public let name: String?
    public let data: String

    public init(name: String?, data: String) {
        self.name = name
        self.data = data
    }
}

/// SSE framing must use the raw bytes: AsyncSequence.lines can omit empty lines,
/// but an empty line is what terminates each SSE event.
public struct ServerSentEventDecoder: Sendable {
    private var lineBytes: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName: String?
    private var skipNextLF = false

    public init() {}

    public mutating func append(_ byte: UInt8) -> ServerSentEvent? {
        if skipNextLF {
            skipNextLF = false
            if byte == 10 { return nil }
        }
        switch byte {
        case 13:
            skipNextLF = true
            return finishLine()
        case 10:
            return finishLine()
        default:
            lineBytes.append(byte)
            return nil
        }
    }

    public mutating func finish() -> ServerSentEvent? {
        if !lineBytes.isEmpty, let event = finishLine() { return event }
        return takeEvent()
    }

    private mutating func finishLine() -> ServerSentEvent? {
        let line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        if line.isEmpty { return takeEvent() }
        if line.hasPrefix(":") { return nil }

        let field: Substring
        let value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var remainder = line[line.index(after: colon)...]
            if remainder.first == " " { remainder = remainder.dropFirst() }
            value = remainder
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "data": dataLines.append(String(value))
        case "event": eventName = String(value)
        default: break
        }
        return nil
    }

    private mutating func takeEvent() -> ServerSentEvent? {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
        }
        guard !dataLines.isEmpty else { return nil }
        return ServerSentEvent(name: eventName, data: dataLines.joined(separator: "\n"))
    }
}
