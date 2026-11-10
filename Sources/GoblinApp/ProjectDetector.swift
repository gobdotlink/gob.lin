import AppKit
import ApplicationServices
import GoblinCore

/// Finds the project open in the app where dictation starts, for project-scoped dictionary terms.
/// Runs off the main thread with node and time limits, so it never delays recording. Results read from the interface
/// or a repository walk are cached briefly by page address or document; other apps' storage is read each time, so
/// renamed projects apply at once.
actor ProjectDetector {
    private static let cacheLifetime: Duration = .seconds(300)
    /// Every accessibility call: each element has its own timeout, and the deadline can't interrupt a call in progress.
    private static let messagingTimeout: Float = 0.2
    private var cache: [String: (project: DetectedProject, expires: ContinuousClock.Instant)] = [:]

    /// The project open in the frontmost window of `pid`, or nil when nothing identifies one.
    func detect(pid: pid_t, bundleIdentifier: String?, budget: Duration = .milliseconds(1500)) -> DetectedProject? {
        let deadline = ContinuousClock.now.advanced(by: budget)
        let bundle = bundleIdentifier ?? ""
        let isT3 = bundle.hasPrefix(ProjectResolution.t3CodeBundlePrefix), isPaseo = bundle == ProjectResolution.paseoBundle
        // Dictation has already asked Electron apps such as these to build their web accessibility tree.
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        guard let window = Self.element(app, kAXFocusedWindowAttribute) ?? Self.element(app, kAXMainWindowAttribute) else { return nil }

        if let document = Self.string(window, kAXDocumentAttribute),
           let url = document.hasPrefix("/") ? URL(fileURLWithPath: document) : URL(string: document), url.isFileURL {
            if let cached = cached(bundle + "|" + url.path) { return cached }
            if let root = ProjectResolution.repositoryRoot(containing: url) {
                return remember(DetectedProject(name: root.lastPathComponent, source: .repository, root: root), key: bundle + "|" + url.path)
            }
        }
        if bundle == ProjectResolution.slackBundle {
            return Self.string(window, kAXTitleAttribute)
                .flatMap { ProjectResolution.slackWorkspace(fromTitle: $0, known: ProjectResolution.slackWorkspaceNames()) }
                .map { DetectedProject(name: $0, source: .slackWindow) }
        }
        if bundle == ProjectResolution.codexBundle {
            return Self.string(window, kAXTitleAttribute).flatMap { ProjectResolution.codexProject(threadTitle: $0) }
                .map { DetectedProject(name: $0.name, source: .codexDatabase, root: $0.root) }
        }
        if bundle == ProjectResolution.claudeBundle {
            // The window holds an app shell and the claude.ai page; only the page names the session.
            guard let web = Self.webArea(in: window, deadline: deadline, accepting: { ProjectResolution.claudeSessionID(fromAddress: $0) != nil }),
                  let session = Self.string(web, "AXURL").flatMap(ProjectResolution.claudeSessionID(fromAddress:)) else { return nil }
            return ProjectResolution.claudeProject(sessionID: session)
                .map { DetectedProject(name: $0.name, source: .claudeSession, root: $0.root) }
        }
        guard isT3 || isPaseo, let web = Self.webArea(in: window, deadline: deadline),
              let address = Self.string(web, "AXURL") else { return nil }
        if isT3, let thread = ProjectResolution.t3ThreadID(fromAddress: address),
           let title = ProjectResolution.t3ProjectTitle(threadID: thread) {
            return DetectedProject(name: title, source: .t3Database, root: ProjectResolution.t3ProjectRoot(threadID: thread))
        }
        if isPaseo, let workspace = ProjectResolution.paseoWorkspaceID(fromAddress: address),
           let project = ProjectResolution.paseoProject(workspaceID: workspace) {
            return DetectedProject(name: project.name, source: .paseoWorkspaces, root: project.root)
        }
        let key = bundle + "|" + address
        if let cached = cached(key) { return cached }
        guard !Task.isCancelled else { return nil }
        // Remote threads and workspaces exist only on another machine; read the project from the visible interface.
        let nodes = Self.interface(of: web, deadline: deadline)
        if isT3, let name = ProjectResolution.t3Project(fromInterface: nodes) {
            return remember(DetectedProject(name: name, source: .t3Interface), key: key)
        }
        if isPaseo, let name = ProjectResolution.paseoProject(fromInterface: nodes) {
            // Paseo's styling can move between workspaces without the address changing, so this is not cached.
            return DetectedProject(name: name, source: .paseoInterface)
        }
        return nil
    }

    private func cached(_ key: String) -> DetectedProject? {
        guard let entry = cache[key], entry.expires > .now else { return nil }
        return entry.project
    }

    private func remember(_ project: DetectedProject, key: String) -> DetectedProject {
        if cache.count > 200 { cache.removeAll() }
        cache[key] = (project, ContinuousClock.now.advanced(by: Self.cacheLifetime))
        return project
    }

    // MARK: Accessibility reading

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        let value = attribute(element, name)
        if let text = value as? String, !text.isEmpty { return text }
        return (value as? URL)?.absoluteString
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// The first web area in a window whose address `accepting` allows, breadth-first and shallow.
    private static func webArea(in window: AXUIElement, deadline: ContinuousClock.Instant,
                                accepting: (String) -> Bool = { _ in true }) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        while index < queue.count, index < 400, ContinuousClock.now < deadline, !Task.isCancelled {
            let (element, depth) = queue[index]
            index += 1
            if string(element, kAXRoleAttribute) == "AXWebArea", accepting(string(element, "AXURL") ?? "") { return element }
            if depth < 10 { queue += children(element).prefix(50).map { ($0, depth + 1) } }
        }
        return nil
    }

    /// Buttons in document order with their labels and class lists, within node and time limits.
    private static func interface(of root: AXUIElement, deadline: ContinuousClock.Instant) -> [ProjectResolution.InterfaceNode] {
        var nodes: [ProjectResolution.InterfaceNode] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < 6000, ContinuousClock.now < deadline, !Task.isCancelled {
            visited += 1
            if string(element, kAXRoleAttribute) == "AXButton" {
                let label = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute) ?? ""
                let classes = (attribute(element, "AXDOMClassList") as? [String])?.joined(separator: " ") ?? ""
                nodes.append(.init(role: "AXButton", depth: depth, label: label, classes: classes))
            }
            if depth < 60 { stack += children(element).reversed().map { ($0, depth + 1) } }
        }
        return nodes
    }
}
