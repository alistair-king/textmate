import Foundation
import Testing
@testable import OakSwiftUI

@MainActor
@Suite("CommandPaletteViewModel")
struct CommandPaletteViewModelTests {
	@Test func defaultModeIsRecentProjects() {
		let vm = CommandPaletteViewModel()
		#expect(vm.activeMode == .recentProjects)
	}

	@Test func typingGreaterThanSwitchesToCommandsMode() {
		let vm = CommandPaletteViewModel()
		vm.filterText = ">format"
		#expect(vm.activeMode == .commands)
		#expect(vm.queryText == "format")
	}

	@Test func typingAtSwitchesToSymbolsMode() {
		let vm = CommandPaletteViewModel()
		vm.filterText = "@viewDidLoad"
		#expect(vm.activeMode == .symbols)
		#expect(vm.queryText == "viewDidLoad")
	}

	@Test func typingColonSwitchesToGoToLineMode() {
		let vm = CommandPaletteViewModel()
		vm.filterText = ":42"
		#expect(vm.activeMode == .goToLine)
		#expect(vm.queryText == "42")
	}

	@Test func typingTildeSwitchesToSettingsMode() {
		let vm = CommandPaletteViewModel()
		vm.filterText = "~wrap"
		#expect(vm.activeMode == .settings)
		#expect(vm.queryText == "wrap")
	}

	@Test func typingSlashSwitchesToFindMode() {
		let vm = CommandPaletteViewModel()
		vm.filterText = "/auth"
		#expect(vm.activeMode == .findInProject)
		#expect(vm.queryText == "auth")
	}

	@Test func typingHashSwitchesToBundleEditorMode() {
		let vm = CommandPaletteViewModel()
		vm.filterText = "#ruby"
		#expect(vm.activeMode == .bundleEditor)
		#expect(vm.queryText == "ruby")
	}

	@Test func emptyFilterDefaultsToRecentProjects() {
		let vm = CommandPaletteViewModel()
		vm.filterText = ">test"
		vm.filterText = ""
		#expect(vm.activeMode == .recentProjects)
	}

	@Test func fuzzyFilteringWorks() {
		let vm = CommandPaletteViewModel()
		let items = [
			OakCommandPaletteItem(title: "Format File", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "menu:formatFile:"),
			OakCommandPaletteItem(title: "Find in Project", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "menu:findInProject:"),
			OakCommandPaletteItem(title: "Open Recent", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "menu:openRecent:"),
		]
		vm.setItems(items, forMode: .commands)
		vm.filterText = ">fmt"
		#expect(vm.filteredItems.count == 1)
		#expect(vm.filteredItems.first?.item.title == "Format File")
	}

	@Test func frecencyBoostIncreasesScoreForRecentItems() {
		let vm = CommandPaletteViewModel()
		let now = Date().timeIntervalSinceReferenceDate

		vm.updateFrecency(for: "menu:formatFile:", at: now)
		vm.updateFrecency(for: "menu:formatFile:", at: now)
		vm.updateFrecency(for: "menu:formatFile:", at: now)

		let boost = vm.frecencyBoost(for: "menu:formatFile:")
		#expect(boost > 0)
	}

	@Test func frecencyBoostDecaysOverTime() {
		let vm = CommandPaletteViewModel()
		let now = Date().timeIntervalSinceReferenceDate
		let oneWeekAgo = now - 168 * 3600

		vm.updateFrecency(for: "old", at: oneWeekAgo)
		vm.updateFrecency(for: "recent", at: now)

		let oldBoost = vm.frecencyBoost(for: "old")
		let recentBoost = vm.frecencyBoost(for: "recent")
		#expect(recentBoost > oldBoost)
	}

	@Test func selectionNavigationWorks() {
		let vm = CommandPaletteViewModel()
		let items = [
			OakCommandPaletteItem(title: "Aa", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "a"),
			OakCommandPaletteItem(title: "Bb", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "b"),
			OakCommandPaletteItem(title: "Cc", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "c"),
		]
		vm.setItems(items, forMode: .commands)
		vm.filterText = ">"
		#expect(vm.selectedIndex == 0)
		vm.selectNext()
		#expect(vm.selectedIndex == 1)
		vm.selectNext()
		#expect(vm.selectedIndex == 2)
		vm.selectNext()
		#expect(vm.selectedIndex == 2)
		vm.selectPrevious()
		#expect(vm.selectedIndex == 1)
	}

