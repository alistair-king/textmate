#ifndef COMPARE_MENU_H_J7N2PX4D
#define COMPARE_MENU_H_J7N2PX4D

#import <Cocoa/Cocoa.h>

// The View menu: display modes (tag = CompareFilter), ignored files,
// expanding or collapsing every folder, and swapping the sides.
// Built in one place so Compare.app and its tests use the same items and
// key equivalents.

namespace compare {

	inline NSMenu* view_menu ()
	{
		NSMenu* menu = [[NSMenu alloc] initWithTitle:@"View"];
		NSArray* modes = @[ @"Changed Files", @"Only on the Left", @"Only on the Right", @"All Files" ];
		for(NSUInteger mode = 0; mode < modes.count; ++mode)
		{
			NSMenuItem* item = [menu addItemWithTitle:modes[mode] action:@selector(takeDisplayModeFrom:) keyEquivalent:[NSString stringWithFormat:@"%lu", mode + 1]];
			item.tag = mode;
		}
		[menu addItem:NSMenuItem.separatorItem];
		// ⇧⌘. on a US keyboard: AppKit matches the typed character, and Shift+.
		// types “>”, so “.” with Shift would never fire.
		NSMenuItem* ignored = [menu addItemWithTitle:@"Show Ignored Files" action:@selector(toggleIgnoredFilesFromMenu:) keyEquivalent:@">"];
		ignored.keyEquivalentModifierMask = NSEventModifierFlagCommand;
		ignored.toolTip = @"Also compare files that .gitignore excludes, walking both folders on disk";
		[menu addItem:NSMenuItem.separatorItem];
		// No key equivalents: ⇧⌘←/→ and ⌥⌘←/→ move the caret or copy changes.
		[menu addItemWithTitle:@"Expand All" action:@selector(expandAllFolders:) keyEquivalent:@""];
		[menu addItemWithTitle:@"Collapse All" action:@selector(collapseAllFolders:) keyEquivalent:@""];
		[menu addItem:NSMenuItem.separatorItem];
		[menu addItemWithTitle:@"Swap Left and Right" action:@selector(swapSides:) keyEquivalent:@""];
		return menu;
	}

	// Edit → Find: in a file tab, the find bar above both sides; in the Files
	// tab, Find… goes to the name filter. Own selectors, so the text views'
	// standard find panel never answers them.
	inline NSMenu* find_menu ()
	{
		NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Find"];
		[menu addItemWithTitle:@"Find…" action:@selector(findInComparison:) keyEquivalent:@"f"];
		[menu addItemWithTitle:@"Find Next" action:@selector(findNextInComparison:) keyEquivalent:@"g"];
		[menu addItemWithTitle:@"Find Previous" action:@selector(findPreviousInComparison:) keyEquivalent:@"G"];
		return menu;
	}

} /* compare */

#endif /* end of include guard: COMPARE_MENU_H_J7N2PX4D */
