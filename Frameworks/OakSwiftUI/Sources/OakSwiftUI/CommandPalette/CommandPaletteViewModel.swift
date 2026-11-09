import AppKit
import Combine

public enum PaletteMode: String, CaseIterable, Sendable {
	case recentProjects
	case commands
	case symbols
	case bundleEditor
	case goToLine
	case findInProject
	case settings

	public var prefix: Character? {
		switch self {
		case .recentProjects: return nil
		case .commands:       return ">"
		case .symbols:        return "@"
		case .bundleEditor:   return "#"
		case .goToLine:       return ":"
		case .findInProject:  return "/"
		case .settings:       return "~"
		}
	}

	public var label: String {
		switch self {
		case .recentProjects: return "Recent Projects"
		case .commands:       return "Commands"
		case .symbols:        return "Symbols"
		case .bundleEditor:   return "Bundles"
		case .goToLine:       return "Go to Line"
		case .findInProject:  return "Find"
		case .settings:       return "Settings"
		}
	}

	public var placeholder: String {
		switch self {
		case .recentProjects: return "Search recent projects..."
		case .commands:       return "Search commands..."
		case .symbols:        return "Search symbols..."
		case .bundleEditor:   return "Search bundles..."
		case .goToLine:       return "Type a line number..."
		case .findInProject:  return "Search in project..."
		case .settings:       return "Search settings..."
		}
	}

	public var intValue: Int {
		switch self {
		case .recentProjects: return 0
		case .commands:       return 1
		case .symbols:        return 2
		case .bundleEditor:   return 3
		case .goToLine:       return 4
		case .findInProject:  return 5
		case .settings:       return 6
		}
	}

	public init?(prefix: Character) {
		guard let mode = PaletteMode.allCases.first(where: { $0.prefix == prefix }) else {
			return nil
		}
		self = mode
	}
}

public struct RankedItem: Identifiable, Sendable {
	public let item: OakCommandPaletteItem
	public let matchedIndices: [Int]
	public let score: Double
	public var id: UUID { item.id }
}

public struct FrecencyEntry {
	public var count: Int
	public var lastUsed: TimeInterval

	public init(count: Int, lastUsed: TimeInterval) {
		self.count = count
		self.lastUsed = lastUsed
	}
}

@MainActor
public class CommandPaletteViewModel: ObservableObject {
	@Published public var filterText: String = "" {
		didSet { processFilterChange() }
	}
	@Published public private(set) var activeMode: PaletteMode = .recentProjects
	@Published public private(set) var filteredItems: [RankedItem] = []
	@Published public var selectedIndex: Int = 0
	@Published public var showsHiddenProjects = false {
		didSet { refreshProjectVisibility() }
	}
	public private(set) var hiddenWorkspaceIdentifiers: Set<String> = []
	public private(set) var hiddenProjectIdentifiers: Set<String> = []
	public private(set) var hiddenProjectWorkspaces: [String: [String]] = [:]
	public var onProjectVisibilityChanged: (() -> Void)?

	public var onItemSelected: ((OakCommandPaletteItem) -> Void)?
	public var onDismiss: (() -> Void)?
	public var onModeSwitch: ((PaletteMode) -> [OakCommandPaletteItem])?
	public var onSearchDocument: ((String) -> [OakCommandPaletteItem])?

	private var itemsByMode: [PaletteMode: [OakCommandPaletteItem]] = [:]
	public private(set) var frecencyData: [String: FrecencyEntry] = [:]

	public init() {}

	public var queryText: String {
		guard let prefix = activeMode.prefix, filterText.first == prefix else {
			return filterText
		}
		return String(filterText.dropFirst())
	}

	public func setItems(_ items: [OakCommandPaletteItem], forMode mode: PaletteMode) {
		itemsByMode[mode] = items
		if mode == activeMode {
			applyFilter()
		}
	}

	public func updateProjects(_ items: [OakCommandPaletteItem]) {
		let selection = selectedItem?.actionIdentifier
		let previousIndex = selectedIndex
		setItems(items, forMode: .recentProjects)
		if activeMode == .recentProjects {
			selectedIndex = filteredItems.firstIndex { $0.item.actionIdentifier == selection } ?? min(previousIndex, max(filteredItems.count - 1, 0))
		}
	}

	public var hasHiddenProjects: Bool {
		!hiddenWorkspaceIdentifiers.isEmpty || !hiddenProjectIdentifiers.isEmpty
	}

	public func loadProjectVisibility(workspaces: Set<String>, projects: Set<String>, projectWorkspaces: [String: [String]]) {
		hiddenWorkspaceIdentifiers = workspaces
		hiddenProjectIdentifiers = projects
		hiddenProjectWorkspaces = projectWorkspaces
		refreshProjectVisibility()
	}

	private func containsWorkspace(_ identifier: String, in hidden: String) -> Bool {
		identifier == hidden || identifier.hasPrefix(hidden + "/")
	}