	@Test func projectsSearchBranchesAndPaths() {
		let vm = CommandPaletteViewModel()
		let item = OakCommandPaletteItem(title: "textmate · topic/palette", subtitle: "~/hidden/location", keyEquivalent: "", category: .recentProject, actionIdentifier: "project:/hidden/location")
		item.searchText = "/hidden/location topic/palette"
		vm.setItems([item], forMode: .recentProjects)
		vm.filterText = "palette"
		#expect(vm.filteredItems.count == 1)
		#expect(!vm.filteredItems[0].matchedIndices.isEmpty)
		vm.filterText = "hidden"
		#expect(vm.filteredItems.count == 1)
		#expect(vm.filteredItems[0].matchedIndices.isEmpty)
	}

	@Test func projectRefreshPreservesSearchAndSelectedWorkspace() {
		let vm = CommandPaletteViewModel()
		func item(_ path: String, _ branch: String) -> OakCommandPaletteItem {
			OakCommandPaletteItem(title: "textmate · \(branch)", subtitle: path, keyEquivalent: "", category: .recentProject, actionIdentifier: "project:\(path)")
		}
		vm.setItems([item("/a", "main"), item("/b", "feature")], forMode: .recentProjects)
		vm.filterText = "textmate"
		vm.selectNext()
		let selected = vm.selectedItem?.actionIdentifier
		vm.updateProjects([item("/new", "discovered"), item("/b", "new-branch"), item("/a", "main")])
		#expect(vm.filterText == "textmate")
		#expect(vm.selectedItem?.actionIdentifier == selected)
		#expect(vm.selectedItem?.title == "textmate · new-branch")
	}

	@Test func projectRefreshDoesNotChangeCommandMode() {
		let vm = CommandPaletteViewModel()
		let command = OakCommandPaletteItem(title: "Build", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "menu:build")
		vm.setItems([command], forMode: .commands)
		vm.filterText = ">build"
		vm.updateProjects([])
		#expect(vm.activeMode == .commands)
		#expect(vm.selectedItem?.actionIdentifier == "menu:build")
	}

	private func workspace(_ path: String, branch: String, repository: String) -> OakCommandPaletteItem {
		let item = OakCommandPaletteItem(title: "textmate · \(branch)", subtitle: path, keyEquivalent: "", category: .recentProject, actionIdentifier: "project:\(path)")
		item.projectGroupIdentifier = repository
		item.projectGroupTitle = "textmate"
		item.projectGroupPath = repository
		item.gitBranch = branch
		item.searchText = "\(path) \(repository)"
		return item
	}

	@Test func relatedWorkspacesStayTogetherAndHeadersAreNotSelectable() {
		let vm = CommandPaletteViewModel()
		vm.setItems([
			workspace("/a/main", branch: "main", repository: "/a"),
			workspace("/b/main", branch: "main", repository: "/b"),
			workspace("/a/feature", branch: "feature", repository: "/a"),
		], forMode: .recentProjects)
		#expect(vm.filteredItems.map(\.item.actionIdentifier) == ["project:/a/main", "project:/a/feature", "project:/b/main"])
		#expect(vm.startsProjectGroup(at: 0))
		#expect(!vm.startsProjectGroup(at: 1))
		#expect(!vm.startsProjectGroup(at: 2))
		#expect(vm.isCompactProject(vm.filteredItems[2].item))
		#expect(vm.projectGroupCaption(for: "/a") == "2 workspaces")
		vm.selectNext()
		#expect(vm.selectedItem?.actionIdentifier == "project:/a/feature")
		vm.selectNext()
		#expect(vm.selectedItem?.actionIdentifier == "project:/b/main")
	}

