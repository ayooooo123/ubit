import Foundation

/// Reader for YouTube's UMP stream (`application/vnd.yt-ump`).
///
/// UMP framing is *not* protobuf: each part's type and length are a custom variable-length
/// integer (1 byte under 128, 2 under 192, 3 under 224, 4 under 240, else `0xF0` +
/// little-endian UInt32). Part payloads can be protobuf messages (the redirect part is one)
/// and are decoded with protobuf rules. Each media part carries a one-byte prefix before its
/// payload, and the payloads only form a valid MP4 once that prefix is dropped and the parts
/// are concatenated.
public enum UMP {
    public static let requestBody = Data([0x78, 0x00])   // {15: 0} — "start streaming"

    public struct Part {
        public var type: Int
        public var payload: Data
    }

    /// Reads one UMP varint at `index`, advancing it.
    public static func varint(_ bytes: [UInt8], _ index: inout Int) -> Int? {
        guard index < bytes.count else { return nil }
        let b1 = Int(bytes[index])
        let width: Int
        if b1 < 128 { width = 1 }
        else if b1 < 192 { width = 2 }
        else if b1 < 224 { width = 3 }
        else if b1 < 240 { width = 4 }
        else { width = 5 }
        guard index + width <= bytes.count else { return nil }
        defer { index += width }
        switch width {
        case 1: return b1
        case 2: return (b1 & 0x3f) | (Int(bytes[index + 1]) << 6)
        case 3: return (b1 & 0x1f) | (Int(bytes[index + 1]) << 5) | (Int(bytes[index + 2]) << 13)
        case 4: return (b1 & 0x0f) | (Int(bytes[index + 1]) << 4) | (Int(bytes[index + 2]) << 12) | (Int(bytes[index + 3]) << 20)
        default:
            let b = bytes[(index + 1)...(index + 4)]
            return Int(UInt32(b[b.startIndex])
                | (UInt32(b[b.startIndex + 1]) << 8)
                | (UInt32(b[b.startIndex + 2]) << 16)
                | (UInt32(b[b.startIndex + 3]) << 24))
        }
    }

    public static func parts(in data: Data) -> [Part] {
        let bytes = [UInt8](data)
        var index = 0
        var out: [Part] = []
        while index < bytes.count {
            guard let type = varint(bytes, &index), let length = varint(bytes, &index) else { break }
            guard length >= 0, index + length <= bytes.count else { break }
            out.append(Part(type: type, payload: Data(bytes[index..<(index + length)])))
            index += length
        }
        return out
    }

    /// The redirect URL carried by a type-43 part (protobuf field 1, length-delimited).
    public static func redirectURL(in data: Data) -> String? {
        for part in parts(in: data) where part.type == 43 {
            let bytes = [UInt8](part.payload)
            var index = 0
            while index < bytes.count {
                guard let key = protobufVarint(bytes, &index) else { break }
                let field = key >> 3
                switch key & 0x7 {
                case 0:
                    guard protobufVarint(bytes, &index) != nil else { return nil }
                case 1:
                    index += 8
                case 2:
                    guard let length = protobufVarint(bytes, &index),
                          length <= UInt64(bytes.count - index) else { return nil }
                    let end = index + Int(length)
                    if field == 1 {
                        return String(decoding: bytes[index..<end], as: UTF8.self)
                    }
                    index = end
                case 5:
                    index += 4
                default:
                    return nil   // groups (3, 4) and invalid wire types
                }
            }
        }
        return nil
    }

    /// Reads one protobuf base-128 varint at `index`, advancing it. Nil when truncated or
    /// longer than 10 bytes.
    static func protobufVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 70 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    /// Downloads one SABR (`lsig`) stream end to end: start the umbrella request, follow the
    /// redirect part, and return the assembled MP4. The format's advertised content length is
    /// required, and a result of any other length is an error: a stream cut between two
    /// complete fragments still forms a valid box chain, so only the size can expose it.
    /// Without a length no result can be shown to be complete, so no request is sent.
    public static func pull(mediaURL: String, userAgent: String, expectedSize: Int64?, client: HTTPClient) async throws -> Data {
        guard let expectedSize, expectedSize > 0 else {
            throw HTTPError.badURL("UMP: no content length, so a complete stream cannot be confirmed")
        }
        let separator = mediaURL.contains("?") ? "&" : "?"
        let headers = ["Content-Type": "application/octet-stream", "User-Agent": userAgent]
        let (probe, _) = try await client.fetchData(
            url: mediaURL + separator + "ump=1&srfvp=1&alr=yes&rn=0",
            method: "POST", headers: headers, body: requestBody, includeCookies: false
        )
        guard let redirect = redirectURL(in: probe) else {
            throw HTTPError.badURL("UMP: no redirect part")
        }
        let (blob, _) = try await client.fetchData(
            url: redirect, method: "POST", headers: headers, body: requestBody, includeCookies: false
        )
        guard let mp4 = assembleMP4(from: blob) else {
            throw HTTPError.badURL("UMP: no complete media")
        }
        if Int64(mp4.count) != expectedSize {
            throw HTTPError.badURL("UMP: got \(mp4.count) of \(expectedSize) bytes")
        }
        return mp4
    }

    /// Concatenates the media parts (type 21, minus their one-byte header ID) and returns the
    /// MP4 box chain that starts at `ftyp`. Nil unless the chain is complete: every box must
    /// fit, the chain must end exactly at the end of the media bytes, and it must hold an
    /// `mdat`. Nil also when the parts carry more than one header ID, because that means more
    /// than one stream and their bytes must not be merged into one file. A chain cut exactly
    /// between two boxes still passes here; `pull` checks the size for that case.
    public static func assembleMP4(from data: Data) -> Data? {
        var media = Data()
        var headerID: UInt8?
        for part in parts(in: data) where part.type == 21 {
            guard let id = part.payload.first else { continue }
            if headerID == nil { headerID = id }
            guard id == headerID else { return nil }
            media.append(part.payload.dropFirst())
        }
        guard media.count > 8 else { return nil }
        let bytes = [UInt8](media)

        guard let ftyp = indexOf("ftyp", in: bytes), ftyp >= 4 else { return nil }
        var position = ftyp - 4
        var sawMediaData = false
        while position < bytes.count {
            let remaining = bytes.count - position
            guard remaining >= 8 else { return nil }
            let size32 = beU32(bytes, position)
            let size: Int
            if size32 == 1 {
                guard remaining >= 16 else { return nil }
                let size64 = beU64(bytes, position + 8)
                guard size64 >= 16, size64 <= UInt64(remaining) else { return nil }
                size = Int(size64)
            } else if size32 == 0 {
                size = remaining   // box runs to the end of the data
            } else {
                guard size32 >= 8, UInt64(size32) <= UInt64(remaining) else { return nil }
                size = Int(size32)
            }
            if bytes[(position + 4)..<(position + 8)].elementsEqual("mdat".utf8) { sawMediaData = true }
            position += size
        }
        guard sawMediaData else { return nil }
        return media.subdata(in: (ftyp - 4)..<position)
    }

    private static func indexOf(_ needle: String, in bytes: [UInt8]) -> Int? {
        let pattern = [UInt8](needle.utf8)
        guard bytes.count >= pattern.count else { return nil }
        for i in 0...(bytes.count - pattern.count) where Array(bytes[i..<(i + pattern.count)]) == pattern {
            return i
        }
        return nil
    }

    private static func beU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    private static func beU64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(b[o + i]) }
        return value
    }
}
