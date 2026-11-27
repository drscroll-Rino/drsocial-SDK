#if os(iOS)
import StoreKit
import UIKit
import UserNotifications

public struct DrSocialOptions {
    /// The build's key (32 hex) from Settings → 📱 Mobile app, one per store build.
    public var buildKey: String
    /// The platform's Ed25519 public keys this release trusts, {"v1": base64}.
    public var trustedKeys: [String: String]
    public var base: String = "https://social.drscroll.com/api/v1"
    /// Prove the app with App Attest at registration and on each token (needs the App Attest capability).
    public var appAttest: Bool = true
    /// Send a DeviceCheck token so a ban can follow the phone.
    public var deviceCheck: Bool = true
    /// Catch fatal crashes (NSException and signals) and send them on the next launch.
    public var crashes: Bool = true
    /// Show the SDK's own full-screen block for a stopped phone and a required update.
    public var blockScreens: Bool = true
    /// Open a link (a notification's, a button's, a deferred link).
    public var onLink: ((String) -> Void)?
    /// The config was read (remote values, features).
    public var onConfig: ((SdkConfig) -> Void)?
    /// In-app messages, inbox, surveys, tours to show.
    public var onMessages: (([JsonObject]) -> Void)?
    /// The phone was stopped: [message] ('' = the SDK's default), [until] (nil = until lifted).
    public var onBanned: ((String, Date?) -> Void)?
    /// The link that opened the app on its first run (iOS has no install referrer), for attribution.
    public var openingLink: String?

    public init(buildKey: String, trustedKeys: [String: String]) {
        self.buildKey = buildKey
        self.trustedKeys = trustedKeys
    }
}

/// The DrSocial SDK for iOS. `DrSocial.start(options)` once in `application(_:didFinishLaunchingWithOptions:)`, then
/// `DrSocial.shared`. Every call is safe offline; a feature off in the config does nothing.
public final class DrSocial {
    private static var instance: DrSocial?
    public static var shared: DrSocial {
        guard let i = instance else { fatalError("DrSocial.start(_:) first") }
        return i
    }

    /// Whether `start(_:)` was called (`shared` stops the app before then).
    public static var isStarted: Bool { instance != nil }

    public let client: DrSocialClient
    public let options: DrSocialOptions
    public private(set) var config: SdkConfig = .empty
    private let store: SdkStore
    private let crashes: CrashReporter?
    private let live = LiveSession()
    private var queue: [SdkEvent] = []
    private let lock = NSLock()
    private var stopped = false
    private var timer: Timer?
    private var nextPing: Date = .distantPast
    private var currentScreen: String?
    private var blockWindow: UIWindow?

    @discardableResult
    public static func start(_ options: DrSocialOptions) -> DrSocial {
        if let i = instance { return i }
        let i = DrSocial(options)
        instance = i
        i.begin()
        return i
    }

    private init(_ options: DrSocialOptions) {
        self.options = options
        store = UserDefaultsSdkStore()
        let device = UIDevice.current
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        client = DrSocialClient(buildKey: options.buildKey, installId: DeviceIds.installId(store), trustedKeys: options.trustedKeys,
                                base: options.base, store: store, os: device.systemVersion, appVersion: appVersion,
                                hardwareId: DeviceIds.hardwareId(vendorId: device.identifierForVendor?.uuidString))
        crashes = options.crashes ? CrashReporter(appVersion: appVersion, osVersion: device.systemVersion) : nil
        if let raw = store.read("queue"), let arr = Json.parseAny(raw) as? [Any] {
            queue = arr.objects().map(SdkEvent.from)
        }
    }