	private func hiddenGroups(for item: OakCommandPaletteItem) -> Set<String> {
		let group = item.projectGroupIdentifier.isEmpty ? item.actionIdentifier : "project:" + item.projectGroupIdentifier
		return Set(hiddenProjectIdentifiers.filter { hidden in
			hidden == group || matchesHiddenWorkspace(item, identifier: hidden)
				|| (hiddenProjectWorkspaces[hidden] ?? []).contains { matchesHiddenWorkspace(item, identifier: $0) }
		})
	}

	private func matchesHiddenWorkspace(_ item: OakCommandPaletteItem, identifier: String) -> Bool {
		item.actionIdentifier == identifier || item.workspaceAliases.contains(identifier)
			|| (item.projectGroupIdentifier.isEmpty && containsWorkspace(item.actionIdentifier, in: identifier))
	}

	public func isProjectGroupHidden(_ item: OakCommandPaletteItem) -> Bool {
		!hiddenGroups(for: item).isEmpty
	}

	public func isProjectHidden(_ item: OakCommandPaletteItem) -> Bool {
		guard item.category == .recentProject else { return false }
		return isProjectGroupHidden(item) || hiddenWorkspaceIdentifiers.contains { matchesHiddenWorkspace(item, identifier: $0) }
	}

	public func hideWorkspace(_ item: OakCommandPaletteItem) {
		guard item.category == .recentProject else { return }
		hiddenWorkspaceIdentifiers.insert(item.actionIdentifier)
		projectVisibilityChanged()
	}

	public func hideProject(_ item: OakCommandPaletteItem) {
		guard item.category == .recentProject else { return }
		let group = item.projectGroupIdentifier.isEmpty ? item.actionIdentifier : "project:" + item.projectGroupIdentifier
		hiddenProjectIdentifiers.insert(group)
		let siblings = (itemsByMode[.recentProjects] ?? []).filter {
			item.projectGroupIdentifier.isEmpty ? $0.actionIdentifier == item.actionIdentifier : $0.projectGroupIdentifier == item.projectGroupIdentifier
		}
		// Remember known linked paths as well, so hidden projects stay hidden
		// before asynchronous Git discovery restores their group metadata.
		hiddenProjectWorkspaces[group] = Array(Set(siblings.map(\.actionIdentifier) + siblings.flatMap(\.workspaceAliases) + item.projectWorkspaceIdentifiers)).sorted()
		projectVisibilityChanged()
	}

	public func showWorkspace(_ item: OakCommandPaletteItem) {
		hiddenWorkspaceIdentifiers = hiddenWorkspaceIdentifiers.filter { !matchesHiddenWorkspace(item, identifier: $0) }
		projectVisibilityChanged()
	}

	public func showProject(_ item: OakCommandPaletteItem) {
		for group in hiddenGroups(for: item) {
			hiddenProjectIdentifiers.remove(group)
			hiddenProjectWorkspaces.removeValue(forKey: group)
		}
		projectVisibilityChanged()
	}

	public func restoreAllProjects() {
		hiddenWorkspaceIdentifiers.removeAll()
		hiddenProjectIdentifiers.removeAll()
		hiddenProjectWorkspaces.removeAll()
		projectVisibilityChanged()
	}

	private func projectVisibilityChanged() {
		refreshProjectVisibility()
		onProjectVisibilityChanged?()
	}

	private func refreshProjectVisibility() {
		updateProjects(itemsByMode[.recentProjects] ?? [])
	}

	public func selectNext() {
		if selectedIndex < filteredItems.count - 1 {
			selectedIndex += 1
		}
	}

	public func selectPrevious() {
		if selectedIndex > 0 {
			selectedIndex -= 1
		}
	}

	public func acceptSelection() {
		guard selectedIndex >= 0, selectedIndex < filteredItems.count else { return }
		let item = filteredItems[selectedIndex].item
		guard item.enabled else { return }
		onItemSelected?(item)
	}

	public func requestDismiss() {
		onDismiss?()
	}

	public func updateFrecency(for identifier: String, at timestamp: TimeInterval? = nil) {
		let ts = timestamp ?? Date().timeIntervalSinceReferenceDate
		var entry = frecencyData[identifier] ?? FrecencyEntry(count: 0, lastUsed: ts)
		entry.count += 1
		entry.lastUsed = ts
		frecencyData[identifier] = entry
	}

	public func frecencyBoost(for identifier: String) -> Double {
		guard let entry = frecencyData[identifier] else { return 0 }
		let now = Date().timeIntervalSinceReferenceDate
		let hoursSinceLastUse = (now - entry.lastUsed) / 3600.0
		return Double(min(entry.count, 20)) * exp(-hoursSinceLastUse / 168.0)
	}

	public func loadFrecency(_ data: [String: FrecencyEntry]) {
		frecencyData = data
	}

	public var selectedItem: OakCommandPaletteItem? {
		guard selectedIndex >= 0, selectedIndex < filteredItems.count else { return nil }
		return filteredItems[selectedIndex].item
	}

