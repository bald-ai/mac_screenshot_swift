import Foundation

/// Embeds and extracts Zoomies round-trip metadata in PNG text chunks so a
/// saved screenshot can carry its clean (pre-note) original plus the prompt
/// text that was burned onto it.
///
/// We manipulate PNG chunks directly instead of going through ImageIO's
/// `kCGImagePropertyPNGDictionary`: that dictionary only round-trips a fixed set
/// of standard tEXt keywords (Title, Author, Description, ...) and cannot write
/// the custom keywords this feature needs. The payloads are stored in
/// uncompressed `iTXt` chunks, which are UTF-8 safe.
enum PNGMetadata {
    /// Keyword for the base64-encoded clean original PNG.
    static let originalPNGKeyword = "Zoomies-OriginalPNG-v1"
    /// Keyword for the UTF-8 prompt text.
    static let promptKeyword = "Zoomies-Prompt-v1"

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Inserts the original PNG bytes and prompt as `iTXt` chunks just before
    /// `IEND`. Returns nil if either input is not a PNG, or the input PNG is
    /// malformed.
    static func embed(intoPNG pngData: Data, originalPNG: Data, prompt: String) -> Data? {
        let bytes = [UInt8](pngData)
        guard hasPNGSignature(bytes), isPNG(originalPNG) else { return nil }
        guard let iendStart = indexOfChunk(named: "IEND", in: bytes) else { return nil }

        var result = Data()
        result.append(contentsOf: bytes[0..<iendStart])
        result.append(makeITXtChunk(keyword: originalPNGKeyword, text: originalPNG.base64EncodedString()))
        result.append(makeITXtChunk(keyword: promptKeyword, text: prompt))
        result.append(contentsOf: bytes[iendStart...])
        return result
    }

    /// Extracts the embedded clean original and prompt. Returns nil for non-PNG
    /// input or when either chunk is missing.
    static func extract(fromPNG pngData: Data) -> (originalPNG: Data, prompt: String)? {
        let bytes = [UInt8](pngData)
        guard hasPNGSignature(bytes) else { return nil }

        var original: Data?
        var prompt: String?
        var index = 8
        while index + 8 <= bytes.count {
            guard let length = readUInt32(bytes, at: index) else { break }
            let typeStart = index + 4
            let dataStart = typeStart + 4
            let len = Int(length)
            guard dataStart + len + 4 <= bytes.count else { break }

            let type = String(bytes: bytes[typeStart..<dataStart], encoding: .ascii) ?? ""
            if type == "iTXt", let (keyword, text) = parseITXt(Array(bytes[dataStart..<dataStart + len])) {
                if keyword == originalPNGKeyword {
                    original = Data(base64Encoded: text)
                } else if keyword == promptKeyword {
                    prompt = text
                }
            }
            if type == "IEND" { break }
            index = dataStart + len + 4
        }

        guard let original, let prompt else { return nil }
        return (original, prompt)
    }

    /// True when the data starts with the 8-byte PNG signature.
    static func isPNG(_ data: Data) -> Bool {
        hasPNGSignature([UInt8](data.prefix(8)))
    }

    // MARK: - Chunk building

    private static func makeITXtChunk(keyword: String, text: String) -> Data {
        var payload = Data()
        payload.append(contentsOf: Array(keyword.utf8))
        payload.append(0x00) // keyword null separator
        payload.append(0x00) // compression flag: uncompressed
        payload.append(0x00) // compression method
        payload.append(0x00) // empty language tag, terminated
        payload.append(0x00) // empty translated keyword, terminated
        payload.append(contentsOf: Array(text.utf8))
        return assembleChunk(type: "iTXt", payload: payload)
    }

    private static func assembleChunk(type: String, payload: Data) -> Data {
        var typeAndPayload = Data(type.utf8)
        typeAndPayload.append(payload)

        var chunk = Data()
        chunk.append(contentsOf: bigEndianBytes(UInt32(payload.count)))
        chunk.append(typeAndPayload)
        chunk.append(contentsOf: bigEndianBytes(crc32(typeAndPayload)))
        return chunk
    }

    // MARK: - Chunk parsing

    /// Parses an uncompressed `iTXt` chunk payload into its keyword and text.
    private static func parseITXt(_ data: [UInt8]) -> (keyword: String, text: String)? {
        guard let keywordNull = data.firstIndex(of: 0x00),
              let keyword = String(bytes: data[0..<keywordNull], encoding: .utf8) else {
            return nil
        }

        var cursor = keywordNull + 1
        guard cursor + 2 <= data.count else { return nil }
        let compressionFlag = data[cursor]
        cursor += 2 // skip compression flag + method
        guard compressionFlag == 0 else { return nil } // we only write uncompressed

        guard let languageNull = data[cursor...].firstIndex(of: 0x00) else { return nil }
        cursor = languageNull + 1
        guard let translatedNull = data[cursor...].firstIndex(of: 0x00) else { return nil }
        cursor = translatedNull + 1

        guard let text = String(bytes: data[cursor...], encoding: .utf8) else { return nil }
        return (keyword, text)
    }

    private static func indexOfChunk(named name: String, in bytes: [UInt8]) -> Int? {
        let nameBytes = Array(name.utf8)
        var index = 8
        while index + 8 <= bytes.count {
            guard let length = readUInt32(bytes, at: index) else { return nil }
            let typeStart = index + 4
            let dataStart = typeStart + 4
            let len = Int(length)
            guard dataStart + len + 4 <= bytes.count else { return nil }
            if Array(bytes[typeStart..<dataStart]) == nameBytes {
                return index
            }
            index = dataStart + len + 4
        }
        return nil
    }

    // MARK: - Bytes & CRC

    private static func hasPNGSignature(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 8 && Array(bytes[0..<8]) == signature
    }

    private static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        return (UInt32(bytes[index]) << 24)
            | (UInt32(bytes[index + 1]) << 16)
            | (UInt32(bytes[index + 2]) << 8)
            | UInt32(bytes[index + 3])
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
