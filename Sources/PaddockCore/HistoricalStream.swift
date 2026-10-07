import Foundation
import zlib

enum HistoricalStream {
    static let maximumRecordBytes = 8 * 1024 * 1024

    static func duration(_ text: String?) -> TimeInterval? {
        guard let text else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]),
              let seconds = Double(parts[2]), hours >= 0, hours <= 48,
              minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else { return nil }
        let result = hours * 3600 + minutes * 60 + seconds
        return result.isFinite ? result : nil
    }

    static func forEach(_ data: Data, compressed: Bool = false,
                        _ body: (TimeInterval, JSONValue) throws -> Void) throws {
        var start = data.startIndex
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { start += 3 }
        while start < data.endIndex {
            try Task.checkCancellation()
            let end = data[start...].firstIndex(of: 10) ?? data.endIndex
            var contentEnd = end
            if contentEnd > start, data[contentEnd - 1] == 13 { contentEnd -= 1 }
            if contentEnd > start {
                guard contentEnd - start > 12, contentEnd - start <= maximumRecordBytes,
                      let stamp = String(data: data[start..<(start + 12)], encoding: .utf8),
                      let elapsed = duration(stamp) else {
                    throw ProviderError.invalidData("The historical archive contains an invalid timestamp or record.")
                }
                try autoreleasepool {
                    var record = Data(data[(start + 12)..<contentEnd])
                    if compressed {
                        let wrapper = try JSONValue.decode(record)
                        guard let text = wrapper.string, let packed = Data(base64Encoded: text), !packed.isEmpty else {
                            throw ProviderError.invalidData("The historical archive contains invalid compressed telemetry.")
                        }
                        record = try inflate(packed, maximumBytes: maximumRecordBytes)
                    }
                    try body(elapsed, JSONValue.decode(record))
                }
            }
            start = end == data.endIndex ? end : end + 1
        }
    }

    static func inflate(_ data: Data, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0, data.count <= maximumRecordBytes else {
            throw ProviderError.invalidData("The compressed historical record exceeds its size limit.")
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ProviderError.invalidData("Historical telemetry decompression could not start.")
        }
        defer { inflateEnd(&stream) }
        var result = Data()
        try data.withUnsafeBytes { input in
            guard let base = input.bindMemory(to: UInt8.self).baseAddress else {
                throw ProviderError.invalidData("The compressed historical record is empty.")
            }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)
            var block = [UInt8](repeating: 0, count: min(65536, maximumBytes))
            while true {
                try Task.checkCancellation()
                let status = block.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let count = block.count - Int(stream.avail_out)
                guard count <= maximumBytes - result.count else {
                    throw ProviderError.invalidData("The expanded historical record exceeds its size limit.")
                }
                result.append(contentsOf: block.prefix(count))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else {
                        throw ProviderError.invalidData("The compressed historical record contains trailing data.")
                    }
                    return
                }
                guard status == Z_OK, count > 0 else {
                    throw ProviderError.invalidData("The historical archive contains damaged compressed telemetry.")
                }
            }
        }
        return result
    }
}
