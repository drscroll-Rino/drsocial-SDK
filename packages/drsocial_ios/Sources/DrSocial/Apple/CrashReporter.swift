import Darwin
import Foundation
import MachO

// What the signal handler may touch: set up once, before any signal, so the handler only calls write() and backtrace().
private var drsCrashFd: Int32 = -1
private var drsExceptionWritten: Int32 = 0
private var drsLineBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
private var drsFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
private var drsPrevious = UnsafeMutablePointer<sigaction>.allocate(capacity: 32)
private var drsHasPrevious = UnsafeMutablePointer<Bool>.allocate(capacity: 32)
private var drsPreviousException: (@convention(c) (NSException) -> Void)?

private func drsWriteText(_ s: StaticString) {
    _ = write(drsCrashFd, s.utf8Start, s.utf8CodeUnitCount)
}

/// Writes `<prefix><hex>\n` with no allocation.
private func drsWriteHexLine(_ prefix: UInt8, _ value: UInt64, decimal: Bool = false) {
    var n = 0
    // "addr 0x" or "signal "
    if prefix == 0 {
        for c in "addr 0x".utf8 { drsLineBuffer[n] = c; n += 1 }
    } else {
        for c in "signal ".utf8 { drsLineBuffer[n] = c; n += 1 }
    }
    let radix: UInt64 = decimal ? 10 : 16
    var tmp = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
               UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
               UInt8(0), UInt8(0), UInt8(0), UInt8(0))
    var count = 0
    var v = value
    withUnsafeMutableBytes(of: &tmp) { t in
        repeat {
            let d = UInt8(v % radix)
            t[count] = d < 10 ? 48 + d : 87 + d
            count += 1
            v /= radix
        } while v > 0 && count < 20
        for i in stride(from: count - 1, through: 0, by: -1) { drsLineBuffer[n] = t[i]; n += 1 }
    }
    drsLineBuffer[n] = 10
    n += 1
    _ = write(drsCrashFd, drsLineBuffer, n)
}

private func drsSignalHandler(_ sig: Int32) {
    if drsCrashFd >= 0 && drsExceptionWritten == 0 {
        drsWriteHexLine(1, UInt64(sig), decimal: true)
        let count = backtrace(drsFrames, 64)
        // The first frames are this handler and the system's trampoline.
        for i in 0..<Int(count) {
            if let p = drsFrames[i] { drsWriteHexLine(0, UInt64(UInt(bitPattern: p))) }
        }
        fsync(drsCrashFd)
    }
    // Hand the signal to whoever had it, else let the system end the app.
    if sig > 0 && sig < 32 && drsHasPrevious[Int(sig)] {
        sigaction(sig, drsPrevious + Int(sig), nil)
    } else {
        signal(sig, SIG_DFL)
    }
    raise(sig)
}

private func drsExceptionHandler(_ e: NSException) {
    CrashReporter.shared?.save(exception: e)
    drsExceptionWritten = 1
    drsPreviousException?(e)
}

/// Fatal crashes: an uncaught NSException and the fatal signals (a Swift trap, a bad access…). They are written to disk
/// while the app dies and sent on the next launch ([pending], then [markSent]).
public final class CrashReporter {
    public static private(set) var shared: CrashReporter?

    public let dir: URL
    private let launch = newSdkId()
    private let appVersion: String
    private let osVersion: String
    /// The screen shown now (a caught NSException carries it).
    public var screen: String?

