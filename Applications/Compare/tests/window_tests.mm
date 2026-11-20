#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#import <Preferences/Keys.h>
#import <OakTabBarView/OakTabBarView.h>
#import "../src/CompareWindowController.h"
#import "../src/compare_tree.h"
#import "../src/compare_colors.h"
#import "../src/CompareDiffView.h"
#import "compare_fixture.h"
#import "syntax_fixture.h"
#import "../src/compare_menu.h"
#import "../src/CompareSettings.h"

// Drives the real CompareWindowController over the shared fixture. Failures
// print `file:line: Assertion failed: …` and make the process exit non-zero.
// Set COMPARE_SNAPSHOT_DIR to also write light and dark PNG snapshots.

@interface CompareTreeStrip : NSView
- (BOOL)hasArrowForRow:(NSInteger)row toRight:(BOOL)toRight;
- (void)clickRow:(NSInteger)row toRight:(BOOL)toRight;
- (BOOL)clickAtPoint:(NSPoint)point;
- (NSRect)arrowRectForRow:(NSInteger)row toRight:(BOOL)toRight;
- (NSRect)rowsArea;
@end

@interface CompareWindowController (Testing)
- (NSOutlineView*)outlineViewForLeftSide:(BOOL)left;
- (void)setFilter:(NSInteger)filter;
- (IBAction)expandAllFolders:(id)sender;
- (IBAction)editInTextMate:(id)sender;
- (void)menuNeedsUpdate:(NSMenu*)menu;
- (IBAction)collapseAllFolders:(id)sender;
- (void)takeDisplayModeFrom:(NSMenuItem*)sender;
- (void)toggleIgnoredFilesFromMenu:(id)sender;
- (CompareDiffView*)selectedDiffView;
- (NSUInteger)tabCount;
- (NSUInteger)selectedTabIndex;
- (void)selectTabAtIndex:(NSUInteger)index;
- (void)closeTabAtIndex:(NSUInteger)index;
- (void)openSelectedFiles:(id)sender;
- (void)closeTab:(id)sender;
- (NSString*)tabBarView:(id)tabBar titleForIndex:(NSUInteger)index;
- (BOOL)tabBarView:(id)tabBar isClosableAtIndex:(NSUInteger)index;
- (void)trashClickedEntries:(NSMenuItem*)sender;
- (void)searchChanged:(NSSearchField*)sender;
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
	[controller setFilter:filter];
	[controller.window layoutIfNeeded];
}

// Draws the content view into a PNG for looking at by hand. The rendering
// checks below use real window pixels instead.
static void Snapshot (NSWindowController* controller, NSString* name)
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

// ==================
// = Rendered pixels =
// ==================

