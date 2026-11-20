#import <Cocoa/Cocoa.h>
#import <Preferences/Keys.h>
#import <OakTabBarView/OakTabBarView.h>
#import "../src/CompareWindowController.h"
#import "../src/compare_tree.h"
#import "../src/compare_colors.h"
#import "../src/CompareDiffView.h"
#import "compare_fixture.h"

// Drives the real CompareWindowController over the shared fixture. Failures
// print `file:line: Assertion failed: …` and make the process exit non-zero.
// Set COMPARE_SNAPSHOT_DIR to also write light and dark PNG snapshots.

@interface CompareWindowController (Testing)
- (NSOutlineView*)outlineViewForLeftSide:(BOOL)left;
- (void)takeFilterFrom:(NSSegmentedControl*)sender;
- (CompareDiffView*)selectedDiffView;
- (NSUInteger)tabCount;
- (NSUInteger)selectedTabIndex;
- (void)selectTabAtIndex:(NSUInteger)index;
- (void)closeTabAtIndex:(NSUInteger)index;
- (void)openSelectedFiles:(id)sender;
- (void)closeTab:(id)sender;
- (NSString*)tabBarView:(id)tabBar titleForIndex:(NSUInteger)index;
- (void)trashClickedEntries:(NSMenuItem*)sender;
@end

static int Failures = 0;
#define CHECK(expr) do { if(!(expr)) { fprintf(stderr, "%s:%d: Assertion failed: %s\n", __FILE__, __LINE__, #expr); ++Failures; } } while(false)

static BOOL WaitUntil (BOOL (^condition)())
{
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:30];
	while(!condition() && deadline.timeIntervalSinceNow > 0)
		[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
	return condition();
}

static BOOL Loaded (CompareWindowController* controller)
{
	NSTextField* summary = [controller valueForKey:@"_summaryLabel"];
	return [controller valueForKey:@"_root"] && ![summary.stringValue isEqualToString:@"Comparing…"];
}

static CompareWindowController* Open (compare_fixture_t const& fixture, NSString* focus)
{
	CompareWindowController* controller = [[CompareWindowController alloc] initWithLeftPath:fixture.left rightPath:fixture.right focus:focus];
	[controller.window setFrame:NSMakeRect(100, 100, 900, 320) display:NO];
	[controller showWindow:nil];
	CHECK(WaitUntil(^{ return Loaded(controller); }));
	[controller.window layoutIfNeeded];
	return controller;
}

static NSInteger RowFor (NSOutlineView* outlineView, NSString* relativePath)
{
	for(NSInteger row = 0; row < outlineView.numberOfRows; ++row)
	{
		if([((CompareNode*)[outlineView itemAtRow:row]).relativePath isEqualToString:relativePath])
			return row;
	}
	return -1;
}

static NSArray<NSString*>* TopLevelNames (NSOutlineView* outlineView)
{
	NSMutableArray* names = [NSMutableArray array];
	for(NSInteger row = 0; row < outlineView.numberOfRows; ++row)
	{
		if([outlineView levelForRow:row] == 0)
			[names addObject:((CompareNode*)[outlineView itemAtRow:row]).name];
	}
	return names;
}

static NSColor* TintAt (NSOutlineView* outlineView, NSString* relativePath)
{
	NSInteger row = RowFor(outlineView, relativePath);
	return row == -1 ? nil : [[outlineView rowViewAtRow:row makeIfNecessary:YES] valueForKey:@"tintColor"];
}

static NSColor* TextColorAt (NSOutlineView* outlineView, NSString* relativePath)
{
	NSInteger row = RowFor(outlineView, relativePath);
	return row == -1 ? nil : ((NSTableCellView*)[outlineView viewAtColumn:0 row:row makeIfNecessary:YES]).textField.textColor;
}

