import SwiftUI

struct CommandPaletteView: View {
	@ObservedObject var viewModel: CommandPaletteViewModel
	@EnvironmentObject var theme: OakThemeEnvironment
	@FocusState private var isSearchFieldFocused: Bool

	var body: some View {
		VStack(spacing: 0) {
			searchField
			Divider()
			resultsList
		}
		.background(Color(nsColor: theme.backgroundColor).opacity(0.85))
		.clipShape(RoundedRectangle(cornerRadius: 6))
		.onKeyPress(.downArrow) { viewModel.selectNext(); return .handled }
		.onKeyPress(.upArrow) { viewModel.selectPrevious(); return .handled }
		.onKeyPress(.return) { viewModel.acceptSelection(); return .handled }
		.onKeyPress(.escape) { viewModel.requestDismiss(); return .handled }
		.onAppear { isSearchFieldFocused = true }
	}

	private var searchField: some View {
		HStack(spacing: 6) {
			if viewModel.activeMode != .recentProjects {
				modePill
			}
			TextField(viewModel.activeMode.placeholder, text: $viewModel.filterText)
				.textFieldStyle(.plain)
				.font(.system(size: theme.fontSize, design: .monospaced))
				.focused($isSearchFieldFocused)
			if viewModel.activeMode == .recentProjects {
				Menu {
					if let item = viewModel.selectedItem {
						projectVisibilityActions(item)
						Divider()
					}
					Toggle("Show Hidden Workspaces", isOn: $viewModel.showsHiddenProjects)
					Button("Restore All Hidden Entries") { viewModel.restoreAllProjects() }
						.disabled(!viewModel.hasHiddenProjects)
				} label: {
					Image(systemName: "ellipsis.circle")
				}
				.menuStyle(.borderlessButton)
				.fixedSize()
				.help("Project visibility")
				.accessibilityLabel("Project visibility")
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}

	private var modePill: some View {
		Text(viewModel.activeMode.label)
			.font(.system(size: max(theme.fontSize - 2, 9), weight: .medium))
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(Color.accentColor.opacity(0.2))
			.foregroundStyle(Color.accentColor)
			.clipShape(RoundedRectangle(cornerRadius: 4))
	}

	private var resultsList: some View {
		ScrollViewReader { proxy in
			ScrollView(.vertical) {
				LazyVStack(spacing: 0) {
					ForEach(Array(viewModel.filteredItems.enumerated()), id: \.element.id) { index, ranked in
						if viewModel.startsProjectGroup(at: index) {
							projectGroupHeader(ranked.item)
						}
						CommandPaletteRowView(
							item: ranked.item,
							matchedIndices: ranked.matchedIndices,
							isSelected: index == viewModel.selectedIndex,
							isHidden: viewModel.isProjectHidden(ranked.item)
						)
						.padding(.leading, ranked.item.projectGroupIdentifier.isEmpty ? 0 : 12)
						.overlay(alignment: .leading) {
							if !ranked.item.projectGroupIdentifier.isEmpty {
								Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1).padding(.leading, 4)
							}
						}
						.contextMenu { projectVisibilityActions(ranked.item) }
						.id(ranked.id)
						.contentShape(Rectangle())
						.onTapGesture {
							if ranked.item.enabled {
								viewModel.selectedIndex = index
								viewModel.acceptSelection()
							}
						}
					}
				}
				.padding(.vertical, 4)
				.padding(.horizontal, 4)
			}
			.frame(maxHeight: max(theme.fontSize * 2.4, 32) * 10 + 8)
			.onChange(of: viewModel.selectedIndex) { _, newValue in
				guard newValue < viewModel.filteredItems.count else { return }
				withAnimation(.easeOut(duration: 0.1)) {
					proxy.scrollTo(viewModel.filteredItems[newValue].id, anchor: .center)
				}
			}
		}
	}

	private func projectGroupHeader(_ item: OakCommandPaletteItem) -> some View {
		HStack(spacing: 8) {
			Image(systemName: "folder.fill")
				.foregroundStyle(.secondary)
			VStack(alignment: .leading, spacing: 1) {
				Text(item.projectGroupTitle)
					.font(.system(size: theme.fontSize, weight: .semibold))
					.lineLimit(1)
				Text(item.projectGroupPath)
					.font(.system(size: max(theme.fontSize - 2, 9), design: .monospaced))
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			Spacer(minLength: 4)
			Text(viewModel.projectGroupCaption(for: item.projectGroupIdentifier))
				.font(.system(size: max(theme.fontSize - 2, 9)))
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
		.padding(.horizontal, 8)
		.padding(.top, 10)
		.padding(.bottom, 5)
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(.isHeader)
		.contextMenu {
			if viewModel.isProjectGroupHidden(item) {
				Button("Show Project") { viewModel.showProject(item) }
			} else {
				Button("Hide Project") { viewModel.hideProject(item) }
			}
		}
	}

	@ViewBuilder private func projectVisibilityActions(_ item: OakCommandPaletteItem) -> some View {
		if item.category == .recentProject {
			if viewModel.isProjectGroupHidden(item) {
				Button("Show Project") { viewModel.showProject(item) }
			} else {
				if viewModel.isProjectHidden(item) {
					Button("Show Workspace") { viewModel.showWorkspace(item) }
				} else {
					Button("Hide Workspace") { viewModel.hideWorkspace(item) }
				}
				Button("Hide Project") { viewModel.hideProject(item) }
			}
		}
	}
}