    public init(appVersion: String, osVersion: String, dir: URL? = nil) {
        let base = dir ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DrSocial/crashes", isDirectory: true))
        self.dir = base
        self.appVersion = appVersion
        self.osVersion = osVersion
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    /// Starts catching (once per process).
    public func install() {
        guard CrashReporter.shared == nil else { return }
        CrashReporter.shared = self
        let images = CrashReporter.loadedImages()
        try? LoadedImage.writeMap(images).write(to: dir.appendingPathComponent("\(launch).images"), atomically: true, encoding: .utf8)
        try? Json.encode(["app_version": appVersion, "os_version": osVersion]).write(to: dir.appendingPathComponent("\(launch).meta"), atomically: true, encoding: .utf8)
        drsCrashFd = open(dir.appendingPathComponent("\(launch).log").path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)

        drsPreviousException = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(drsExceptionHandler)

        drsHasPrevious.initialize(repeating: false, count: 32)
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGSYS] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = drsSignalHandler
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            drsHasPrevious[Int(sig)] = sigaction(sig, &action, drsPrevious + Int(sig)) == 0
        }
    }

    /// An uncaught exception: its type and the stack where it was thrown. Its reason is never sent (it may hold personal data).
    func save(exception e: NSException) {
        let images = CrashReporter.loadedImages()
        let frames = e.callStackReturnAddresses.prefix(40).map { n -> SdkFrame in
            let a = n.uint64Value
            return CrashFormat.frame(address: a, images: images, symbol: CrashReporter.symbol(a))
        }
        let crash = SdkCrash(kind: "fatal", type: e.name.rawValue, frames: Array(frames), appVersion: appVersion, osVersion: osVersion, screen: screen)
        try? Json.encode(crash.toMap()).write(to: dir.appendingPathComponent("\(crash.id).crash"), atomically: true, encoding: .utf8)
    }

    /// A caught error the app reports (kind non_fatal), with the stack where it was reported.
    public func nonFatal(type: String) -> SdkCrash {
        let images = CrashReporter.loadedImages()
        let frames = Thread.callStackReturnAddresses.dropFirst().prefix(40).map { n -> SdkFrame in
            let a = n.uint64Value
            return CrashFormat.frame(address: a, images: images, symbol: CrashReporter.symbol(a))
        }
        return SdkCrash(kind: "non_fatal", type: type, frames: Array(frames), appVersion: appVersion, osVersion: osVersion, screen: screen)
    }

    /// The crashes of earlier launches, oldest first, with the files that hold them.
    public func pending() -> [(crash: SdkCrash, files: [URL])] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [(SdkCrash, [URL], Date)] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            let at = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
            if name.hasSuffix(".crash"), let text = try? String(contentsOf: url, encoding: .utf8) {
                out.append((SdkCrash.parse(text), [url], at))
            } else if name.hasSuffix(".log") {
                let id = String(name.dropLast(4))
                if id == launch { continue }
                let imagesUrl = dir.appendingPathComponent("\(id).images"), metaUrl = dir.appendingPathComponent("\(id).meta")
                let files = [url, imagesUrl, metaUrl]
                guard let log = try? String(contentsOf: url, encoding: .utf8), !log.isEmpty else {
                    files.forEach { try? fm.removeItem(at: $0) }
                    continue
                }
                let images = LoadedImage.parseMap((try? String(contentsOf: imagesUrl, encoding: .utf8)) ?? "")
                let meta = Json.parseObject((try? String(contentsOf: metaUrl, encoding: .utf8)) ?? "")
                let version = meta.str("app_version")
                let named = version == appVersion ? CrashReporter.nameFrames(log, images: images) : log
                if let crash = CrashFormat.fromLog(named, images: images, appVersion: version, osVersion: meta.str("os_version"), at: at) {
                    out.append((crash, files, at))
                } else {
                    files.forEach { try? fm.removeItem(at: $0) }
                }
            }
        }
        return out.sorted { $0.2 < $1.2 }.map { ($0.0, $0.1) }
    }

    public func markSent(_ files: [URL]) {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Same release as the crashed launch: the same binaries, so a frame's symbol is found at its offset in today's image.
    static func nameFrames(_ log: String, images: [LoadedImage]) -> String {
        let now = loadedImages()
        var extra: [String] = []
        for line in log.split(separator: "\n") where line.hasPrefix("addr ") {
            guard let a = CrashFormat.parseHex(String(line.dropFirst(5))), let img = CrashFormat.image(for: a, in: images),
                  let cur = now.first(where: { $0.name == img.name }) else { continue }
            if let s = symbol(cur.base + (a - img.base)) { extra.append("sym \(String(a, radix: 16)) \(s)") }
        }
        return extra.isEmpty ? log : log + "\n" + extra.joined(separator: "\n")
    }

    static func symbol(_ address: UInt64) -> String? {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: UInt(address)), &info) != 0, let s = info.dli_sname else { return nil }
        return String(cString: s)
    }

    /// Every image loaded now: its file name, load address and `__TEXT` size.
    public static func loadedImages() -> [LoadedImage] {
        var out: [LoadedImage] = []
        for i in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(i), let cname = _dyld_get_image_name(i) else { continue }
            let name = (String(cString: cname) as NSString).lastPathComponent
            out.append(LoadedImage(name: name, base: UInt64(UInt(bitPattern: header)), size: textSize(header)))
        }
        return out
    }

    private static func textSize(_ header: UnsafePointer<mach_header>) -> UInt64 {
        guard header.pointee.magic == MH_MAGIC_64 else { return 0 }
        var cmd = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let lc = cmd.assumingMemoryBound(to: load_command.self).pointee
            if lc.cmd == LC_SEGMENT_64 {
                let seg = cmd.assumingMemoryBound(to: segment_command_64.self).pointee
                let name = withUnsafeBytes(of: seg.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if name == "__TEXT" { return seg.vmsize }
            }
            cmd = cmd.advanced(by: Int(lc.cmdsize))
        }
        return 0
    }
}