static BOOL Aligned (CompareWindowController* controller)
{
	NSOutlineView* left  = [controller outlineViewForLeftSide:YES];
	NSOutlineView* right = [controller outlineViewForLeftSide:NO];
	if(left.numberOfRows != right.numberOfRows)
		return NO;
	for(NSInteger row = 0; row < left.numberOfRows; ++row)
	{
		if([left itemAtRow:row] != [right itemAtRow:row])
			return NO;
	}
	return YES;
}

static void SelectFilter (CompareWindowController* controller, NSInteger filter)
{
	NSSegmentedControl* control = [controller valueForKey:@"_filterControl"];
	control.selectedSegment = filter;
	[controller takeFilterFrom:control];
	[controller.window layoutIfNeeded];
}

// Draws the content view into a PNG. Note: on recent macOS releases this
// drawing path leaves the file-contents text views (inside scroll views with
// rulers) and their header blank, although they display on screen; the
// assertions, not the snapshot, cover that pane.
static void Snapshot (CompareWindowController* controller, NSString* name)
{
	NSString* directory = NSProcessInfo.processInfo.environment[@"COMPARE_SNAPSHOT_DIR"];
	if(!directory.length)
		return;
	for(NSAppearanceName appearance in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ])
	{
		controller.window.appearance = [NSAppearance appearanceNamed:appearance];
		NSView* view = controller.window.contentView;
		[view layoutSubtreeIfNeeded];
		[view displayIfNeeded];
		NSBitmapImageRep* bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
		// The window background is not part of the content view's drawing.
		[NSGraphicsContext saveGraphicsState];
		NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
		[controller.window.effectiveAppearance performAsCurrentDrawingAppearance:^{
			[NSColor.windowBackgroundColor setFill];
			NSRectFill(view.bounds);
		}];
		[NSGraphicsContext restoreGraphicsState];
		[view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
		NSString* file = [NSString stringWithFormat:@"%@-%@.png", name, appearance == NSAppearanceNameAqua ? @"light" : @"dark"];
		[[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{ }] writeToFile:[directory stringByAppendingPathComponent:file] atomically:YES];
	}
	controller.window.appearance = nil;
}

