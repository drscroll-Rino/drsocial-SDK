import Foundation

/// One Mach-O image loaded in the process: its file name and where it was loaded (ASLR moves it every launch).
public struct LoadedImage: Equatable {
    public let name: String
    public let base: UInt64
    /// Its `__TEXT` size; 0 = unknown (then the nearest image below an address is taken).
    public let size: UInt64

    public init(name: String, base: UInt64, size: UInt64 = 0) {
        self.name = name
        self.base = base
        self.size = size
    }

    /// The images as the crash files keep them: one per line, `<base hex> <size hex> <name>`.
    public static func writeMap(_ images: [LoadedImage]) -> String {
        images.map { "\(String($0.base, radix: 16)) \(String($0.size, radix: 16)) \($0.name)" }.joined(separator: "\n")
    }

    public static func parseMap(_ text: String) -> [LoadedImage] {
        text.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ", maxSplits: 2)
            guard p.count == 3, let base = UInt64(p[0], radix: 16), let size = UInt64(p[1], radix: 16) else { return nil }
            return LoadedImage(name: String(p[2]), base: base, size: size)
        }
    }
}

/// Turns what the runtime gives into the platform's crash shape. An iOS frame carries `lib` (its image's name) and `offset`
/// (hex: the address minus the image's load address), so the platform finds its line in the release's symbol table.
public enum CrashFormat {
    /// The image holding [address]: the one whose range covers it, else the nearest one loaded below it.
    public static func image(for address: UInt64, in images: [LoadedImage]) -> LoadedImage? {
        var best: LoadedImage?
        for i in images where i.base <= address {
            if i.size > 0 && address >= i.base + i.size { continue }
            if best == nil || i.base > best!.base { best = i }
        }
        return best
    }

    /// One frame: `lib` + `offset` ("0x…", lower case), and [symbol] as `fn` when the runtime knew it.
    public static func frame(address: UInt64, images: [LoadedImage], symbol: String? = nil) -> SdkFrame {
        guard let img = image(for: address, in: images) else {
            return SdkFrame(fn: symbol ?? "0x" + String(address, radix: 16))
        }
        let offset = "0x" + String(address - img.base, radix: 16)
        return SdkFrame(fn: symbol ?? "\(img.name) + \(offset)", lib: img.name, offset: offset)
    }

    /// The names of the signals the SDK catches.
    public static let signalNames: [Int32: String] = [
        SIGABRT: "SIGABRT", SIGSEGV: "SIGSEGV", SIGBUS: "SIGBUS", SIGILL: "SIGILL", SIGFPE: "SIGFPE", SIGTRAP: "SIGTRAP", SIGSYS: "SIGSYS",
    ]

    /// A crash file written while the app died. Its lines: `type <name>` or `signal <n>`, then `addr <hex>` per frame
    /// (first = where it failed), optionally `sym <hex> <name>` for frames the runtime named. [images] = that launch's map.
    public static func fromLog(_ log: String, images: [LoadedImage], appVersion: String? = nil, osVersion: String? = nil,
                               screen: String? = nil, at: Date = Date()) -> SdkCrash? {
        var type: String?
        var addresses: [UInt64] = []
        var symbols: [UInt64: String] = [:]
        for raw in log.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("signal ") {
                let n = Int32(line.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 0
                type = signalNames[n] ?? "SIG\(n)"
            } else if line.hasPrefix("type ") {
                type = String(line.dropFirst(5))
            } else if line.hasPrefix("addr "), let a = parseHex(String(line.dropFirst(5))) {
                addresses.append(a)
            } else if line.hasPrefix("sym ") {
                let p = line.dropFirst(4).split(separator: " ", maxSplits: 1)
                if p.count == 2, let a = parseHex(String(p[0])) { symbols[a] = String(p[1]) }
            }
        }
        guard let t = type else { return nil }
        let frames = addresses.prefix(40).map { frame(address: $0, images: images, symbol: symbols[$0]) }
        return SdkCrash(kind: "fatal", type: t, frames: Array(frames), appVersion: appVersion, osVersion: osVersion, screen: screen, at: at)
    }

    static func parseHex(_ s: String) -> UInt64? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return UInt64(t.hasPrefix("0x") ? String(t.dropFirst(2)) : t, radix: 16)
    }
}