	@Test func searchKeepsMatchingWorkspacesGroupedAndReportsHiddenSiblings() {
		let vm = CommandPaletteViewModel()
		vm.setItems([
			workspace("/a/main", branch: "main", repository: "/a"),
			workspace("/b/main", branch: "main", repository: "/b"),
			workspace("/a/unique", branch: "unique", repository: "/a"),
		], forMode: .recentProjects)
		vm.filterText = "textmate"
		#expect(vm.filteredItems[0].item.projectGroupIdentifier == vm.filteredItems[1].item.projectGroupIdentifier)
		vm.filterText = "unique"
		#expect(vm.filteredItems.count == 1)
		#expect(vm.startsProjectGroup(at: 0))
		#expect(vm.projectGroupCaption(for: "/a") == "1 of 2 workspaces")
	}

	@Test func repositoriesWithTheSameNameRemainSeparateGroups() {
		let vm = CommandPaletteViewModel()
		vm.setItems([
			workspace("/first/textmate", branch: "main", repository: "/first/textmate"),
			workspace("/second/textmate", branch: "main", repository: "/second/textmate"),
		], forMode: .recentProjects)
		#expect(!vm.startsProjectGroup(at: 0))
		#expect(!vm.startsProjectGroup(at: 1))
		#expect(vm.filteredItems.allSatisfy { vm.isCompactProject($0.item) })
		#expect(vm.projectGroupCaption(for: "/first/textmate") == "1 workspace")
	}

	@Test func groupingRefreshPreservesTheSelectedWorkspace() {
		let vm = CommandPaletteViewModel()
		let main = workspace("/a/main", branch: "main", repository: "")
		let other = workspace("/b/main", branch: "main", repository: "")
		let feature = workspace("/a/feature", branch: "feature", repository: "")
		vm.setItems([main, other, feature], forMode: .recentProjects)
		vm.selectNext()
		vm.selectNext()
		vm.updateProjects([
			workspace("/a/main", branch: "main", repository: "/a"),
			workspace("/b/main", branch: "main", repository: "/b"),
			workspace("/a/feature", branch: "feature", repository: "/a"),
		])
		#expect(vm.selectedIndex == 1)
		#expect(vm.selectedItem?.actionIdentifier == "project:/a/feature")
	}

	@Test func singleCheckoutIsCompactAndDoesNotHaveASeparateHeading() {
		let vm = CommandPaletteViewModel()
		let item = workspace("/project", branch: "main", repository: "/project")
		item.projectWorkspaceIdentifiers = [item.actionIdentifier]
		vm.setItems([item], forMode: .recentProjects)
		#expect(vm.isCompactProject(item))
		#expect(!vm.startsProjectGroup(at: 0))
		#expect(!vm.hasMultipleProjectWorkspaces(item))
	}

	@Test func multiWorktreeLayoutRemainsExpandedWhenSearchMatchesOneCheckout() {
		let vm = CommandPaletteViewModel()
		let main = workspace("/project", branch: "main", repository: "/project")
		let feature = workspace("/feature", branch: "feature", repository: "/project")
		vm.setItems([main, feature], forMode: .recentProjects)
		vm.filterText = "feature"
		#expect(vm.filteredItems.count == 1)
		#expect(vm.startsProjectGroup(at: 0))
		#expect(!vm.isCompactProject(feature))
		feature.projectWorkspaceIdentifiers = [main.actionIdentifier, feature.actionIdentifier]
		vm.updateProjects([feature])
		#expect(vm.hasMultipleProjectWorkspaces(feature))
		#expect(!vm.isCompactProject(feature))
	}

	@Test func hideWorkspaceSurvivesRefreshAndCanBeRestored() {
		let vm = CommandPaletteViewModel()
		let main = workspace("/a/main", branch: "main", repository: "/a")
		let feature = workspace("/a/feature", branch: "feature", repository: "/a")
		vm.setItems([main, feature], forMode: .recentProjects)
		vm.hideWorkspace(main)
		#expect(vm.filteredItems.map(\.item.actionIdentifier) == [feature.actionIdentifier])
		#expect(vm.projectGroupCaption(for: "/a") == "1 workspace")
		vm.updateProjects([main, feature])
		#expect(vm.filteredItems.count == 1)
		vm.showsHiddenProjects = true
		#expect(vm.filteredItems.count == 2)
		#expect(vm.isProjectHidden(main))
		vm.showWorkspace(main)
		#expect(!vm.isProjectHidden(main))
		#expect(!vm.hasHiddenProjects)
	}

