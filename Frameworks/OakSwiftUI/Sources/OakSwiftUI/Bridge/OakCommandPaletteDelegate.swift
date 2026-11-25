import AppKit

@MainActor @objc public protocol OakCommandPaletteDelegate: AnyObject {
	func commandPaletteDidSelectItem(_ item: OakCommandPaletteItem)
	func commandPaletteDidDismiss()
	func commandPaletteRequestItems(forMode mode: Int) -> [OakCommandPaletteItem]
	func commandPaletteSearchDocument(_ query: String) -> [OakCommandPaletteItem]
	// Project actions; the palette is dismissed before these are sent.
	func commandPaletteRequestNewProject()
	func commandPaletteRequestImportProject()
	func commandPaletteRequestNewWorktree(_ item: OakCommandPaletteItem)
}
