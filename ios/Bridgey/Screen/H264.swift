import CoreMedia
import Foundation

/// H.264 access units as the session hands them over (Annex B: start codes before each NAL unit), turned into what
/// VideoToolbox decodes (AVCC: a 4-byte length before each NAL unit, parameter sets in a format description).
enum H264 {
    static let sps: UInt8 = 7
    static let pps: UInt8 = 8
    static let accessUnitDelimiter: UInt8 = 9

    /// The NAL units of an Annex B access unit, without their start codes.
    static func nalUnits(_ data: UnsafeRawBufferPointer) -> [UnsafeRawBufferPointer] {
        let bytes = data.bindMemory(to: UInt8.self)
        let n = bytes.count
        var starts: [(code: Int, body: Int)] = []
        var i = 0
        while i + 3 <= n {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let code = i > 0 && bytes[i - 1] == 0 ? i - 1 : i
                starts.append((code, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var units: [UnsafeRawBufferPointer] = []
        for (k, s) in starts.enumerated() {
            var end = k + 1 < starts.count ? starts[k + 1].code : n
            // Zero bytes before the next start code belong to no unit.
            while end > s.body, bytes[end - 1] == 0 { end -= 1 }
            if end > s.body { units.append(UnsafeRawBufferPointer(rebasing: data[s.body..<end])) }
        }
        return units
    }

    static func type(_ unit: UnsafeRawBufferPointer) -> UInt8 { unit.first.map { $0 & 0x1F } ?? 0 }

    /// An access unit for the decoder: its parameter sets (when it carries them) and the rest as AVCC.
    struct AccessUnit {
        var sps: Data?
        var pps: Data?
        var avcc = Data()
        var hasPicture = false
    }

    static func accessUnit(_ data: UnsafeRawBufferPointer) -> AccessUnit {
        var unit = AccessUnit()
        for nal in nalUnits(data) {
            switch type(nal) {
            case sps: unit.sps = Data(nal)
            case pps: unit.pps = Data(nal)
            case accessUnitDelimiter: continue
            default:
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { unit.avcc.append(contentsOf: $0) }
                unit.avcc.append(contentsOf: nal)
                let t = type(nal)
                if t == 1 || t == 5 { unit.hasPicture = true }
            }
        }
        return unit
    }

    /// The format description for a pair of parameter sets, or nil when VideoToolbox doesn't take them.
    static func formatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        return status == noErr ? description : nil
    }

    /// Annex B from AVCC with the given parameter sets first: how an encoded frame goes to the session (the demo).
    static func annexB(avcc: Data, sps: Data?, pps: Data?) -> Data {
        let code: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        for set in [sps, pps].compactMap({ $0 }) {
            out.append(contentsOf: code)
            out.append(set)
        }
        var i = avcc.startIndex
        while i + 4 <= avcc.endIndex {
            let length = avcc[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            let body = i + 4
            guard length > 0, body + length <= avcc.endIndex else { break }
            out.append(contentsOf: code)
            out.append(avcc[body..<body + length])
            i = body + length
        }
        return out
    }
}