// The window as the window server shows it. Snapshots of the view hierarchy
// miss what covers it (a view drawing outside its bounds once blanked most of
// the window), so these checks read real pixels. An app may capture its own
// windows; CGWindowListCreateImage is looked up at run time because newer SDKs
// mark it unavailable. Returns nil when capturing is not possible.
static NSBitmapImageRep* RenderedWindow (NSWindow* window)
{
	typedef CGImageRef (*capture_t)(CGRect, uint32_t, uint32_t, uint32_t);
	static capture_t capture = (capture_t)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
	if(!capture)
		return nil;
	[window orderFrontRegardless];
	[window displayIfNeeded];
	for(NSDate* until = [NSDate dateWithTimeIntervalSinceNow:0.5]; until.timeIntervalSinceNow > 0; )
		[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	CGImageRef image = capture(CGRectNull, 1 << 3 /* this window */, (uint32_t)window.windowNumber, 1 << 0 /* without the shadow */);
	if(!image)
		return nil;
	NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
	CGImageRelease(image);
	return rep;
}

// The colour at the centre of `rect` (in `view`'s coordinates), in the captured window.
static NSColor* PixelAt (NSBitmapImageRep* rendered, NSView* view, NSRect rect)
{
	NSWindow* window = view.window;
	NSPoint center = [view convertPoint:NSMakePoint(NSMidX(rect), NSMidY(rect)) toView:nil];
	CGFloat scale = rendered.pixelsWide / NSWidth(window.frame);
	NSInteger x = (NSInteger)(center.x * scale);
	NSInteger y = (NSInteger)((NSHeight(window.frame) - center.y) * scale); // image rows start at the top
	return [[rendered colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
}

static BOOL SameColor (NSColor* lhs, NSColor* rhs)
{
	return lhs && rhs && fabs(lhs.redComponent - rhs.redComponent) < 0.03 && fabs(lhs.greenComponent - rhs.greenComponent) < 0.03 && fabs(lhs.blueComponent - rhs.blueComponent) < 0.03;
}

static BOOL White (NSColor* color)
{
	return color && color.redComponent > 0.97 && color.greenComponent > 0.97 && color.blueComponent > 0.97;
}

static void TestChangedFilter (compare_fixture_t const& fixture)
{
	CompareWindowController* controller = Open(fixture, nil);
	NSOutlineView* left  = [controller outlineViewForLeftSide:YES];
	NSOutlineView* right = [controller outlineViewForLeftSide:NO];

	NSTextField* summary = [controller valueForKey:@"_summaryLabel"];
	CHECK([summary.stringValue isEqualToString:@"5 modified · 2 only on the left · 1 only on the right · 1 changed type"]);
	CHECK([controller.window.title isEqualToString:@"main ⇄ feature"]);

	NSArray* names = TopLevelNames(left);
	CHECK([names isEqual:(@[ @"deep", @"kind", @"newdir", @"gone.txt", @"grown.txt", @"left-only.txt", @"link", @"multi.txt", @"same-size.txt" ])]);
	CHECK(Aligned(controller));

	// A new comparison opens the folders above changed files, on both sides;
	// folders that are differences themselves stay collapsed.
	CHECK(RowFor(left, @"deep/a/b.txt") != -1 && RowFor(right, @"deep/a/b.txt") != -1);
	CHECK(RowFor(left, @"deep/a/b.txt") == RowFor(right, @"deep/a/b.txt"));
	CHECK(RowFor(left, @"newdir") != -1 && RowFor(left, @"newdir/x.txt") == -1); // only on the right
	CHECK(RowFor(left, @"kind") != -1 && RowFor(left, @"kind/inner.txt") == -1);  // a file on the left
	[left collapseItem:nil collapseChildren:YES];

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
	// A folder on both sides is not itself a difference: default background,
	// with a dot because something inside it differs.
	CHECK(TintAt(left, @"deep") == nil && TintAt(right, @"deep") == nil);
	CHECK([[[left rowViewAtRow:RowFor(left, @"deep") makeIfNecessary:YES] valueForKey:@"marker"] boolValue]);
	CHECK(![[[left rowViewAtRow:RowFor(left, @"grown.txt") makeIfNecessary:YES] valueForKey:@"marker"] boolValue]);
	CHECK(![[[left rowViewAtRow:RowFor(left, @"newdir") makeIfNecessary:YES] valueForKey:@"marker"] boolValue]); // one-sided: tinted instead
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

	// The View menu chooses the display mode, with the current one checked.
	NSMenuItem* modes[4];
	for(NSInteger mode = 0; mode < 4; ++mode)
	{
		modes[mode] = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(takeDisplayModeFrom:) keyEquivalent:@""];
		modes[mode].tag = mode;
	}
	[controller takeDisplayModeFrom:modes[3]];
	CHECK(RowFor(left, @"same.txt") != -1); // identical files are shown
	for(NSInteger mode = 0; mode < 4; ++mode)
	{
		[controller validateMenuItem:modes[mode]];
		CHECK(modes[mode].state == (mode == 3 ? NSControlStateValueOn : NSControlStateValueOff));
	}
	[controller takeDisplayModeFrom:modes[0]];
	CHECK(RowFor(left, @"same.txt") == -1);
	[controller validateMenuItem:modes[0]];
	CHECK(modes[0].state == NSControlStateValueOn);
	// The window has no display-mode or ignored-files controls of its own.
	for(NSView* view in [[controller valueForKey:@"_summaryLabel"] superview].subviews)
	{
		CHECK(![view isKindOfClass:NSSegmentedControl.class]);
		CHECK(!([view isKindOfClass:NSButton.class] && [[(NSButton*)view title] isEqualToString:@"Ignored Files"]));
	}
	SelectFilter(controller, 2);

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

	// Both trees are on screen, also after showing a file tab: the same
	// modified row has the same tint on both sides.
	controller.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	if(NSBitmapImageRep* rendered = RenderedWindow(controller.window))
	{
		NSOutlineView* right = [controller outlineViewForLeftSide:NO];
		NSInteger row = RowFor(left, @"grown.txt");
		NSRect leftRow = [left rectOfRow:row], rightRow = [right rectOfRow:row];
		leftRow.size.width = rightRow.size.width = 8; // the row's leading edge, away from text
		NSColor* leftColor  = PixelAt(rendered, left, leftRow);
		NSColor* rightColor = PixelAt(rendered, right, rightRow);
		CHECK(SameColor(leftColor, rightColor));
		CHECK(!White(leftColor));

		// A placeholder (left-only.txt has no file on the right) is hatched:
		// along the row there are stripe pixels and pixels between stripes.
		NSRect placeholder = [right rectOfRow:RowFor(right, @"left-only.txt")];
		NSColor* first = PixelAt(rendered, right, NSMakeRect(NSMinX(placeholder) + 2, NSMidY(placeholder), 0, 0));
		BOOL varies = NO;
		for(CGFloat x = NSMinX(placeholder) + 3; x < NSMinX(placeholder) + 20 && !varies; x += 1)
			varies = !SameColor(first, PixelAt(rendered, right, NSMakeRect(x, NSMidY(placeholder), 0, 0)));
		CHECK(varies);
		// A modified row is a flat tint.
		NSColor* flat = PixelAt(rendered, left, NSMakeRect(NSMinX(leftRow) + 2, NSMidY(leftRow), 0, 0));
		BOOL uniform = YES;
		for(CGFloat x = NSMinX(leftRow) + 3; x < NSMinX(leftRow) + 20 && uniform; x += 1)
			uniform = SameColor(flat, PixelAt(rendered, left, NSMakeRect(x, NSMidY(leftRow), 0, 0)));
		CHECK(uniform);
	}
	else
	{
		fprintf(stderr, "compare-window: window capture unavailable, rendering checks skipped\n");
	}

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
	if(NSBitmapImageRep* rendered = RenderedWindow(controller.window))
	{
		// The changed line's tint, past the end of the text on both sides.
		NSRect leftLine  = NSMakeRect(NSMaxX(diff.leftTextView.visibleRect) - 20, 4, 4, 4);
		NSRect rightLine = NSMakeRect(NSMaxX(diff.rightTextView.visibleRect) - 20, 4, 4, 4);
		NSColor* leftColor  = PixelAt(rendered, diff.leftTextView, leftLine);
		NSColor* rightColor = PixelAt(rendered, diff.rightTextView, rightLine);
		CHECK(!White(leftColor) && SameColor(leftColor, rightColor));
		// Back on the Files tab, the trees are drawn again.
		[controller selectTabAtIndex:0];
		if(NSBitmapImageRep* trees = RenderedWindow(controller.window))
		{
			NSRect row = [left rectOfRow:RowFor(left, @"grown.txt")];
			row.size.width = 8;
			CHECK(!White(PixelAt(trees, left, row)));
		}
		[controller selectTabAtIndex:1];
	}

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
	// The line-number gutter carries the row tints too: line 3 changed, line 1 not.
	if(NSBitmapImageRep* rendered = RenderedWindow(controller.window))
	{
		NSTextView* text = diff.leftTextView;
		NSView* ruler = text.enclosingScrollView.verticalRulerView;
		auto gutterPixel = ^NSColor*(NSInteger row){
			NSPoint inText = NSMakePoint(0, text.textContainerOrigin.y + (row + 0.5) * diff.rowHeight);
			NSPoint inRuler = [ruler convertPoint:inText fromView:text];
			return PixelAt(rendered, ruler, NSMakeRect(3, inRuler.y, 0, 0));
		};
		NSColor* unchanged = gutterPixel(0);
		NSColor* changed   = gutterPixel(2);
		CHECK(!SameColor(unchanged, changed));
		CHECK(SameColor(unchanged, gutterPixel(1)));
	}
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

	// The Files tab has no close button; file tabs do.
	CHECK(![controller tabBarView:nil isClosableAtIndex:0] && [controller tabBarView:nil isClosableAtIndex:1]);
	{
		NSView* tabBar = [controller valueForKey:@"_tabBar"];
		[tabBar layoutSubtreeIfNeeded];
		int checked = 0;
		for(NSView* tabView in tabBar.subviews)
		{
			if(![NSStringFromClass(tabView.class) isEqualToString:@"OakTabView"] || ![tabView valueForKey:@"tabItem"])
				continue;
			[tabView setValue:@YES forKey:@"mouseInside"]; // as when the pointer is over the tab
			BOOL files = [[tabView valueForKeyPath:@"tabItem.title"] isEqualToString:@"Files"];
			NSView* closeButton = [tabView valueForKey:@"closeButton"];
			CHECK(files ? closeButton.alphaValue == 0 : closeButton.alphaValue == 1);
			[tabView setValue:@NO forKey:@"mouseInside"];
			++checked;
		}
		CHECK(checked >= 2);
	}

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

	// The arrows between the trees: only where there is something to copy that way.
	[controller selectTabAtIndex:0];
	SelectFilter(controller, 3);
	CompareTreeStrip* strip = [controller valueForKey:@"_treeStrip"];
	CHECK([strip hasArrowForRow:RowFor(left, @"grown.txt") toRight:YES] && [strip hasArrowForRow:RowFor(left, @"grown.txt") toRight:NO]);
	CHECK([strip hasArrowForRow:RowFor(left, @"left-only.txt") toRight:YES] && ![strip hasArrowForRow:RowFor(left, @"left-only.txt") toRight:NO]);
	CHECK(![strip hasArrowForRow:RowFor(left, @"newdir") toRight:YES] && [strip hasArrowForRow:RowFor(left, @"newdir") toRight:NO]);
	// A folder on both sides only contains differences: no arrows (it looks
	// identical), though Copy to the Right still copies what differs inside it.
	CHECK(![strip hasArrowForRow:RowFor(left, @"deep") toRight:YES] && ![strip hasArrowForRow:RowFor(left, @"deep") toRight:NO]);
	SelectRow(left, @"deep");
	CHECK([controller validateMenuItem:toRight]);
	CHECK(![strip hasArrowForRow:RowFor(left, @"same.txt") toRight:YES] && ![strip hasArrowForRow:RowFor(left, @"same.txt") toRight:NO]);
	[controller.window layoutIfNeeded];
	NSOutlineView* right = [controller outlineViewForLeftSide:NO];
	NSRect leftPane  = [left.enclosingScrollView convertRect:left.enclosingScrollView.bounds toView:nil];
	NSRect rightPane = [right.enclosingScrollView convertRect:right.enclosingScrollView.bounds toView:nil];
	NSRect stripRect = [strip convertRect:strip.bounds toView:nil];
	CHECK(NSWidth(leftPane) > 400 && NSWidth(leftPane) == NSWidth(rightPane));
	CHECK(NSWidth(stripRect) == 34 && NSMinX(stripRect) == NSMaxX(leftPane) && NSMaxX(stripRect) == NSMinX(rightPane));
	CHECK(NSMinY(stripRect) <= NSMinY(leftPane) && NSMaxY(stripRect) >= NSMaxY(leftPane));
	NSRect grownRow = [left convertRect:[left rectOfRow:RowFor(left, @"grown.txt")] toView:nil];
	CHECK(NSIntersectsRect(grownRow, leftPane)); // visible, so its arrows are drawn
	CHECK(left.window == controller.window && strip.window == controller.window);
	Snapshot(controller, @"arrows");
	CHECK(!NSIsEmptyRect(strip.rowsArea));
	CHECK(NSIntersectsRect([strip arrowRectForRow:RowFor(left, @"grown.txt") toRight:YES], strip.rowsArea));
	// Clicking where nothing can be copied does nothing.
	NSRect sameArrow = [strip arrowRectForRow:RowFor(left, @"same.txt") toRight:YES];
	CHECK(![strip clickAtPoint:NSMakePoint(NSMidX(sameArrow), NSMidY(sameArrow))]);
	// Clicking the → beside grown.txt, as a mouse click would.
	NSRect arrow = [strip arrowRectForRow:RowFor(left, @"grown.txt") toRight:YES];
	CHECK([strip clickAtPoint:NSMakePoint(NSMidX(arrow), NSMidY(arrow))]);
	CHECK([Contents(fixture.right, @"grown.txt") isEqualToString:@"short\n"]);
	CHECK(![strip hasArrowForRow:RowFor(left, @"grown.txt") toRight:YES]);
	[undo undo];
	CHECK([Contents(fixture.right, @"grown.txt") isEqualToString:@"much longer contents\n"]);
	SelectFilter(controller, 0);
	[controller selectTabAtIndex:1];

	// Redo replays a copy only over the state Undo restored: an edit made
	// after the undo is not overwritten, even once Compare has refreshed.
	[controller selectTabAtIndex:0];
	SelectFilter(controller, 3);
	SelectRow(left, @"same-size.txt");
	[controller refresh:nil];
	CHECK(WaitUntil(^{ return Loaded(controller); }));
	SelectRow(left, @"same-size.txt");
	NSString* sameSize = [fixture.right stringByAppendingPathComponent:@"same-size.txt"];
	NSString* beforeCopy = Contents(fixture.right, @"same-size.txt");
	[controller copyToRight:nil];
	CHECK(controller.lastProblem == nil);
	[undo undo];
	CHECK([Contents(fixture.right, @"same-size.txt") isEqualToString:beforeCopy]);
	[@"edited after the undo\n" writeToFile:sameSize atomically:NO encoding:NSUTF8StringEncoding error:nil];
	[controller refresh:nil];
	CHECK(WaitUntil(^{ return Loaded(controller); }));
	CHECK(undo.canRedo);
	[undo redo];
	CHECK([controller.lastProblem containsString:@"has changed since the undo"]);
	CHECK([Contents(fixture.right, @"same-size.txt") isEqualToString:@"edited after the undo\n"]);
	// Untouched, redo still works.
	SelectRow(left, @"grown.txt");
	[controller copyToRight:nil];
	[undo undo];
	[undo redo];
	CHECK(controller.lastProblem == nil);
	CHECK([Contents(fixture.right, @"grown.txt") isEqualToString:@"short\n"]);
	[undo undo];
	SelectFilter(controller, 0);
	[controller selectTabAtIndex:1];

	// After a new comparison, an unchanged tab still copies to the right
	// place: a change into a file that exists only on the left.
	{
		CompareDiffView* onlyLeft = Show(controller, @"left-only.txt");
		[controller refresh:nil];
		CHECK(WaitUntil(^{ return Loaded(controller); }));
		CHECK(onlyLeft.changeCount == 1);
		[controller copyToRight:nil];
		CHECK(controller.lastProblem == nil);
		CHECK([Contents(fixture.right, @"left-only.txt") isEqualToString:@"untracked on the left\n"]);
		[undo undo];
		CHECK(!CompareStampAtPath([fixture.right stringByAppendingPathComponent:@"left-only.txt"]).exists);
		[controller closeTab:nil];
		[controller selectTabAtIndex:1];
	}

	// A file tab refuses to copy over a file edited since it was shown.
	[[Contents(fixture.right, @"multi.txt") stringByAppendingString:@"appended\n"] writeToFile:[fixture.right stringByAppendingPathComponent:@"multi.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
	[controller copyToRight:nil];
	CHECK([controller.lastProblem containsString:@"changed since it was compared"]);
	CHECK([Contents(fixture.right, @"multi.txt") hasSuffix:@"appended\n"]);

	SelectFilter(controller, 0);
	[controller close];
}

static void Spin (NSTimeInterval seconds)
{
	NSDate* until = [NSDate dateWithTimeIntervalSinceNow:seconds];
	while(until.timeIntervalSinceNow > 0)
		[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

// After a change that must not compare again: waits for the window to receive
// its file system event (which can take seconds), then long enough for a
// comparison it would start, and says whether none did.
static BOOL IgnoresChange (CompareWindowController* controller, void (^change)())
{
	NSUInteger events = controller.fileEventCount;
	NSUInteger count  = controller.comparisonCount;
	change();
	if(!WaitUntil(^{ return (BOOL)(controller.fileEventCount > events); }))
		return NO;
	Spin(1.5);
	return controller.comparisonCount == count && Loaded(controller);
}

static void Search (CompareWindowController* controller, NSString* text)
{
	NSSearchField* field = [controller valueForKey:@"_searchField"];
	field.stringValue = text;
	[controller searchChanged:field];
	[controller.window layoutIfNeeded];
}

static void TestLiveRefreshAndSearch (compare_fixture_t const& fixture)
{
	CompareWindowController* controller = Open(fixture, nil);
	[controller.window setFrame:NSMakeRect(100, 100, 1000, 700) display:NO];
	NSOutlineView* left = [controller outlineViewForLeftSide:YES];

	// An edit to a compared file compares again.
	NSUInteger count = controller.comparisonCount;
	[@"now different\n" writeToFile:[fixture.right stringByAppendingPathComponent:@"same.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
	CHECK(WaitUntil(^{ return (BOOL)(controller.comparisonCount > count && Loaded(controller)); }));
	CHECK(RowFor(left, @"same.txt") != -1);

	// Ignored build output does not.
	CHECK(IgnoresChange(controller, ^{
		[@"object\n" writeToFile:[fixture.left stringByAppendingPathComponent:@"build/new.o"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
	}));

	// A new file that is not ignored appears.
	[@"hello\n" writeToFile:[fixture.right stringByAppendingPathComponent:@"brand-new.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
	CHECK(WaitUntil(^{ return (BOOL)(RowFor(left, @"brand-new.txt") != -1); }));

	// An open tab keeps its place when its file changes elsewhere.
	CompareDiffView* diff = Show(controller, @"multi.txt");
	[NSApp sendAction:@selector(nextChange:) to:controller from:nil];
	CHECK(diff.currentChange == 1);
	count = controller.comparisonCount;
	NSString* multi = [fixture.right stringByAppendingPathComponent:@"multi.txt"];
	[[[NSString stringWithContentsOfFile:multi encoding:NSUTF8StringEncoding error:nil] stringByAppendingString:@"extra\n"] writeToFile:multi atomically:NO encoding:NSUTF8StringEncoding error:nil];
	CHECK(WaitUntil(^{ return (BOOL)(controller.comparisonCount > count && !diff.loading && diff.changeCount == 3); }));
	CHECK(diff.currentChange == 1);
	[controller selectTabAtIndex:0];

	// View → Show Ignored Files, also from a file tab; the menu item is checked.
	[controller selectTabAtIndex:1];
	NSMenuItem* showIgnored = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(toggleIgnoredFilesFromMenu:) keyEquivalent:@""];
	count = controller.comparisonCount;
	[controller toggleIgnoredFilesFromMenu:showIgnored];
	CHECK(controller.selectedTabIndex == 0);
	CHECK(WaitUntil(^{ return (BOOL)(controller.comparisonCount > count && Loaded(controller)); }));
	CHECK(RowFor(left, @"build") != -1);
	[controller validateMenuItem:showIgnored];
	CHECK(showIgnored.state == NSControlStateValueOn);
	count = controller.comparisonCount;
	[controller toggleIgnoredFilesFromMenu:showIgnored];
	[controller validateMenuItem:showIgnored];
	CHECK(showIgnored.state == NSControlStateValueOff);
	CHECK(WaitUntil(^{ return (BOOL)(controller.comparisonCount > count && Loaded(controller)); }));
	CHECK(RowFor(left, @"build") == -1);

	// Searching by name expands to the matches; clearing restores the expansion.
	[left collapseItem:nil collapseChildren:YES];
	[left expandItem:[left itemAtRow:RowFor(left, @"newdir")]];
	Search(controller, @"B.TXT");
	CHECK([TopLevelNames(left) isEqual:(@[ @"deep" ])]);
	CHECK(RowFor(left, @"deep/a/b.txt") != -1);
	CHECK(Aligned(controller));
	Search(controller, @"deep"); // a matching folder shows what is inside it
	CHECK(RowFor(left, @"deep/a/b.txt") != -1);
	CHECK(RowFor(left, @"grown.txt") == -1);
	Search(controller, @"");
	CHECK(RowFor(left, @"grown.txt") != -1);
	CHECK(RowFor(left, @"deep/a") == -1); // collapsed again
	CHECK(RowFor(left, @"newdir/x.txt") != -1);

	// Expanded folders are remembered for this pair; folders above changed
	// files open again even if they were collapsed.
	[controller close];
	CompareWindowController* reopened = Open(fixture, nil);
	CHECK(RowFor([reopened outlineViewForLeftSide:YES], @"newdir/x.txt") != -1);
	CHECK(RowFor([reopened outlineViewForLeftSide:YES], @"deep/a/b.txt") != -1);
	CHECK(RowFor([reopened outlineViewForLeftSide:YES], @"kind/inner.txt") == -1);
	[reopened close];
}

// File tabs use TextMate's syntax highlighting, theme and font for the file.
static void TestSyntaxHighlighting ()
{
	compare_fixture_t folders;
	NSString* base = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"compare-syntax-window-" stringByAppendingString:NSUUID.UUID.UUIDString]];
	folders.left  = [base stringByAppendingPathComponent:@"left"];
	folders.right = [base stringByAppendingPathComponent:@"right"];
	CHECK(compare_fixture::write(folders.left,  @"code.cmpt", @"// note\nkeyword one\n") == nil);
	CHECK(compare_fixture::write(folders.right, @"code.cmpt", @"// note\nkeyword two\nextra\n") == nil);

	CompareWindowController* controller = Open(folders, nil);
	controller.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	[controller.window setFrame:NSMakeRect(100, 100, 1000, 600) display:NO];
	CompareDiffView* diff = Show(controller, @"code.cmpt");
	NSTextView* right = diff.rightTextView;
	CHECK([syntax_fixture::hex(right.backgroundColor) isEqualToString:@"#FAFAFA"]);
	CHECK([syntax_fixture::hex(AttributeAt(right, NSForegroundColorAttributeName, 0)) isEqualToString:@"#FF0000"]);   // comment
	NSUInteger keyword = [right.string rangeOfString:@"keyword"].location;
	CHECK([syntax_fixture::hex(AttributeAt(right, NSForegroundColorAttributeName, keyword)) isEqualToString:@"#0000FF"]);
	NSFont* font = AttributeAt(right, NSFontAttributeName, keyword);
	CHECK(font && (CTFontGetSymbolicTraits((__bridge CTFontRef)font) & kCTFontBoldTrait));
	CHECK([syntax_fixture::hex(AttributeAt(right, NSForegroundColorAttributeName, keyword + 8)) isEqualToString:@"#111111"]); // plain text
	// The tints still mark differences on top of the theme.
	CHECK(AttributeAt(right, CompareLineTintAttributeName, keyword) == compare::modified_color());
	CHECK(diff.rowHeight > 0);

	// In dark appearance the dark theme is used, and the tints follow it.
	[controller closeTabAtIndex:1];
	controller.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
	diff = Show(controller, @"code.cmpt");
	CHECK([syntax_fixture::hex(diff.rightTextView.backgroundColor) isEqualToString:@"#101010"]);
	CHECK([diff.rightTextView.enclosingScrollView.appearance.name isEqualToString:NSAppearanceNameDarkAqua]);
	Snapshot(controller, @"syntax");
	[controller close];
}

// A View menu choice applies to every open window; new windows in the tests
// start in the default mode because the defaults are pinned in the argument
// domain (so tests cannot leak a mode into one another).
static void TestDisplayModeAcrossWindows (compare_fixture_t const& fixture)
{
	CompareWindowController* first  = Open(fixture, nil);
	CompareWindowController* second = Open(fixture, nil);
	NSMenuItem* all = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(takeDisplayModeFrom:) keyEquivalent:@""];
	all.tag = 3;
	[first takeDisplayModeFrom:all];
	[second.window layoutIfNeeded];
	CHECK(RowFor([second outlineViewForLeftSide:YES], @"same.txt") != -1);
	[second validateMenuItem:all];
	CHECK(all.state == NSControlStateValueOn);

	CompareWindowController* third = Open(fixture, nil);
	NSMenuItem* changed = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(takeDisplayModeFrom:) keyEquivalent:@""];
	changed.tag = 0;
	[third validateMenuItem:changed];
	CHECK(changed.state == NSControlStateValueOn);
	CHECK(RowFor([third outlineViewForLeftSide:YES], @"same.txt") == -1);

	all.tag = 0;
	[first takeDisplayModeFrom:all]; // back to the default for later tests
	[first close];
	[second close];
	[third close];
}

// Records which View menu action AppKit sent for a key equivalent.
@interface MenuActionRecorder : NSObject
@property (nonatomic) SEL action;
@property (nonatomic) NSInteger tag;
@end

@implementation MenuActionRecorder
- (void)takeDisplayModeFrom:(NSMenuItem*)sender  { _action = _cmd; _tag = sender.tag; }
- (void)toggleIgnoredFilesFromMenu:(id)sender    { _action = _cmd; }
@end

// The View menu's shortcuts, matched by AppKit as for a real key press.
static void TestViewMenuShortcuts ()
{
	NSMenu* menu = compare::view_menu();
	MenuActionRecorder* recorder = [MenuActionRecorder new];
	for(NSMenuItem* item in menu.itemArray)
		item.target = recorder;
	NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	auto press = ^BOOL(NSString* characters, NSString* ignoringModifiers, unsigned short keyCode, NSEventModifierFlags flags){
		recorder.action = NULL;
		NSEvent* event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:window.windowNumber context:nil characters:characters charactersIgnoringModifiers:ignoringModifiers isARepeat:NO keyCode:keyCode];
		return [menu performKeyEquivalent:event];
	};
	// ⇧⌘. on a US layout: Shift turns “.” into “>”.
	CHECK(press(@">", @">", 47, NSEventModifierFlagCommand|NSEventModifierFlagShift));
	CHECK(recorder.action == @selector(toggleIgnoredFilesFromMenu:));
	// Expand All and Collapse All are there, without shortcuts.
	CHECK([menu indexOfItemWithTitle:@"Expand All"] != -1 && [menu itemWithTitle:@"Expand All"].keyEquivalent.length == 0);
	CHECK([menu itemWithTitle:@"Collapse All"].action == @selector(collapseAllFolders:));
	// ⌘4: All Files.
	CHECK(press(@"4", @"4", 21, NSEventModifierFlagCommand));
	CHECK(recorder.action == @selector(takeDisplayModeFrom:) && recorder.tag == 3);
	// The ignored-files item explains itself.
	CHECK([[menu itemWithTitle:@"Show Ignored Files"].toolTip containsString:@".gitignore"]);
}

// Settings → Ignore folders and files: node_modules is hidden by default, on
// both sides and from live refresh; changing the setting in the Settings
// window compares every open window again.
static void TestIgnoreSetting (compare_fixture_t const& fixture)
{
	CHECK([CompareSettings.excludedNames isEqualToString:@"node_modules"]);
	for(NSString* root in @[ fixture.left, fixture.right ]) // untracked and not gitignored: Git lists it
		CHECK(compare_fixture::write(root, @"node_modules/pkg/index.js", [root isEqualToString:fixture.left] ? @"v1\n" : @"v2\n") == nil);
	CHECK(compare_fixture::write(fixture.left, @"app/node_modules/only-left.js", @"x\n") == nil);

	CompareWindowController* controller = Open(fixture, nil);
	CompareWindowController* other      = Open(fixture, nil);
	NSOutlineView* left  = [controller outlineViewForLeftSide:YES];
	NSOutlineView* right = [controller outlineViewForLeftSide:NO];
	SelectFilter(controller, 3); // All Files: even identical entries would show
	CHECK(RowFor(left, @"same.txt") != -1);
	CHECK(RowFor(left, @"node_modules") == -1 && RowFor(right, @"node_modules") == -1);
	CHECK(RowFor(left, @"app") == -1); // nothing else inside it

	// Changes inside node_modules (npm install) do not compare again.
	CHECK(IgnoresChange(controller, ^{ compare_fixture::write(fixture.right, @"node_modules/pkg/new.js", @"new\n"); }));
	NSUInteger count;

	// The Settings window: a standard one, showing the current list.
	CompareSettingsWindowController* settings = CompareSettingsWindowController.sharedController;
	[settings showWindow:nil];
	CHECK(settings.window.isVisible);
	CHECK(settings.window.toolbarStyle == NSWindowToolbarStylePreference);
	CHECK([settings.window.title isEqualToString:@"General"]);
	CHECK([settings.window.toolbar.selectedItemIdentifier isEqualToString:@"general"]);
	CHECK([settings.excludedNamesField.stringValue isEqualToString:@"node_modules"]);
	Snapshot(settings, @"settings");

	// Clearing it shows node_modules in every open window.
	count = controller.comparisonCount;
	NSUInteger otherCount = other.comparisonCount;
	settings.excludedNamesField.stringValue = @"";
	[settings commitEditing];
	CHECK([CompareSettings.excludedNames isEqualToString:@""]);
	CHECK(WaitUntil(^{ return (BOOL)(controller.comparisonCount > count && Loaded(controller) && other.comparisonCount > otherCount && Loaded(other)); }));
	[controller.window layoutIfNeeded];
	CHECK(RowFor(left, @"node_modules") != -1);
	CHECK(RowFor([other outlineViewForLeftSide:YES], @"node_modules") != -1);
	[left expandItem:[left itemAtRow:RowFor(left, @"node_modules")] expandChildren:YES];
	CHECK(RowFor(left, @"node_modules/pkg/index.js") != -1);

	// Patterns: wildcards and paths from the top.
	count = controller.comparisonCount;
	settings.excludedNamesField.stringValue = @"node_*, multi.*";
	[settings commitEditing];
	CHECK(WaitUntil(^{ return (BOOL)(controller.comparisonCount > count && Loaded(controller)); }));
	CHECK(RowFor(left, @"node_modules") == -1 && RowFor(left, @"multi.txt") == -1);
	CHECK(RowFor(left, @"same.txt") != -1);

	// Unchanged text does not compare again; closing the window saves edits.
	count = controller.comparisonCount;
	[settings commitEditing];
	Spin(0.5);
	CHECK(controller.comparisonCount == count);
	settings.excludedNamesField.stringValue = @"node_modules";
	[settings.window close];
	CHECK([CompareSettings.excludedNames isEqualToString:@"node_modules"]);
	CHECK(WaitUntil(^{ return (BOOL)(controller.comparisonCount > count && Loaded(controller)); }));
	CHECK(RowFor(left, @"node_modules") == -1 && RowFor(left, @"multi.txt") != -1);

	SelectFilter(controller, 0);
	[controller close];
	[other close];
}

// View → Expand All and Collapse All, on both sides, within the display mode.
static void TestExpandAndCollapseAll (compare_fixture_t const& fixture)
{
	CompareWindowController* controller = Open(fixture, nil);
	NSOutlineView* left  = [controller outlineViewForLeftSide:YES];
	NSOutlineView* right = [controller outlineViewForLeftSide:NO];
	CHECK(RowFor(left, @"deep/a/b.txt") != -1); // opened above changed files

	// Also from a file tab, which switches to Files.
	Show(controller, @"multi.txt");
	CHECK(controller.selectedTabIndex == 1);
	NSMenuItem* collapse = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(collapseAllFolders:) keyEquivalent:@""];
	CHECK([controller validateMenuItem:collapse]);
	[controller collapseAllFolders:nil];
	CHECK(controller.selectedTabIndex == 0);
	CHECK(left.numberOfRows == (NSInteger)TopLevelNames(left).count);
	CHECK(right.numberOfRows == left.numberOfRows);
	CHECK(RowFor(left, @"deep/a") == -1);

	[controller expandAllFolders:nil];
	for(NSString* path in @[ @"deep/a/b.txt", @"kind/inner.txt", @"newdir/x.txt" ])
		CHECK(RowFor(left, path) != -1 && RowFor(left, path) == RowFor(right, path));
	CHECK(RowFor(left, @"deep/a/c.txt") == -1); // identical: not in Changed Files
	CHECK(Aligned(controller));

	// In All Files, identical entries inside folders show too.
	SelectFilter(controller, 3);
	[controller expandAllFolders:nil];
	CHECK(RowFor(left, @"deep/a/c.txt") != -1);
	CHECK(Aligned(controller));
	[controller collapseAllFolders:nil];
	CHECK(RowFor(left, @"deep/a/c.txt") == -1 && RowFor(left, @"deep/a") == -1);

	SelectFilter(controller, 0);
	[controller close];
}

// The file a txmt://open URL names, and its line (0 without one).
static NSString* EditedPath (NSURL* url, NSInteger* line = nullptr)
{
	NSMutableDictionary* parameters = [NSMutableDictionary dictionary];
	for(NSString* part in [url.query componentsSeparatedByString:@"&"])
	{
		NSArray* keyValue = [part componentsSeparatedByString:@"="];
		if(keyValue.count == 2)
			parameters[keyValue[0]] = [keyValue[1] stringByRemovingPercentEncoding];
	}
	if(line)
		*line = [parameters[@"line"] integerValue];
	return [parameters[@"url"] hasPrefix:@"file://"] ? [parameters[@"url"] substringFromIndex:7] : nil;
}

// File → Edit in TextMate (⌘E) and the trees' context menus open files in
// TextMate: the focused side's, at the current change in a file tab.
static void TestEditInTextMate (compare_fixture_t const& fixture)
{
	NSMutableArray<NSURL*>* opened = [NSMutableArray array];
	CompareWindowController.editHandler = ^(NSArray<NSURL*>* urls){ [opened addObjectsFromArray:urls]; };
	CompareWindowController* controller = Open(fixture, nil);
	[controller.window makeKeyAndOrderFront:nil];
	NSOutlineView* left  = [controller outlineViewForLeftSide:YES];
	NSOutlineView* right = [controller outlineViewForLeftSide:NO];
	NSMenuItem* edit = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(editInTextMate:) keyEquivalent:@""];

	// The selected file, on the left by default.
	SelectRow(left, @"grown.txt");
	CHECK([controller validateMenuItem:edit] && [edit.title isEqualToString:@"Edit in TextMate"]);
	[controller editInTextMate:nil];
	CHECK(opened.count == 1 && [EditedPath(opened.lastObject) isEqualToString:[fixture.left stringByAppendingPathComponent:@"grown.txt"]]);

	// The focused tree's side.
	[controller.window makeFirstResponder:right];
	[opened removeAllObjects];
	[controller editInTextMate:nil];
	CHECK(opened.count == 1 && [EditedPath(opened.lastObject) isEqualToString:[fixture.right stringByAppendingPathComponent:@"grown.txt"]]);

	// Nothing to edit: a file missing on that side, or a folder.
	SelectRow(left, @"gone.txt"); // only on the left
	CHECK(![controller validateMenuItem:edit]);
	[controller.window makeFirstResponder:left];
	CHECK([controller validateMenuItem:edit]);
	SelectRow(left, @"deep");
	CHECK(![controller validateMenuItem:edit]);

	// Several files at once, and the context menu of the clicked side.
	NSMutableIndexSet* rows = [NSMutableIndexSet indexSetWithIndex:RowFor(left, @"grown.txt")];
	[rows addIndex:RowFor(left, @"multi.txt")];
	[left selectRowIndexes:rows byExtendingSelection:NO];
	[controller menuNeedsUpdate:right.menu];
	NSMenuItem* contextEdit = [right.menu itemWithTitle:@"Edit in TextMate"];
	CHECK(contextEdit.action != NULL);
	[opened removeAllObjects];
	[NSApp sendAction:contextEdit.action to:contextEdit.target from:contextEdit];
	CHECK(opened.count == 2 && [EditedPath(opened.firstObject) hasPrefix:fixture.right] && [EditedPath(opened.lastObject) hasSuffix:@"/multi.txt"]);

	// A file tab opens at the current change's line (lines 3 and 16 differ).
	CompareDiffView* diff = Show(controller, @"multi.txt");
	CHECK(WaitUntil(^{ return (BOOL)(!diff.loading && diff.changeCount == 2); }));
	[controller.window makeFirstResponder:diff.leftTextView];
	CHECK([controller validateMenuItem:edit] && [edit.title isEqualToString:@"Edit Left in TextMate"]);
	[opened removeAllObjects];
	[controller editInTextMate:nil];
	NSInteger line = 0;
	CHECK(opened.count == 1 && [EditedPath(opened.lastObject, &line) isEqualToString:[fixture.left stringByAppendingPathComponent:@"multi.txt"]] && line == 3);
	[NSApp sendAction:@selector(nextChange:) to:controller from:nil];
	[controller.window makeFirstResponder:diff.rightTextView];
	CHECK([controller validateMenuItem:edit] && [edit.title isEqualToString:@"Edit Right in TextMate"]);
	[opened removeAllObjects];
	[controller editInTextMate:nil];
	CHECK(opened.count == 1 && [EditedPath(opened.lastObject, &line) isEqualToString:[fixture.right stringByAppendingPathComponent:@"multi.txt"]] && line == 16);

	CompareWindowController.editHandler = nil;
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
		// A test bundle (grammar and themes) plus these defaults, in the argument domain.
		CHECK(syntax_fixture::install(@{ @"compareFilter": @0, @"compareIncludeIgnored": @NO, @"themeAppearance": @"auto", kUserDefaultsFoldersOnTopKey: @YES }));
		CompareWindowController.gitExecutable = @COMPARE_TEST_GIT;
		CompareWindowController.confirmsChanges = NO;
		// Settings change while windows are open, so not in the argument domain;
		// start from the default.
		[NSUserDefaults.standardUserDefaults removeObjectForKey:CompareExcludedNamesDefaultsKey];

		compare_fixture_t fixture = compare_fixture::create(@COMPARE_TEST_GIT);
		CHECK(fixture.error == nil);
		if(!fixture.error)
		{
			TestChangedFilter(fixture);
			TestFileTabs(fixture);
			TestSyntaxHighlighting();
			TestViewMenuShortcuts();
			TestDisplayModeAcrossWindows(fixture);
			TestExpandAndCollapseAll(fixture);
			TestEditInTextMate(fixture);

			// Transfers change files: use a fixture of their own.
			compare_fixture_t writable = compare_fixture::create(@COMPARE_TEST_GIT);
			CHECK(writable.error == nil);
			if(!writable.error)
				TestTransfers(writable);

			compare_fixture_t live = compare_fixture::create(@COMPARE_TEST_GIT);
			CHECK(live.error == nil);
			if(!live.error)
				TestLiveRefreshAndSearch(live);

			compare_fixture_t ignoring = compare_fixture::create(@COMPARE_TEST_GIT);
			CHECK(ignoring.error == nil);
			if(!ignoring.error)
				TestIgnoreSetting(ignoring);
			TestFocus(fixture);
		}

		if(Failures)
			fprintf(stderr, "compare-window: %d assertion(s) failed\n", Failures);
		else
			fprintf(stdout, "compare-window: all checks passed\n");
		return Failures ? 1 : 0;
	}
}
