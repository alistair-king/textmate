#ifndef COMPARE_MENU_H_J7N2PX4D
#define COMPARE_MENU_H_J7N2PX4D

#import <Cocoa/Cocoa.h>

// The View menu: display modes (tag = CompareFilter), ignored files, and
// expanding or collapsing every folder.
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
		return menu;
	}

} /* compare */

#endif /* end of include guard: COMPARE_MENU_H_J7N2PX4D */
