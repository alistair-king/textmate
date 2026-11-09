import SwiftUI

struct CommandPaletteRowView: View {
	let item: OakCommandPaletteItem
	let matchedIndices: [Int]
	let isSelected: Bool
	var isHidden: Bool = false
	var isCompactProject: Bool = false
	@EnvironmentObject var theme: OakThemeEnvironment

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: isCompactProject ? "folder.fill" : item.categorySymbolName)
				.font(.system(size: max(theme.fontSize - 2, 9)))
				.foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
				.frame(width: 20, alignment: .center)

			if isCompactProject {
				Text(item.subtitle.isEmpty ? item.title : item.subtitle)
					.font(.system(size: theme.fontSize, design: .monospaced))
					.foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
					.lineLimit(1)
					.truncationMode(.middle)
			} else {
				VStack(alignment: .leading, spacing: 1) {
					highlightedTitle(item.title, matches: matchedIndices)
						.font(.system(size: theme.fontSize, design: .monospaced))
						.foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
						.lineLimit(1)

					if !item.subtitle.isEmpty {
						Text(item.subtitle)
							.font(.system(size: max(theme.fontSize - 2, 9), design: .monospaced))
							.foregroundStyle(isSelected
								? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.7)
								: .secondary)
							.lineLimit(1)
					}
				}
			}

			Spacer(minLength: 4)
			if isCompactProject && !item.gitBranch.isEmpty {
				Label(item.gitBranch, systemImage: "arrow.triangle.branch")
					.font(.system(size: max(theme.fontSize - 2, 9), design: .monospaced))
					.foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
					.lineLimit(1)
					.layoutPriority(1)
			}
			if isHidden {
				Image(systemName: "eye.slash")
					.foregroundStyle(.secondary)
					.accessibilityLabel("Hidden workspace")
			}

			if !item.statusText.isEmpty {
				Text(item.statusText)
					.font(.system(size: max(theme.fontSize - 2, 9), weight: .medium))
					.foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
					.lineLimit(1)
					.accessibilityLabel(item.statusText)
			}

			if !item.keyEquivalent.isEmpty {
				Text(item.keyEquivalent)
					.font(.system(size: max(theme.fontSize - 2, 9)))
					.foregroundStyle(isSelected
						? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.7)
						: Color(nsColor: theme.foregroundColor).opacity(0.5))
					.lineLimit(1)
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 4)
		.frame(height: isCompactProject ? max(theme.fontSize * 1.6, 24) : max(theme.fontSize * 2.4, 32))
		.background(isSelected ? Color.accentColor : Color.clear)
		.cornerRadius(4)
		.opacity((item.enabled ? 1.0 : 0.4) * (isHidden ? 0.6 : 1.0))
	}

	private func highlightedTitle(_ title: String, matches: [Int]) -> Text {
		guard !matches.isEmpty else { return Text(title) }
		var result = Text("")
		for (i, char) in title.enumerated() {
			let t = Text(String(char))
			result = result + (matches.contains(i) ? t.bold() : t)
		}
		return result
	}
}
