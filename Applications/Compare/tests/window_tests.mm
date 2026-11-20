#import <Cocoa/Cocoa.h>
#import <Preferences/Keys.h>
#import "../src/CompareWindowController.h"
#import "../src/compare_tree.h"
#import "../src/compare_colors.h"
#import "compare_fixture.h"

// Drives the real CompareWindowController over the shared fixture. Failures
// print `file:line: Assertion failed: …` and make the process exit non-zero.
// Set COMPARE_SNAPSHOT_DIR to also write light and dark PNG snapshots.

@interface CompareWindowController (Testing)
- (NSOutlineView*)outlineViewForLeftSide:(BOOL)left;
- (void)takeFilterFrom:(NSSegmentedControl*)sender;
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
	CHECK([summary.stringValue isEqualToString:@"4 modified · 2 only on the left · 2 only on the right · 1 changed type"]);
	CHECK([controller.window.title isEqualToString:@"main ⇄ feature"]);

	NSArray* names = TopLevelNames(left);
	CHECK([names isEqual:(@[ @"deep", @"kind", @"newdir", @"gone.txt", @"grown.txt", @"left-only.txt", @"link", @"same-size.txt" ])]);
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
		[NSUserDefaults.standardUserDefaults setVolatileDomain:@{ @"compareFilter": @0, kUserDefaultsFoldersOnTopKey: @YES } forName:NSArgumentDomain];
		CompareWindowController.gitExecutable = @COMPARE_TEST_GIT;

		compare_fixture_t fixture = compare_fixture::create(@COMPARE_TEST_GIT);
		CHECK(fixture.error == nil);
		if(!fixture.error)
		{
			TestChangedFilter(fixture);
			TestFocus(fixture);
		}

		if(Failures)
			fprintf(stderr, "compare-window: %d assertion(s) failed\n", Failures);
		else
			fprintf(stdout, "compare-window: all checks passed\n");
		return Failures ? 1 : 0;
	}
}
