import Foundation

/// Reader for YouTube's UMP stream (`application/vnd.yt-ump`).
///
/// UMP is *not* protobuf: every length is a custom variable-length integer (1 byte under
/// 128, 2 under 192, 3 under 224, 4 under 240, else `0xF0` + little-endian UInt32). Each
/// media part also carries a one-byte prefix before its payload, and the payloads only form
/// a valid MP4 once that prefix is dropped and the parts are concatenated.
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

    /// The redirect URL carried by a type-43 part (protobuf field 1).
    public static func redirectURL(in data: Data) -> String? {
        for part in parts(in: data) where part.type == 43 {
            let bytes = [UInt8](part.payload)
            var index = 0
            while index < bytes.count {
                guard var tag = varint(bytes, &index), let length = varint(bytes, &index) else { break }
                tag >>= 3
                guard index + length <= bytes.count else { break }
                if tag == 1 {
                    return String(decoding: bytes[index..<(index + length)], as: UTF8.self)
                }
                index += length
            }
        }
        return nil
    }

    /// Downloads one SABR (`lsig`) stream end to end: start the umbrella request, follow the
    /// redirect part, and return the assembled MP4.
    public static func pull(mediaURL: String, userAgent: String, client: HTTPClient) async throws -> Data {
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
            throw HTTPError.badURL("UMP: no media part")
        }
        return mp4
    }

    /// Concatenates the media parts (type 21, minus their one-byte prefix) and trims the result
    /// to its MP4 box chain, so trailing UMP framing never reaches the file.
    public static func assembleMP4(from data: Data) -> Data? {
        var media = Data()
        for part in parts(in: data) where part.type == 21 {
            media.append(part.payload.dropFirst())
        }
        guard media.count > 8 else { return nil }
        let bytes = [UInt8](media)

        guard let ftyp = indexOf("ftyp", in: bytes), ftyp >= 4 else { return nil }
        var position = ftyp - 4
        while position + 8 <= bytes.count {
            let size32 = beU32(bytes, position)
            var size = Int(size32)
            if size32 == 1, position + 16 <= bytes.count {
                size = Int(beU64(bytes, position + 8))
            } else if size32 == 0 {
                size = bytes.count - position
            }
            guard size >= 8, position + size <= bytes.count else { break }
            position += size
        }
        guard position > ftyp else { return nil }
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