	private func processFilterChange() {
		let newMode: PaletteMode
		if let first = filterText.first, let mode = PaletteMode(prefix: first) {
			newMode = mode
		} else {
			newMode = .recentProjects
		}

		if newMode != activeMode {
			activeMode = newMode
			// goToLine generates synthetic items — no delegate needed
			if newMode != .goToLine {
				// Settings always re-fetch (titles change based on toggle state)
				let shouldRefresh = newMode == .settings || itemsByMode[newMode] == nil
				if shouldRefresh, let items = onModeSwitch?(newMode) {
					itemsByMode[newMode] = items.isEmpty ? nil : items
				}
			}
		}

		// Find mode searches the current document — re-query on every keystroke
		if activeMode == .findInProject {
			let q = queryText
			if !q.isEmpty, let items = onSearchDocument?(q), !items.isEmpty {
				itemsByMode[.findInProject] = items
			} else {
				itemsByMode[.findInProject] = nil
			}
		}

		applyFilter()
		selectedIndex = 0
	}

	private func applyFilter() {
		let query = queryText

		// GoToLine generates a synthetic item from the query
		if activeMode == .goToLine {
			filteredItems = goToLineItems(query: query)
			return
		}

		guard let storedItems = itemsByMode[activeMode] else {
			filteredItems = []
			return
		}
		let items = activeMode == .recentProjects && !showsHiddenProjects ? storedItems.filter { !isProjectHidden($0) } : storedItems

		if query.isEmpty {
			filteredItems = groupProjects(items.map { RankedItem(item: $0, matchedIndices: [], score: 0) })
			return
		}

		let matches = items
			.compactMap { item -> RankedItem? in
				let titleMatch = FuzzyMatcher.score(item.title, query: query)
				let searchMatch = item.searchText.isEmpty ? nil : FuzzyMatcher.score(item.searchText, query: query)
				guard let result = titleMatch ?? searchMatch else { return nil }
				let frecency = frecencyBoost(for: item.actionIdentifier)
				let combinedScore = Double(result.score) * (1.0 + frecency) * (titleMatch == nil ? 0.6 : 1.0)
				return RankedItem(item: item, matchedIndices: titleMatch?.matchedIndices ?? [], score: combinedScore)
			}
			.sorted { $0.score > $1.score }
		filteredItems = groupProjects(matches)
	}

	// Group after ranking: projects keep their recency/best-match order, and
	// matching workspaces stay together. Headers are presentation only and
	// never take up a keyboard selection index.
	private func groupProjects(_ items: [RankedItem]) -> [RankedItem] {
		guard activeMode == .recentProjects else { return items }
		var keys: [String] = []
		var groups: [String: [RankedItem]] = [:]
		for ranked in items {
			let group = ranked.item.projectGroupIdentifier
			let key = group.isEmpty ? "item:\(ranked.item.actionIdentifier)" : "group:\(group)"
			if groups[key] == nil { keys.append(key) }
			groups[key, default: []].append(ranked)
		}
		return keys.flatMap { groups[$0] ?? [] }
	}

	public func startsProjectGroup(at index: Int) -> Bool {
		guard activeMode == .recentProjects, filteredItems.indices.contains(index) else { return false }
		guard hasMultipleProjectWorkspaces(filteredItems[index].item) else { return false }
		let group = filteredItems[index].item.projectGroupIdentifier
		return !group.isEmpty && (index == 0 || filteredItems[index - 1].item.projectGroupIdentifier != group)
	}

	public func hasMultipleProjectWorkspaces(_ item: OakCommandPaletteItem) -> Bool {
		guard item.category == .recentProject, !item.projectGroupIdentifier.isEmpty else { return false }
		// Count the known checkouts, not just the current search matches. A
		// branch/path search must not make a multi-worktree project collapse.
		let siblings = (itemsByMode[.recentProjects] ?? []).filter { $0.projectGroupIdentifier == item.projectGroupIdentifier }
		return Set(siblings.map(\.actionIdentifier) + item.projectWorkspaceIdentifiers).count > 1
	}

	public func isCompactProject(_ item: OakCommandPaletteItem) -> Bool {
		item.category == .recentProject && !item.projectGroupIdentifier.isEmpty && !hasMultipleProjectWorkspaces(item)
	}

	public func projectGroupCaption(for identifier: String) -> String {
		let total = (itemsByMode[.recentProjects] ?? []).filter { $0.projectGroupIdentifier == identifier && (showsHiddenProjects || !isProjectHidden($0)) }.count
		let visible = filteredItems.filter { $0.item.projectGroupIdentifier == identifier }.count
		if visible != total { return "\(visible) of \(total) workspaces" }
		return "\(total) workspace\(total == 1 ? "" : "s")"
	}

	private func goToLineItems(query: String) -> [RankedItem] {
		let lineStr = query.isEmpty ? "..." : query
		let title = "Go to line \(lineStr)"
		let item = OakCommandPaletteItem(
			title: title, subtitle: "", keyEquivalent: "",
			category: .goToLine, actionIdentifier: "line:\(query)")
		return [RankedItem(item: item, matchedIndices: [], score: 0)]
	}

	// findInProject is no longer synthetic — items are provided by the delegate
}