	@Test func hideProjectIncludesFutureWorktreesButLeavesOtherRepositoriesVisible() {
		let vm = CommandPaletteViewModel()
		let main = workspace("/a", branch: "main", repository: "/a")
		let clone = workspace("/clone", branch: "main", repository: "/clone")
		vm.setItems([main, clone], forMode: .recentProjects)
		vm.hideProject(main)
		let future = workspace("/elsewhere/new-worktree", branch: "feature", repository: "/a")
		vm.updateProjects([main, clone, future])
		#expect(vm.filteredItems.map(\.item.actionIdentifier) == [clone.actionIdentifier])
		vm.showProject(future)
		#expect(vm.filteredItems.count == 3)
	}

	@Test func visibilityStateRoundTripsBeforeGitMetadataArrives() {
		let vm = CommandPaletteViewModel()
		let main = workspace("/a", branch: "main", repository: "/a")
		main.projectWorkspaceIdentifiers = ["project:/a", "project:/elsewhere/linked"]
		vm.setItems([main], forMode: .recentProjects)
		vm.hideProject(main)
		let restored = CommandPaletteViewModel()
		restored.loadProjectVisibility(workspaces: vm.hiddenWorkspaceIdentifiers, projects: vm.hiddenProjectIdentifiers, projectWorkspaces: vm.hiddenProjectWorkspaces)
		let linked = workspace("/elsewhere/linked", branch: "", repository: "")
		restored.setItems([linked], forMode: .recentProjects)
		#expect(restored.filteredItems.isEmpty)
		restored.showsHiddenProjects = true
		#expect(restored.isProjectGroupHidden(linked))
		restored.showProject(linked)
		#expect(!restored.hasHiddenProjects)
	}

	@Test func hiddenHistoricalSubdirectoryStaysHiddenAfterCheckoutFolding() {
		let vm = CommandPaletteViewModel()
		let subdirectory = workspace("/a/src", branch: "", repository: "")
		vm.setItems([subdirectory], forMode: .recentProjects)
		vm.hideWorkspace(subdirectory)
		let root = workspace("/a", branch: "main", repository: "/a")
		root.workspaceAliases = [subdirectory.actionIdentifier]
		vm.updateProjects([root])
		#expect(vm.filteredItems.isEmpty)
		vm.showWorkspace(root)
		#expect(vm.filteredItems.count == 1)
	}

	@Test func hidingOuterCheckoutDoesNotHideIndependentNestedRepository() {
		let vm = CommandPaletteViewModel()
		let outer = workspace("/a", branch: "main", repository: "/a")
		let nested = workspace("/a/nested", branch: "main", repository: "/a/nested")
		vm.setItems([outer, nested], forMode: .recentProjects)
		vm.hideProject(outer)
		#expect(vm.filteredItems.map(\.item.actionIdentifier) == [nested.actionIdentifier])
		vm.restoreAllProjects()
		vm.hideWorkspace(outer)
		#expect(vm.filteredItems.map(\.item.actionIdentifier) == [nested.actionIdentifier])
	}

	@Test func hiddenPlainProjectsCanBeRestoredAndCommandsRemainAvailable() {
		let vm = CommandPaletteViewModel()
		let plain = workspace("/plain", branch: "", repository: "")
		let command = OakCommandPaletteItem(title: "Build", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "menu:build")
		vm.setItems([plain], forMode: .recentProjects)
		vm.setItems([command], forMode: .commands)
		var saves = 0
		vm.onProjectVisibilityChanged = { saves += 1 }
		vm.hideProject(plain)
		#expect(vm.filteredItems.isEmpty)
		vm.filterText = ">build"
		#expect(vm.selectedItem?.actionIdentifier == command.actionIdentifier)
		vm.restoreAllProjects()
		#expect(saves == 2)
		vm.filterText = ""
		#expect(vm.filteredItems.count == 1)
	}
}