static void TestChangedFilter (compare_fixture_t const& fixture)
{
	CompareWindowController* controller = Open(fixture, nil);
	NSOutlineView* left  = [controller outlineViewForLeftSide:YES];
	NSOutlineView* right = [controller outlineViewForLeftSide:NO];

	NSTextField* summary = [controller valueForKey:@"_summaryLabel"];
	CHECK([summary.stringValue isEqualToString:@"5 modified · 2 only on the left · 2 only on the right · 1 changed type"]);
	CHECK([controller.window.title isEqualToString:@"main ⇄ feature"]);

	NSArray* names = TopLevelNames(left);
	CHECK([names isEqual:(@[ @"deep", @"kind", @"newdir", @"gone.txt", @"grown.txt", @"left-only.txt", @"link", @"multi.txt", @"same-size.txt" ])]);
	CHECK(Aligned(controller));

	// Expanding on one side expands the other.
	[left expandItem:[left itemAtRow:RowFor(left, @"deep")] expandChildren:YES];
	CHECK([right isItemExpanded:[right itemAtRow:RowFor(right, @"deep/a")]]);
	CHECK(Aligned(controller));
	CHECK(RowFor(left, @"deep/a/b.txt") != -1);
	CHECK(RowFor(left, @"deep/a/c.txt") == -1); // identical, hidden
	[right expandItem:[right itemAtRow:RowFor(right, @"kind")]];
	[right expandItem:[right itemAtRow:RowFor(right, @"newdir")]];
	CHECK([left isItemExpanded:[left itemAtRow:RowFor(left, @"newdir")]]);
	CHECK(Aligned(controller));

	// Background tints per side.
	CHECK(TintAt(left, @"grown.txt") == compare::modified_color());
	CHECK(TintAt(right, @"grown.txt") == compare::modified_color());
	CHECK(TintAt(left, @"deep") == compare::folder_color());
	CHECK(TintAt(left, @"left-only.txt") == compare::added_color());
	CHECK(TintAt(right, @"left-only.txt") == compare::placeholder_color());
	CHECK(TintAt(left, @"newdir/x.txt") == compare::placeholder_color());
	CHECK(TintAt(right, @"newdir/x.txt") == compare::added_color());
	CHECK(TintAt(left, @"kind") == compare::type_changed_color());
	CHECK(TintAt(right, @"kind") == compare::type_changed_color());

	// Placeholders are dimmed; present entries are not.
	CHECK([TextColorAt(right, @"left-only.txt") isEqual:NSColor.tertiaryLabelColor]);
	CHECK([TextColorAt(left, @"left-only.txt") isEqual:NSColor.labelColor]);
	CHECK([TextColorAt(left, @"newdir") isEqual:NSColor.tertiaryLabelColor]);

	// Selection and scrolling follow the other side.
	NSInteger row = RowFor(right, @"grown.txt");
	[right selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	CHECK(left.selectedRow == row);
	NSClipView* leftClip  = left.enclosingScrollView.contentView;
	NSClipView* rightClip = right.enclosingScrollView.contentView;
	[leftClip scrollToPoint:NSMakePoint(0, 30)];
	CHECK(leftClip.bounds.origin.y > 0);
	CHECK(rightClip.bounds.origin.y == leftClip.bounds.origin.y);

	Snapshot(controller, @"changed");

	// Collapsing follows too.
	[left collapseItem:[left itemAtRow:RowFor(left, @"deep")]];
	CHECK(![right isItemExpanded:[right itemAtRow:RowFor(right, @"deep")]]);
	CHECK(Aligned(controller));

	// All shows identical entries without a tint; expansion is kept.
	SelectFilter(controller, 3);
	CHECK(RowFor(left, @"same.txt") != -1);
	CHECK(TintAt(left, @"same.txt") == nil);
	CHECK(TintAt(right, @"é.txt") == nil);
	CHECK([left isItemExpanded:[left itemAtRow:RowFor(left, @"newdir")]]);
	CHECK(Aligned(controller));
	Snapshot(controller, @"all");

	// Left Only keeps only entries missing on the right, and what contains them.
	SelectFilter(controller, 1);
	CHECK([TopLevelNames(left) isEqual:(@[ @"gone.txt", @"left-only.txt" ])]);
	CHECK(Aligned(controller));

	SelectFilter(controller, 2);
	CHECK([TopLevelNames(left) isEqual:(@[ @"kind", @"newdir" ])]);
	CHECK(Aligned(controller));

	[controller close];
}

// Selects `relativePath` in the left tree, opens it as a tab (the double-click
// action) and waits for the contents to load.
static CompareDiffView* Show (CompareWindowController* controller, NSString* relativePath)
{
	NSOutlineView* left = [controller outlineViewForLeftSide:YES];
	NSInteger row = RowFor(left, relativePath);
	CHECK(row != -1);
	[left selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	[controller selectTabAtIndex:0];
	[NSApp sendAction:left.doubleAction to:left.target from:left];
	CompareDiffView* diffView = controller.selectedDiffView;
	CHECK(diffView != nil);
	CHECK(WaitUntil(^{ return (BOOL)!diffView.loading; }));
	[controller.window layoutIfNeeded];
	return diffView;
}

static id AttributeAt (NSTextView* textView, NSAttributedStringKey name, NSUInteger index)
{
	NSTextStorage* storage = textView.textStorage;
	return index < storage.length ? [storage attribute:name atIndex:index effectiveRange:nullptr] : nil;
}

static void TestFileTabs (compare_fixture_t const& fixture)
{
	CompareWindowController* controller = Open(fixture, nil);
	[controller.window setFrame:NSMakeRect(100, 100, 1000, 700) display:NO];
	[controller.window layoutIfNeeded];
	NSOutlineView* left = [controller outlineViewForLeftSide:YES];

	// Only the tree tab to begin with; it shows the trees.
	CHECK(controller.tabCount == 1);
	CHECK(controller.selectedDiffView == nil);
	CHECK([[controller tabBarView:nil titleForIndex:0] isEqualToString:@"Files"]);
	CHECK(left.window == controller.window);

	// Opening a modified file adds and selects its tab.
	CompareDiffView* diff = Show(controller, @"grown.txt");
	CHECK(controller.tabCount == 2 && controller.selectedTabIndex == 1);
	CHECK([[controller tabBarView:nil titleForIndex:1] isEqualToString:@"grown.txt"]);
	CHECK(left.window == nil); // the trees are not shown behind the file tab
	CHECK(diff.message == nil);
	CHECK([diff.leftTextView.string isEqualToString:@"short\n"]);
	CHECK([diff.rightTextView.string isEqualToString:@"much longer contents\n"]);
	CHECK(AttributeAt(diff.leftTextView, CompareLineTintAttributeName, 0) == compare::modified_color());
	CHECK(AttributeAt(diff.rightTextView, CompareLineTintAttributeName, 0) == compare::modified_color());
	CHECK(diff.changeCount == 1 && diff.currentChange == 0);
	CHECK([diff.statusText hasPrefix:@"1 change · 1 line modified"]);

	// Opening it again selects the existing tab.
	CHECK(Show(controller, @"grown.txt") == diff);
	CHECK(controller.tabCount == 2);

	// The differing part of a changed line gets a stronger tint.
	diff = Show(controller, @"same-size.txt");
	CHECK(controller.tabCount == 3);
	CHECK(AttributeAt(diff.leftTextView, NSBackgroundColorAttributeName, 0) == compare::changed_text_color());
	CHECK(AttributeAt(diff.leftTextView, NSBackgroundColorAttributeName, 4) == nil); // the newline

	// Two separate changes: navigation moves between them.
	diff = Show(controller, @"multi.txt");
	CHECK(diff.changeCount == 2);
	CHECK(diff.currentChange == 0);
	CHECK([diff.leftTextView.string componentsSeparatedByString:@"\n"].count == 21);
	CHECK(AttributeAt(diff.leftTextView, CompareLineTintAttributeName, 0) == nil);
	NSMenuItem* next = [[NSMenuItem alloc] initWithTitle:@"Next" action:@selector(nextChange:) keyEquivalent:@""];
	NSMenuItem* previous = [[NSMenuItem alloc] initWithTitle:@"Previous" action:@selector(previousChange:) keyEquivalent:@""];
	CHECK([controller validateMenuItem:next] && ![controller validateMenuItem:previous]);
	[NSApp sendAction:@selector(nextChange:) to:controller from:nil];
	CHECK(diff.currentChange == 1);
	CHECK(![controller validateMenuItem:next] && [controller validateMenuItem:previous]);
	[NSApp sendAction:@selector(previousChange:) to:controller from:nil];
	CHECK(diff.currentChange == 0);

	// A file only on one side: gaps on the other side.
	[controller selectTabAtIndex:0];
	[left expandItem:[left itemAtRow:RowFor(left, @"newdir")]];
	diff = Show(controller, @"newdir/x.txt");
	CHECK([diff.leftTextView.string isEqualToString:@"\n"]);
	CHECK([diff.rightTextView.string isEqualToString:@"new on the right\n"]);
	CHECK(AttributeAt(diff.leftTextView, CompareLineTintAttributeName, 0) == compare::placeholder_color());
	CHECK(AttributeAt(diff.rightTextView, CompareLineTintAttributeName, 0) == compare::added_color());

	// Entries without text explain why.
	diff = Show(controller, @"link");
	CHECK([diff.message isEqualToString:@"The symbolic link points to “same.txt” on the left and “grown.txt” on the right."]);
	CHECK(controller.tabCount == 6);

	// Double-clicking a folder expands or collapses it instead of opening a tab.
	[controller selectTabAtIndex:0];
	NSInteger deep = RowFor(left, @"deep");
	[left selectRowIndexes:[NSIndexSet indexSetWithIndex:deep] byExtendingSelection:NO];
	BOOL expanded = [left isItemExpanded:[left itemAtRow:deep]];
	[NSApp sendAction:left.doubleAction to:left.target from:left];
	CHECK([left isItemExpanded:[left itemAtRow:deep]] != expanded);
	CHECK(controller.tabCount == 6 && controller.selectedTabIndex == 0);

	// Several selected files open together; the last one is selected.
	SelectFilter(controller, 3);
	NSMutableIndexSet* rows = [NSMutableIndexSet indexSetWithIndex:RowFor(left, @"same.txt")];
	[rows addIndex:RowFor(left, @".gitignore")];
	[left selectRowIndexes:rows byExtendingSelection:NO];
	[NSApp sendAction:left.doubleAction to:left.target from:left];
	CHECK(controller.tabCount == 8 && controller.selectedTabIndex == 7);
	CHECK(WaitUntil(^{ return (BOOL)!controller.selectedDiffView.loading; }));
	CHECK([controller.selectedDiffView.statusText isEqualToString:@"No differences"]);
	Snapshot(controller, @"file");

	// A new comparison refreshes open tabs.
	NSUInteger grown = NSNotFound;
	for(NSUInteger i = 1; i < controller.tabCount; ++i)
	{
		if([[controller tabBarView:nil titleForIndex:i] isEqualToString:@"grown.txt"])
			grown = i;
	}
	CHECK(grown == 1);
	[NSFileManager.defaultManager removeItemAtPath:[fixture.right stringByAppendingPathComponent:@"newdir/x.txt"] error:nil];
	[controller refresh:nil];
	CHECK(WaitUntil(^{ return Loaded(controller); }));
	[controller selectTabAtIndex:grown];
	CHECK(WaitUntil(^{ return (BOOL)!controller.selectedDiffView.loading; }));
	CHECK([controller.selectedDiffView.rightTextView.string isEqualToString:@"much longer contents\n"]);
	[controller selectTabAtIndex:4];
	CHECK([controller.selectedDiffView.message isEqualToString:@"This file is no longer in either folder."]);
	[@"new on the right\n" writeToFile:[fixture.right stringByAppendingPathComponent:@"newdir/x.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];

	// Closing tabs: the tree tab cannot be closed; Close Tab on it closes nothing else.
	[controller closeTabAtIndex:0];
	CHECK(controller.tabCount == 8);
	[controller selectTabAtIndex:3];
	[controller closeTab:nil];
	CHECK(controller.tabCount == 7 && controller.selectedTabIndex == 3);
	[controller closeTabAtIndex:1];
	CHECK(controller.tabCount == 6 && controller.selectedTabIndex == 2);
	NSMenuItem* close = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(closeTab:) keyEquivalent:@""];
	[controller validateMenuItem:close];
	CHECK([close.title isEqualToString:@"Close Tab"]);
	[controller selectTabAtIndex:0];
	[controller validateMenuItem:close];
	CHECK([close.title isEqualToString:@"Close Window"]);

	SelectFilter(controller, 0);
	[controller close];
}

static NSString* Contents (NSString* root, NSString* relativePath)
{
	return [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:relativePath] encoding:NSUTF8StringEncoding error:nil];
}

static void SelectRow (NSOutlineView* outlineView, NSString* relativePath)
{
	NSInteger row = RowFor(outlineView, relativePath);
	CHECK(row != -1);
	if(row != -1)
		[outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
}

static void TestTransfers (compare_fixture_t const& fixture)
{
	CompareWindowController* controller = Open(fixture, nil);
	[controller.window setFrame:NSMakeRect(100, 100, 1000, 700) display:NO];
	[controller.window layoutIfNeeded];
	NSOutlineView* left = [controller outlineViewForLeftSide:YES];
	NSUndoManager* undo = controller.window.undoManager;
	NSTextField* summary = [controller valueForKey:@"_summaryLabel"];

	// A modified file, left to right; undo and redo.
	SelectRow(left, @"grown.txt");
	NSMenuItem* toRight = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(copyToRight:) keyEquivalent:@""];
	CHECK([controller validateMenuItem:toRight]);
	CHECK([toRight.title isEqualToString:@"Copy to the Right"]);
	[controller copyToRight:nil];
	CHECK(controller.lastProblem == nil);
	CHECK([Contents(fixture.right, @"grown.txt") isEqualToString:@"short\n"]);
	CHECK(RowFor(left, @"grown.txt") == -1); // identical now, hidden by the Changed filter
	CHECK([summary.stringValue hasPrefix:@"4 modified"]);
	CHECK(undo.canUndo && [undo.undoActionName isEqualToString:@"Copy to the Right"]);
	[undo undo];
	CHECK([Contents(fixture.right, @"grown.txt") isEqualToString:@"much longer contents\n"]);
	CHECK(RowFor(left, @"grown.txt") != -1);
	CHECK([summary.stringValue hasPrefix:@"5 modified"]);
	CHECK(undo.canRedo);
	[undo redo];
	CHECK([Contents(fixture.right, @"grown.txt") isEqualToString:@"short\n"]);
	[undo undo];
	CHECK([Contents(fixture.right, @"grown.txt") isEqualToString:@"much longer contents\n"]);

	// Right to left.
	SelectRow(left, @"grown.txt");
	[controller copyToLeft:nil];
	CHECK([Contents(fixture.left, @"grown.txt") isEqualToString:@"much longer contents\n"]);
	[undo undo];
	CHECK([Contents(fixture.left, @"grown.txt") isEqualToString:@"short\n"]);

	// A file only on the left, and a folder only on the right.
	SelectRow(left, @"left-only.txt");
	[controller copyToRight:nil];
	CHECK([Contents(fixture.right, @"left-only.txt") isEqualToString:@"untracked on the left\n"]);
	SelectRow(left, @"newdir");
	NSMenuItem* toLeft = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(copyToLeft:) keyEquivalent:@""];
	CHECK([controller validateMenuItem:toLeft] && ![controller validateMenuItem:toRight]);
	[controller copyToLeft:nil];
	CHECK([Contents(fixture.left, @"newdir/x.txt") isEqualToString:@"new on the right\n"]);
	CHECK(RowFor(left, @"newdir") == -1);
	[undo undo];
	CHECK(!CompareStampAtPath([fixture.left stringByAppendingPathComponent:@"newdir"]).exists);
	CHECK(RowFor(left, @"newdir") != -1);
	[undo undo];
	CHECK(!CompareStampAtPath([fixture.right stringByAppendingPathComponent:@"left-only.txt"]).exists);

	// Move to Trash (the left's gone.txt is the only copy), then undo.
	NSMenuItem* trash = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(trashClickedEntries:) keyEquivalent:@""];
	trash.representedObject = @{ @"left": @YES, @"paths": @[ @"gone.txt" ] };
	[controller trashClickedEntries:trash];
	CHECK(controller.lastProblem == nil);
	CHECK(RowFor(left, @"gone.txt") == -1);
	CHECK(!CompareStampAtPath([fixture.left stringByAppendingPathComponent:@"gone.txt"]).exists);
	[undo undo];
	CHECK([Contents(fixture.left, @"gone.txt") isEqualToString:@"tracked\n"]);
	CHECK(RowFor(left, @"gone.txt") != -1);

	// A file changed since it was compared is not overwritten.
	[@"edited elsewhere\n" writeToFile:[fixture.right stringByAppendingPathComponent:@"same-size.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
	SelectRow(left, @"same-size.txt");
	[controller copyToRight:nil];
	CHECK([controller.lastProblem containsString:@"changed on the right"]);
	CHECK([Contents(fixture.right, @"same-size.txt") isEqualToString:@"edited elsewhere\n"]);
	[controller refresh:nil];
	CHECK(WaitUntil(^{ return Loaded(controller); }));

	// Copying single changes from a file tab.
	CompareDiffView* diff = Show(controller, @"multi.txt");
	CHECK(diff.changeCount == 2 && diff.currentChange == 0);
	Snapshot(controller, @"changes");
	CHECK([controller validateMenuItem:toRight]);
	CHECK([toRight.title isEqualToString:@"Copy Change to the Right"]);
	[controller copyToRight:nil]; // line 3, left to right
	CHECK(controller.lastProblem == nil);
	CHECK([Contents(fixture.right, @"multi.txt") hasPrefix:@"line 1\nline 2\nline 3\nline 4\n"]);
	CHECK([Contents(fixture.right, @"multi.txt") containsString:@"line 16 changed\n"]);
	CHECK(WaitUntil(^{ return (BOOL)!diff.loading; }));
	CHECK(diff.changeCount == 1 && diff.currentChange == 0);

	// The arrows between the sides: line 16, right to left.
	diff.changeHandler(diff, 0, NO);
	CHECK(WaitUntil(^{ return (BOOL)!diff.loading; }));
	CHECK([Contents(fixture.left, @"multi.txt") containsString:@"line 16 changed\n"]);
	CHECK(diff.changeCount == 0);
	CHECK([diff.statusText isEqualToString:@"No differences"]);
	[controller selectTabAtIndex:0];
	CHECK(RowFor(left, @"multi.txt") == -1);

	[undo undo];
	[undo undo];
	[controller selectTabAtIndex:1];
	CHECK(WaitUntil(^{ return (BOOL)!diff.loading; }));
	CHECK(diff.changeCount == 2);
	CHECK(![Contents(fixture.left, @"multi.txt") containsString:@"changed"]);

	// A file tab refuses to copy over a file edited since it was shown.
	[[Contents(fixture.right, @"multi.txt") stringByAppendingString:@"appended\n"] writeToFile:[fixture.right stringByAppendingPathComponent:@"multi.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
	[controller copyToRight:nil];
	CHECK([controller.lastProblem containsString:@"changed since it was compared"]);
	CHECK([Contents(fixture.right, @"multi.txt") hasSuffix:@"appended\n"]);

	SelectFilter(controller, 0);
	[controller close];
}

static void TestFocus (compare_fixture_t const& fixture)
{
	CompareWindowController* controller = Open(fixture, @"deep/a");
	NSOutlineView* left  = [controller outlineViewForLeftSide:YES];
	NSOutlineView* right = [controller outlineViewForLeftSide:NO];
	CHECK(RowFor(left, @"deep/a/b.txt") != -1);
	CHECK(RowFor(right, @"deep/a/b.txt") != -1);
	CHECK(Aligned(controller));

	// Re-requesting the window with another focus reveals it.
	controller.focus = @"newdir";
	CHECK(RowFor(left, @"newdir/x.txt") != -1);
	CHECK(Aligned(controller));
	[controller close];
}

int main (int argc, char const* argv[])
{
	@autoreleasepool
	{
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
		RegisterDefaults(); // tab widths, as Compare.app's main does
		[NSUserDefaults.standardUserDefaults setVolatileDomain:@{ @"compareFilter": @0, kUserDefaultsFoldersOnTopKey: @YES } forName:NSArgumentDomain];
		CompareWindowController.gitExecutable = @COMPARE_TEST_GIT;
		CompareWindowController.confirmsChanges = NO;

		compare_fixture_t fixture = compare_fixture::create(@COMPARE_TEST_GIT);
		CHECK(fixture.error == nil);
		if(!fixture.error)
		{
			TestChangedFilter(fixture);
			TestFileTabs(fixture);

			// Transfers change files: use a fixture of their own.
			compare_fixture_t writable = compare_fixture::create(@COMPARE_TEST_GIT);
			CHECK(writable.error == nil);
			if(!writable.error)
				TestTransfers(writable);
			TestFocus(fixture);
		}

		if(Failures)
			fprintf(stderr, "compare-window: %d assertion(s) failed\n", Failures);
		else
			fprintf(stdout, "compare-window: all checks passed\n");
		return Failures ? 1 : 0;
	}
}