    private func begin() {
        crashes?.install()
        let attest = options.appAttest ? AppAttest() : nil
        let signer: DeviceSigner? = try? SecureEnclaveSigner()
        Task {
            if let signer = signer {
                await client.use(signer, attest: attest?.isSupported == true ? attest?.attestationMaker : nil,
                                 assertion: attest?.isSupported == true ? attest?.assertionMaker : nil,
                                 deviceCheck: options.deviceCheck ? DeviceCheckToken.maker : nil)
            }
            await guarded { try await self.firstRun() }
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(foreground), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    // MARK: start

    private func firstRun() async throws {
        try await refreshConfig()
        if config.feature("crash_lines") { await sendCrashes() }
        if config.feature("attribution") { try await client.attribution(link: options.openingLink) }
        if config.feature("deferred_links"), let link = try await client.deferred() { onMain { self.options.onLink?(link.link) } }
        if config.feature("app_icons") { await applyIcon() }
        if ["in_app", "inbox", "surveys", "tours"].contains(where: config.feature) { try await refreshMessages() }
        await flush()
    }

    /// Reads the config again (honouring its ttl unless [force]), then shows a required update.
    public func refreshConfig(force: Bool = false) async throws {
        let c = force ? try await client.refresh() : try await client.refreshIfStale()
        config = c
        onMain {
            self.options.onConfig?(c)
            let u = c.update(self.client.appVersion)
            if u.need == .required && self.options.blockScreens { self.showBlock(message: u.message, url: u.url) }
        }
    }

    public func refreshMessages() async throws {
        let list = try await client.messages()
        onMain { self.options.onMessages?(list) }
    }

    // MARK: who and what

    public func identify(_ externalId: String, identityHash: String? = nil, traits: [String: Any]? = nil, analytics: Bool? = nil,
                         messages: Bool? = nil, profile: [String: String]? = nil) {
        run { try await self.client.identify(externalId, identityHash: identityHash, traits: traits, analytics: analytics, messages: messages,
                                             locale: Locale.current.identifier, country: Locale.current.regionCode, profile: profile) }
    }

    public func signOut() { run { try await self.client.signOut() } }

    /// Kept on the phone and sent in batches of up to 100; offline is fine. Never put personal data in [props].
    public func track(_ name: String, _ props: [String: Any] = [:]) {
        let count: Int = locked {
            queue.append(SdkEvent(name, props: props))
            if queue.count > 1000 { queue.removeFirst(queue.count - 1000) }
            saveQueueLocked()
            return queue.count
        }
        if count >= 50 { Task { await flush() } }
    }

    /// The screen shown now; its ids become `{id}`.
    public func screen(_ route: String) {
        let name = screenName(route)
        currentScreen = name
        crashes?.screen = name
        track("screen_view", ["screen": name])
        if config.feature("live") { run { _ = try await self.client.live(self.live.id, kind: "screen", screen: name) } }
    }

    /// A caught error (kind non_fatal) with the stack where it was reported; its message is never sent.
    public func reportError(_ error: Error) {
        guard let c = crashes else { return }
        let crash = c.nonFatal(type: String(reflecting: type(of: error)))
        run { if self.config.feature("crash_lines") { try await self.client.crashes([crash]) } }
    }

    /// Sends the kept events now.
    public func flush() async {
        let batch = locked { queue }
        guard !batch.isEmpty, !stopped else { return }
        do {
            _ = try await client.track(batch)
            let sent = Set(batch.map { $0.id })
            locked {
                queue.removeAll { sent.contains($0.id) }
                saveQueueLocked()
            }
        } catch let e as SdkBanned {
            banned(e)
        } catch {
            // Kept with the same ids: sent again later and kept once.
        }
    }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    private func saveQueueLocked() {
        store.write("queue", Json.encode(queue.map { $0.toMap() }))
    }

    /// The company's site with the device id, so a ban on the phone also holds there.
    public func siteUrl(_ url: String) async -> String { await client.siteUrl(url) }

    // MARK: remote values

    public func string(_ key: String, _ fallback: String = "") -> String {
        config.string(key, fallback, installId: client.installId, appVersion: client.appVersion)
    }

    public func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        config.bool(key, fallback, installId: client.installId, appVersion: client.appVersion)
    }

    public func int(_ key: String, _ fallback: Int = 0) -> Int {
        config.int(key, fallback, installId: client.installId, appVersion: client.appVersion)
    }

    public func double(_ key: String, _ fallback: Double = 0) -> Double {
        config.double(key, fallback, installId: client.installId, appVersion: client.appVersion)
    }

    public func json(_ key: String) -> Any? {
        config.json(key, nil, installId: client.installId, appVersion: client.appVersion)
    }

    public var update: UpdateAdvice { config.update(client.appVersion) }

    // MARK: push

    /// Asks for notifications ([provisional] = quietly, without a prompt), then registers for APNs.
    public func requestPush(provisional: Bool = false) {
        var opts: UNAuthorizationOptions = [.alert, .sound, .badge]
        if provisional { opts.insert(.provisional) }
        UNUserNotificationCenter.current().requestAuthorization(options: opts) { _, _ in
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// From `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`: the APNs token as hex with `apns`.
    public func setPushToken(_ deviceToken: Data) {
        let token = hexString(deviceToken)
        run {
            let permission = await DrSocialPush.currentPermission()
            guard self.config.feature("push") else { return }
            let key = "apns|\(token)|\(permission)"
            if self.store.read("push_sent") == key { return }
            if try await self.client.pushToken(provider: "apns", token: token, permission: permission) { self.store.write("push_sent", key) }
        }
    }

    /// From `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`: `drs_silent: refresh` reads the config,
    /// the messages and the remote values again; `ping` does nothing at all. Answers false when it was not ours.
    @discardableResult
    public func handleRemoteNotification(_ userInfo: [AnyHashable: Any], completion: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
        let push = DrsPush(userInfo: userInfo)
        guard push.isDrSocial, let silent = push.silent else { return false }
        if silent != "refresh" {
            completion(.noData)
            return true
        }
        Task {
            await guarded {
                try await self.refreshConfig(force: true)
                try await self.refreshMessages()
            }
            completion(.newData)
        }
        return true
    }

    /// From `userNotificationCenter(_:willPresent:withCompletionHandler:)`: plays the pattern while the app is open.
    /// Answers the options to show it with, or nil when it is not ours.
    public func willPresent(_ notification: UNNotification) -> UNNotificationPresentationOptions? {
        let push = DrsPush(userInfo: notification.request.content.userInfo)
        guard push.isDrSocial else { return nil }
        DrSocialPush.registerCategory(for: push)
        DrSocialHaptics.play(push)
        return [.banner, .list, .sound]
    }

    /// From `userNotificationCenter(_:didReceive:withCompletionHandler:)`: reports the open (with the pressed button) and
    /// opens its link. Answers false when it is not ours.
    @discardableResult
    public func didReceive(_ response: UNNotificationResponse) -> Bool {
        let push = DrsPush(userInfo: response.notification.request.content.userInfo)
        guard push.isDrSocial, let id = push.push else { return false }
        let pressed = push.buttons.first { $0.id == response.actionIdentifier }
        let link = pressed?.link ?? (response.actionIdentifier == UNNotificationDefaultActionIdentifier ? push.link : "")
        run { try await self.client.pushOpened(id, action: pressed?.id) }
        if !link.isEmpty { onMain { self.options.onLink?(link) } }
        return true
    }

    // MARK: review, icons, live activities

    /// After a success, never on launch: asks the platform, and on a yes opens the store's own review box.
    public func askReviewIfDue(in scene: UIWindowScene? = nil) {
        run {
            guard self.config.feature("store_review") else { return }
            let answer = try await self.client.review()
            guard answer.ask else { return }
            self.onMain {
                let s = scene ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
                if let s = s { SKStoreReviewController.requestReview(in: s) }
            }
        }
    }

    /// Shows the icon the config's schedule names now (`setAlternateIconName`) and reports the icons to the platform.
    public func applyIcon() async {
        guard let wanted = config.iconAt(Date()) else { return }
        let available = config.availableIcons
        let current: String = await MainActor.run {
            let app = UIApplication.shared
            let now = app.alternateIconName ?? ""
            if app.supportsAlternateIcons && now != wanted {
                app.setAlternateIconName(wanted.isEmpty ? nil : wanted) { _ in }
            }
            return now
        }
        let shown = current == wanted ? current : wanted
        if store.read("icons_sent") != "\(client.appVersion)|\(shown)" {
            do {
                try await client.reportIcons(available: available, current: shown)
                store.write("icons_sent", "\(client.appVersion)|\(shown)")
            } catch let e as SdkBanned { banned(e) } catch {}
        }
    }

    /// A Live Activity's token (see `DrSocialLiveActivities.observe` for the automatic way).
    public func liveActivity(kind: String, type: String, activity: String? = nil, token: String? = nil) {
        run {
            guard self.config.feature("live_activities") else { return }
            try await self.client.liveActivity(kind: kind, type: type, activity: activity, token: token)
        }
    }

    // MARK: crashes

    private func sendCrashes() async {
        guard let c = crashes else { return }
        let pending = c.pending()
        guard !pending.isEmpty else { return }
        do {
            for part in pending.chunked(20) {
                try await client.crashes(part.map { $0.crash })
                c.markSent(part.flatMap { $0.files })
            }
        } catch let e as SdkBanned { banned(e) } catch {}
    }

    // MARK: lifecycle

    @objc private func foreground() {
        let isNew = live.front(Date())
        run {
            try await self.refreshConfig()
            if self.config.feature("live") {
                if let ping = try await self.client.live(self.live.id, kind: isNew ? "open" : "ping", screen: self.currentScreen) {
                    self.nextPing = Date().addingTimeInterval(Double(ping))
                }
            }
            if self.config.feature("app_icons") { await self.applyIcon() }
        }
        if isNew { track("app_open") }
    }

    @objc private func background() {
        live.back(Date())
        let app = UIApplication.shared
        let task = BackgroundTask()
        task.id = app.beginBackgroundTask { app.endBackgroundTask(task.id) }
        Task {
            if config.feature("live") { _ = try? await client.live(live.id, kind: "close") }
            await flush()
            await MainActor.run { app.endBackgroundTask(task.id) }
        }
    }

    private func tick() {
        Task { await flush() }
        guard UIApplication.shared.applicationState == .active, config.feature("live"), Date() >= nextPing else { return }
        run {
            if let ping = try await self.client.live(self.live.id, kind: "ping", screen: self.currentScreen) {
                self.nextPing = Date().addingTimeInterval(Double(ping))
            }
        }
    }

    // MARK: stopped phones

    private func run(_ work: @escaping () async throws -> Void) {
        guard !stopped else { return }
        Task { await guarded(work) }
    }

    private func guarded(_ work: () async throws -> Void) async {
        guard !stopped else { return }
        do { try await work() } catch let e as SdkBanned { banned(e) } catch {}
    }

    private func banned(_ e: SdkBanned) {
        stopped = true
        onMain {
            self.timer?.invalidate()
            self.options.onBanned?(e.message, e.until)
            if self.options.blockScreens { self.showBlock(message: e.message.isEmpty ? "This app can't be used on this phone." : e.message, url: "") }
        }
    }

    private func showBlock(message: String, url: String) {
        guard blockWindow == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.rootViewController = BlockViewController(message: message, url: url)
        w.makeKeyAndVisible()
        blockWindow = w
    }

    private func onMain(_ f: @escaping @MainActor () -> Void) { Task { @MainActor in f() } }
}

private final class BackgroundTask { var id: UIBackgroundTaskIdentifier = .invalid }

/// A full-screen block: a stopped phone (no button) or a required update (one button that opens the store page).
final class BlockViewController: UIViewController {
    private let message: String
    private let url: String

    init(message: String, url: String) {
        self.message = message
        self.url = url
        super.init(nibName: nil, bundle: nil)
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = message.isEmpty ? "Please update the app to continue." : message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .title3)
        label.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [label])
        stack.axis = .vertical
        stack.spacing = 24
        if let u = URL(string: url), u.scheme == "https" {
            let b = UIButton(type: .system)
            b.setTitle("Update", for: .normal)
            b.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            b.addAction(UIAction { _ in UIApplication.shared.open(u) }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -16),
        ])
    }
}
#endif
