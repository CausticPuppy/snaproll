import Foundation

/// Codec for the aFrame's ExtGetProject / ExtSetProject payloads.
///
/// The API spec calls this "LZSS" but the actual format — reverse-engineered
/// from capture session 20260701-213259 and verified byte-exact against a
/// VER.2.00 device (all 160 patches match the TXT dumps; trailing byteSum32
/// checksum matches) — is an escape-byte LZ77:
///
///   Framing (after the 2-byte wire size prefix):
///     u32 LE  decodedSize   (0x7F00 for a project)
///     u32 LE  compressedSize (includes this 12-byte header)
///     u8      escape byte   (0x7D on the device)
///     u8[3]   padding (zero)
///     ...token stream...
///
///   Token stream:
///     - any byte != 0x7D: literal
///     - 0x7D d l: copy `l` bytes from `dist` bytes back in the output,
///       where dist = d - 1 if d >= 0x7E else d. The value 0x7D never
///       appears as `d` (the encoder skips it, shifting larger distances
///       up by one). Lengths are raw (observed 4...192); distances reach
///       254. Overlapping copies repeat bytes (RLE-style).
///     - 0x7D 0x7D: literal 0x7D. UNVERIFIED — the captured project contains
///       no 0x7D plaintext bytes, so the firmware's rule for them is unknown.
///       Our encoder uses this only when no back-reference can supply the
///       byte; a wrong guess is caught by the device's project checksum.
public enum AFrameLZ {
    public static let escapeByte: UInt8 = 0x7D
    static let maxDistance = 254
    static let minMatch = 4
    /// Device emits lengths up to 192; stay within the observed envelope.
    static let maxMatch = 192

    public enum CodecError: Error, LocalizedError, Equatable {
        case malformedHeader
        case truncatedStream
        case sizeMismatch(declared: Int, actual: Int)

        public var errorDescription: String? {
            switch self {
            case .malformedHeader: return "LZ payload header is malformed"
            case .truncatedStream: return "LZ token stream ended prematurely"
            case .sizeMismatch(let d, let a): return "LZ size mismatch (declared \(d), got \(a))"
            }
        }
    }

    // MARK: Decode

    /// Decodes a framed payload (12-byte header + token stream).
    public static func decode(framed data: Data) throws -> Data {
        guard data.count >= 12 else { throw CodecError.malformedHeader }
        var r = BinaryReader(data)
        let decodedSize = Int(r.readLEUInt32())
        let compressedSize = Int(r.readLEUInt32())
        let escape: UInt8 = r.readLE()
        guard escape == escapeByte, compressedSize <= data.count,
              decodedSize <= 0x40000 else {
            throw CodecError.malformedHeader
        }
        let out = try decodeStream(data.dropFirst(12), decodedSize: decodedSize)
        guard out.count == decodedSize else {
            throw CodecError.sizeMismatch(declared: decodedSize, actual: out.count)
        }
        return out
    }

    static func decodeStream(_ payload: Data, decodedSize: Int) throws -> Data {
        let bytes = [UInt8](payload)
        var out = [UInt8]()
        out.reserveCapacity(decodedSize)
        var i = 0
        while i < bytes.count && out.count < decodedSize {
            let b = bytes[i]
            if b != escapeByte {
                out.append(b)
                i += 1
                continue
            }
            guard i + 1 < bytes.count else { throw CodecError.truncatedStream }
            let d = bytes[i + 1]
            if d == escapeByte {  // stuffed literal escape byte (unverified)
                out.append(escapeByte)
                i += 2
                continue
            }
            guard i + 2 < bytes.count else { throw CodecError.truncatedStream }
            let length = Int(bytes[i + 2])
            let dist = d >= 0x7E ? Int(d) - 1 : Int(d)
            guard dist > 0, dist <= out.count else { throw CodecError.truncatedStream }
            let start = out.count - dist
            for k in 0..<length {  // byte-wise: overlapping copies repeat
                out.append(out[start + k])
            }
            i += 3
        }
        return Data(out)
    }

    // MARK: Encode

    /// Encodes plaintext into a framed payload the device can decode.
    public static func encode(framed plaintext: Data) -> Data {
        let stream = encodeStream(plaintext)
        var out = Data(capacity: stream.count + 12)
        out.appendLE(UInt32(plaintext.count))
        out.appendLE(UInt32(stream.count + 12))  // includes this header
        out.append(escapeByte)
        out.append(Data(repeating: 0, count: 3))
        out.append(stream)
        return out
    }

    static func encodeStream(_ input: Data) -> Data {
        let bytes = [UInt8](input)
        var out = Data()
        var pos = 0
        while pos < bytes.count {
            if let m = findMatch(bytes, at: pos) {
                out.append(escapeByte)
                // Distances >= 0x7D are stored +1 so the byte 0x7D never
                // appears in the distance slot.
                out.append(m.distance >= 0x7D ? UInt8(m.distance + 1) : UInt8(m.distance))
                out.append(UInt8(m.length))
                pos += m.length
            } else if bytes[pos] == escapeByte {
                out.append(escapeByte)  // stuffed literal (unverified, see header doc)
                out.append(escapeByte)
                pos += 1
            } else {
                out.append(bytes[pos])
                pos += 1
            }
        }
        return out
    }

    private static func findMatch(_ bytes: [UInt8], at pos: Int) -> (distance: Int, length: Int)? {
        let maxLen = min(maxMatch, bytes.count - pos)
        guard maxLen >= minMatch else { return nil }
        var best: (distance: Int, length: Int)?
        let windowStart = max(0, pos - maxDistance)
        var start = pos - 1
        while start >= windowStart {
            var len = 0
            // Comparing against bytes[start + k] with start + k possibly >= pos
            // is exactly the decoder's overlapping-copy semantics.
            while len < maxLen && bytes[start + len] == bytes[pos + len] {
                len += 1
            }
            if len >= minMatch, len > (best?.length ?? 0) {
                best = (pos - start, len)
                if len == maxLen { break }
            }
            start -= 1
        }
        return best
    }
}
