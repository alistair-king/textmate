#import "CompareWindowController.h"
#import "compare_tree.h"
#import "compare_colors.h"
#import "CompareDiffView.h"
#import "compare_transfer.h"
#import "compare_watch.h"
#import "CompareSettings.h"
#import "compare_url.h"
#include <stdlib.h>
#include <utility>
#import <FileBrowser/FileItem.h>
#import <FileBrowser/FileBrowserOutlineView.h>
#import <FileBrowser/FileItemTableCellView.h>
#import <OakTabBarView/OakTabBarView.h>
#import <Preferences/Keys.h>

typedef NS_ENUM(NSInteger, CompareFilter) {
	CompareFilterChanged = 0,
	CompareFilterLeftOnly,
	CompareFilterRightOnly,
	CompareFilterAll,
};

// Posted by a window whose display mode or ignored-files choice changed.
static NSString* const CompareDisplayDidChangeNotification = @"CompareDisplayDidChangeNotification";

static NSString* const kCompareFilterDefaultsKey         = @"compareFilter";
static NSString* const kCompareIncludeIgnoredDefaultsKey = @"compareIncludeIgnored";
static NSString* const kCompareExpandedDefaultsKey       = @"compareExpandedFolders"; // { pair: { paths, date } }
static NSUInteger const kCompareRememberedPairs          = 30;

// The real path (with /private for /var, /tmp, /etc), as FSEvents reports it.
static NSString* RealPath (NSString* path)
{
	char buffer[PATH_MAX];
	return realpath(path.fileSystemRepresentation, buffer) ? @(buffer) : path;
}

static CompareStatus MaskForFilter (CompareFilter filter)
{
	switch(filter)
	{
		case CompareFilterLeftOnly:  return CompareStatusLeftOnly;
		case CompareFilterRightOnly: return CompareStatusRightOnly;
		case CompareFilterAll:       return CompareStatusDifferent|CompareStatusIdentical;
		default:                     return CompareStatusDifferent;
	}
}

// ===========
// = Row view =
// ===========

@interface CompareRowView : NSTableRowView
@property (nonatomic) NSColor* tintColor;
@property (nonatomic) BOOL marker; // a dot at the trailing end: something inside differs
@end

@implementation CompareRowView
- (BOOL)clipsToBounds { return YES; }

- (void)setTintColor:(NSColor*)color
{
	if(_tintColor == color)
		return;
	_tintColor = color;
	self.needsDisplay = YES;
}

- (void)setMarker:(BOOL)flag
{
	if(_marker == flag)
		return;
	_marker = flag;
	self.needsDisplay = YES;
}

- (void)drawBackgroundInRect:(NSRect)dirtyRect
{
	[super drawBackgroundInRect:dirtyRect];
	compare::fill_row(_tintColor, NSIntersectionRect(self.bounds, dirtyRect));
}

// Drawn after the selection so it stays visible on a selected row.
- (void)drawRect:(NSRect)dirtyRect
{
	[super drawRect:dirtyRect];
	if(_marker)
	{
		CGFloat const size = 7;
		NSRect dot = NSMakeRect(NSMaxX(self.bounds) - 14 - size, round(NSMidY(self.bounds) - size / 2), size, size);
		[(self.isSelected && self.isEmphasized ? NSColor.alternateSelectedControlTextColor : compare::marker_color()) set];
		[[NSBezierPath bezierPathWithOvalInRect:dot] fill];
	}
}
@end

// =============================================
// = Copy arrows between the trees, one per row =
// =============================================

// Sits between the two trees. Rows line up across the trees, so the left
// tree's row rectangles position the arrows: → copies the row's entry to the
// right, ← to the left, shown only where there is something to copy.
@interface CompareTreeStrip : NSView
@property (nonatomic, weak) NSOutlineView* outlineView;
@property (nonatomic, copy) BOOL (^canCopy)(CompareNode* node, BOOL toRight);
@property (nonatomic, copy) void (^copyHandler)(CompareNode* node, BOOL toRight);
- (BOOL)hasArrowForRow:(NSInteger)row toRight:(BOOL)toRight;
- (void)clickRow:(NSInteger)row toRight:(BOOL)toRight;
- (BOOL)clickAtPoint:(NSPoint)point;
- (NSRect)arrowRectForRow:(NSInteger)row toRight:(BOOL)toRight;
@end

static CGFloat const kTreeStripWidth = 34;

@implementation CompareTreeStrip
- (BOOL)isFlipped { return YES; }

// Views do not clip to their bounds by default (macOS 14): without this the
// backing layer grows to whatever is drawn and covers the rest of the window.
- (BOOL)clipsToBounds { return YES; }

- (NSSize)intrinsicContentSize
{
	return NSMakeSize(kTreeStripWidth, NSViewNoIntrinsicMetric);
}

// The band where the tree's rows are visible, in this view's coordinates:
// the tree is beside this view, so only its vertical extent counts.
- (NSRect)rowsArea
{
	NSClipView* clip = _outlineView.enclosingScrollView.contentView;
	if(!clip)
		return NSZeroRect;
	NSRect visible = [self convertRect:clip.bounds fromView:clip];
	return NSIntersectionRect(self.bounds, NSMakeRect(0, NSMinY(visible), NSWidth(self.bounds), NSHeight(visible)));
}

// The tree rows beside `rect` (in this view's coordinates).
- (NSRange)rowsBeside:(NSRect)rect
{
	NSRect inTree = [_outlineView convertRect:rect fromView:self];
	return [_outlineView rowsInRect:NSMakeRect(0, NSMinY(inTree), NSWidth(_outlineView.bounds), NSHeight(inTree))];
}

- (NSRect)arrowRectForRow:(NSInteger)row toRight:(BOOL)toRight
{
	NSRect rowRect = [self convertRect:[_outlineView rectOfRow:row] fromView:_outlineView];
	return NSMakeRect(toRight ? 1 : kTreeStripWidth / 2, NSMinY(rowRect), kTreeStripWidth / 2 - 1, NSHeight(rowRect));
}

- (BOOL)hasArrowForRow:(NSInteger)row toRight:(BOOL)toRight
{
	CompareNode* node = row >= 0 && row < _outlineView.numberOfRows ? [_outlineView itemAtRow:row] : nil;
	return node && _canCopy && _canCopy(node, toRight);
}

- (void)clickRow:(NSInteger)row toRight:(BOOL)toRight
{
	if([self hasArrowForRow:row toRight:toRight] && _copyHandler)
		_copyHandler([_outlineView itemAtRow:row], toRight);
}

- (void)drawRect:(NSRect)dirtyRect
{
	dirtyRect = NSIntersectionRect(dirtyRect, self.bounds);
	[NSColor.controlBackgroundColor set];
	NSRectFill(dirtyRect);
	[NSColor.separatorColor set];
	NSRectFill(NSMakeRect(0, NSMinY(dirtyRect), 1, NSHeight(dirtyRect)));
	NSRectFill(NSMakeRect(NSMaxX(self.bounds) - 1, NSMinY(dirtyRect), 1, NSHeight(dirtyRect)));

	NSRect area = self.rowsArea;
	if(NSIsEmptyRect(area))
		return;
	[NSGraphicsContext saveGraphicsState];
	NSRectClip(area);
	NSRange rows = [self rowsBeside:area];
	for(NSInteger row = rows.location; row < (NSInteger)NSMaxRange(rows); ++row)
	{
		for(BOOL toRight : { YES, NO })
		{
			if(![self hasArrowForRow:row toRight:toRight])
				continue;
			NSRect cell = [self arrowRectForRow:row toRight:toRight];
			NSImageSymbolConfiguration* configuration = [[NSImageSymbolConfiguration configurationWithPointSize:MIN(NSHeight(cell) * 0.5, 12) weight:NSFontWeightSemibold] configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.secondaryLabelColor]];
			NSImage* image = [[NSImage imageWithSystemSymbolName:toRight ? @"arrow.right" : @"arrow.left" accessibilityDescription:toRight ? @"Copy to the right" : @"Copy to the left"] imageWithSymbolConfiguration:configuration];
			NSSize size = image.size;
			[image drawInRect:NSMakeRect(round(NSMidX(cell) - size.width / 2), round(NSMidY(cell) - size.height / 2), size.width, size.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
		}
	}
	[NSGraphicsContext restoreGraphicsState];
}

- (void)mouseDown:(NSEvent*)event
{
	[self clickAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}

// Returns YES when the point hit an arrow.
- (BOOL)clickAtPoint:(NSPoint)point
{
	if(!NSPointInRect(point, self.rowsArea))
		return NO;
	NSRange rows = [self rowsBeside:NSMakeRect(0, point.y, 1, 1)];
	if(!rows.length)
		return NO;
	BOOL toRight = point.x < kTreeStripWidth / 2;
	if(![self hasArrowForRow:rows.location toRight:toRight])
		return NO;
	[self clickRow:rows.location toRight:toRight];
	return YES;
}
@end

// ==============================
// = One side of the comparison =
// ==============================

@interface CompareSide : NSObject
@property (nonatomic) BOOL left;
@property (nonatomic) NSString* root;
@property (nonatomic) NSView* view;
@property (nonatomic) NSTextField* nameLabel;
@property (nonatomic) NSTextField* branchLabel;
@property (nonatomic) NSTextField* locationLabel;
@property (nonatomic) NSScrollView* scrollView;
@property (nonatomic) FileBrowserOutlineView* outlineView;
@property (nonatomic) NSMapTable<CompareNode*, FileItem*>* items;
@end

@implementation CompareSide
@end

static NSTextField* Label (NSString* text, NSFont* font, NSColor* color)
{
	NSTextField* label = [NSTextField labelWithString:text ?: @""];
	label.font = font;
	label.textColor = color;
	label.lineBreakMode = NSLineBreakByTruncatingMiddle;
	[label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	return label;
}

// ========
// = Tabs =
// ========

// The first tab compares the trees; the others each compare one file.
// Covers the empty trees while the first comparison runs: a spinner, what
// is happening, and how far it has got.
@interface CompareLoadingView : NSView
@end

@implementation CompareLoadingView
- (void)drawRect:(NSRect)dirtyRect
{
	[NSColor.controlBackgroundColor setFill];
	NSRectFill(dirtyRect);
}

- (NSView*)hitTest:(NSPoint)point
{
	return self.hidden ? nil : [super hitTest:point] ? self : nil; // the trees below are empty
}
@end

@interface CompareTab : NSObject
@property (nonatomic) NSUUID* identifier;
@property (nonatomic) NSView* view;
@property (nonatomic) NSString* relativePath;       // nil for the tree tab
@property (nonatomic) CompareDiffView* diffView;    // nil for the tree tab
@property (nonatomic) CompareNode* node;            // the entry shown, from the latest comparison
@end

@implementation CompareTab
@end

@interface CompareWindowController () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, OakTabBarViewDataSource, OakTabBarViewDelegate>
@end

@implementation CompareWindowController
{
	CompareSide* _sides[2];
	CompareNode* _root;
	CompareFilter _filter;
	NSMapTable<CompareNode*, NSArray<CompareNode*>*>* _visibleChildren;

	NSTextField* _summaryLabel;
	NSProgressIndicator* _spinner;

	NSProgress* _loading;
	NSUInteger _generation;
	BOOL _synchronizing;
	BOOL _revealFocusAfterLoad;

	NSSearchField* _searchField;
	NSString* _search;                       // nil or empty: no name filter
	NSArray<NSString*>* _expandedBeforeSearch;
	BOOL _includeIgnored;

	compare::folder_watch_t _watch;
	BOOL _comparing;
	BOOL _refreshPending;

	CompareTreeStrip* _treeStrip;
	OakTabBarView* _tabBar;
	NSView* _tabContent;
	NSMutableArray<CompareTab*>* _tabs;
	NSUInteger _selectedTab;
	BOOL _files; // two files: one file tab, no trees
	BOOL _reloadFiles; // the next comparison of two files reloads their text
	NSString* _branches[2]; // shown in each file tab's headers
	CompareLoadingView* _loadingView;
	NSProgressIndicator* _loadingSpinner;
	NSTextField* _loadingTitle;
	NSTextField* _loadingDetail;
	NSTimer* _progressTimer;
	std::shared_ptr<compare_progress_t> _progress; // of the running (or last) comparison
	NSArray<NSString*>* _keptExpanded; // after swapping sides: restored on the next comparison
	NSString* _keptSelection;
}

static NSString* GitExecutable;
static BOOL ConfirmsChanges = YES;

+ (NSString*)gitExecutable              { return GitExecutable; }
+ (void)setGitExecutable:(NSString*)git { GitExecutable = [git copy]; }
+ (BOOL)confirmsChanges                 { return ConfirmsChanges; }
+ (void)setConfirmsChanges:(BOOL)flag   { ConfirmsChanges = flag; }

static void (^EditHandler)(NSArray<NSURL*>*) = nil;
+ (void (^)(NSArray<NSURL*>*))editHandler       { return EditHandler; }
+ (void)setEditHandler:(void (^)(NSArray<NSURL*>*))handler { EditHandler = [handler copy]; }

// The TextMate to edit in: the app this Compare is embedded in
// (TextMate.app/Contents/Helpers/Compare.app), else an installed one,
// preferring the development build.
static NSURL* TextMateApplicationURL ()
{
	NSURL* helpers = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent;
	if([helpers.lastPathComponent isEqualToString:@"Helpers"])
	{
		NSURL* app = helpers.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
		if([app.pathExtension isEqualToString:@"app"])
			return app;
	}
	for(NSString* identifier in @[ @"com.macromates.TextMate-dev", @"com.macromates.TextMate" ])
	{
		if(NSURL* app = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:identifier])
			return app;
	}
	return nil;
}

- (instancetype)initWithLeftPath:(NSString*)left rightPath:(NSString*)right focus:(NSString*)focus
{
	NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 680) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
	if(self = [super initWithWindow:window])
	{
		_leftPath  = [left copy];
		_rightPath = [right copy];
		_focus     = [focus copy];
		_filter    = (CompareFilter)MIN(MAX([NSUserDefaults.standardUserDefaults integerForKey:kCompareFilterDefaultsKey], 0), CompareFilterAll);
		_visibleChildren = [NSMapTable strongToStrongObjectsMapTable];
		_revealFocusAfterLoad = YES;
		_includeIgnored = [NSUserDefaults.standardUserDefaults boolForKey:kCompareIncludeIgnoredDefaultsKey];
		BOOL leftIsFolder = NO;
		_files = [NSFileManager.defaultManager fileExistsAtPath:left isDirectory:&leftIsFolder] && !leftIsFolder;

		[self updateTitle];
		window.minSize            = NSMakeSize(560, 420);
		window.releasedWhenClosed = NO;
		window.delegate           = self;
		window.tabbingMode        = NSWindowTabbingModeDisallowed;

		_sides[0] = [self makeSideForRoot:left left:YES];
		_sides[1] = [self makeSideForRoot:right left:NO];

		// Two equal trees with the copy arrows between them.
		_treeStrip = [[CompareTreeStrip alloc] initWithFrame:NSZeroRect];
		_treeStrip.outlineView = _sides[0].outlineView;
		// Arrows only on rows that are themselves differences: a folder on both
		// sides (default background, amber dot) gets none, though the Edit and
		// context menus still copy what differs inside it.
		_treeStrip.canCopy = ^BOOL(CompareNode* node, BOOL toRight){
			return !compare::contains_differences(node) && CompareCountCopies(node, toRight) > 0;
		};
		__weak CompareWindowController* weakController = self;
		_treeStrip.copyHandler = ^(CompareNode* node, BOOL toRight){
			[weakController copyEntriesAtRelativePaths:@[ node.relativePath ] toRight:toRight];
		};
		NSView* split = [NSView new];
		for(NSView* view in @[ _sides[0].view, _treeStrip, _sides[1].view ])
		{
			view.translatesAutoresizingMaskIntoConstraints = NO;
			[split addSubview:view];
			[view.topAnchor constraintEqualToAnchor:split.topAnchor].active = YES;
			[view.bottomAnchor constraintEqualToAnchor:split.bottomAnchor].active = YES;
		}
		[_treeStrip setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
		[NSLayoutConstraint activateConstraints:@[
			[_sides[0].view.leadingAnchor constraintEqualToAnchor:split.leadingAnchor],
			[_treeStrip.leadingAnchor constraintEqualToAnchor:_sides[0].view.trailingAnchor],
			[_sides[1].view.leadingAnchor constraintEqualToAnchor:_treeStrip.trailingAnchor],
			[_sides[1].view.trailingAnchor constraintEqualToAnchor:split.trailingAnchor],
			[_sides[0].view.widthAnchor constraintEqualToAnchor:_sides[1].view.widthAnchor],
		]];

		// The tree tab: filter bar above the two trees.
		CompareSeparatorView* divider = [[CompareSeparatorView alloc] initVertical:NO];
		NSView* bar = [self makeBar];
		[split setContentHuggingPriority:NSLayoutPriorityDefaultLow - 10 forOrientation:NSLayoutConstraintOrientationVertical];
		NSView* treesView = [NSView new];
		for(NSView* view in @[ bar, divider, split ])
		{
			view.translatesAutoresizingMaskIntoConstraints = NO;
			[treesView addSubview:view];
			[view.leadingAnchor constraintEqualToAnchor:treesView.leadingAnchor].active = YES;
			[view.trailingAnchor constraintEqualToAnchor:treesView.trailingAnchor].active = YES;
		}
		[bar.topAnchor constraintEqualToAnchor:treesView.topAnchor].active = YES;
		[divider.topAnchor constraintEqualToAnchor:bar.bottomAnchor].active = YES;
		[split.topAnchor constraintEqualToAnchor:divider.bottomAnchor].active = YES;
		[split.bottomAnchor constraintEqualToAnchor:treesView.bottomAnchor].active = YES;

		_loadingView = [self makeLoadingView];
		_loadingView.translatesAutoresizingMaskIntoConstraints = NO;
		[treesView addSubview:_loadingView positioned:NSWindowAbove relativeTo:split];
		[NSLayoutConstraint activateConstraints:@[
			[_loadingView.topAnchor constraintEqualToAnchor:split.topAnchor],
			[_loadingView.bottomAnchor constraintEqualToAnchor:split.bottomAnchor],
			[_loadingView.leadingAnchor constraintEqualToAnchor:split.leadingAnchor],
			[_loadingView.trailingAnchor constraintEqualToAnchor:split.trailingAnchor],
		]];

		// Two files have no trees: their comparison is the only tab.
		CompareTab* firstTab = [CompareTab new];
		firstTab.identifier = [NSUUID UUID];
		firstTab.view       = treesView;
		if(_files)
		{
			firstTab = [self makeTabForNode:nil]; // compared on a worker queue, like folders
			[firstTab.diffView showMessage:@"Comparing…"];
			window.subtitle = left.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath;
		}
		_tabs = [NSMutableArray arrayWithObject:firstTab];

		// TextMate's tab bar above the selected tab's view.
		_tabBar = [[OakTabBarView alloc] initWithFrame:NSZeroRect];
		_tabBar.dataSource = self;
		_tabBar.delegate   = self;
		_tabBar.showsCreateNewTabButton = NO;
		_tabContent = [NSView new];

		NSView* content = [NSView new];
		for(NSView* view in _files ? @[ _tabContent ] : @[ _tabBar, _tabContent ])
		{
			view.translatesAutoresizingMaskIntoConstraints = NO;
			[content addSubview:view];
			[view.leadingAnchor constraintEqualToAnchor:content.leadingAnchor].active = YES;
			[view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor].active = YES;
		}
		if(_files)
		{
			[_tabContent.topAnchor constraintEqualToAnchor:content.topAnchor].active = YES;
		}
		else
		{
			[_tabBar.topAnchor constraintEqualToAnchor:content.topAnchor].active = YES;
			[_tabContent.topAnchor constraintEqualToAnchor:_tabBar.bottomAnchor].active = YES;
		}
		[_tabContent.bottomAnchor constraintEqualToAnchor:content.bottomAnchor].active = YES;
		window.contentView = content;

		[_tabBar reloadData];
		[self selectTabAtIndex:0];

		[window center];
		[window setFrameAutosaveName:@"CompareWindow"];
		[content layoutSubtreeIfNeeded];

		for(CompareSide* side : _sides)
		{
			side.scrollView.contentView.postsBoundsChangedNotifications = YES;
			[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clipViewBoundsDidChange:) name:NSViewBoundsDidChangeNotification object:side.scrollView.contentView];
		}

		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(displayDidChange:) name:CompareDisplayDidChangeNotification object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsDidChange:) name:CompareSettingsDidChangeNotification object:nil];
		[self refresh:self];
		[self startWatching];
	}
	return self;
}

- (BOOL)isFileComparison
{
	return _files;
}

// The folder or file names; a folder comparison shows the branches once known.
- (void)updateTitle
{
	NSString* left = _leftPath.lastPathComponent, *right = _rightPath.lastPathComponent;
	self.window.title = [NSString stringWithFormat:@"%@ ⇄ %@", left, right];
	if(_files && [left isEqualToString:right])
		self.window.title = [NSString stringWithFormat:@"%@ — %@ ⇄ %@", left, _leftPath.stringByDeletingLastPathComponent.lastPathComponent, _rightPath.stringByDeletingLastPathComponent.lastPathComponent];
	if(_files)
		self.window.subtitle = _leftPath.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath;
}

// View → Swap Left and Right: the same comparison, mirrored. Open file tabs,
// expanded folders, the selection and Undo stay; both sides are compared
// again, as every entry's left and right change places.
- (IBAction)swapSides:(id)sender
{
	[self saveState]; // under the old order's key
	NSString* left = _rightPath;
	_rightPath = _leftPath;
	_leftPath  = left;
	std::swap(_branches[0], _branches[1]);
	[self updateTitle];

	if(_root)
	{
		_keptExpanded  = [self expandedRelativePaths];
		_keptSelection = [self selectedRelativePath];
	}
	_root = nil; // its entries say left and right the other way round
	[self reloadOutlines];
	for(CompareSide* side : _sides)
	{
		side.root = side.left ? _leftPath : _rightPath;
		side.nameLabel.stringValue     = side.root.lastPathComponent;
		side.branchLabel.stringValue   = @"";
		side.locationLabel.stringValue = side.root.stringByAbbreviatingWithTildeInPath;
		side.locationLabel.toolTip     = side.root;
	}
	for(CompareTab* tab in _tabs)
	{
		if(!tab.diffView)
			continue;
		tab.node = nil; // nothing to copy until compared again
		[tab.diffView setBranch:_branches[0] onLeft:YES];
		[tab.diffView setBranch:_branches[1] onLeft:NO];
		[tab.diffView showMessage:@"Comparing…"];
	}
	_reloadFiles = _files;
	[self refresh:self];
}

- (void)dealloc
{
	[_loading cancel];
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)windowWillClose:(NSNotification*)notification
{
	[self saveState];
	[_loading cancel];
	_watch.stop();
	[self hideLoading];
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(liveRefresh) object:nil];
}

// ==================
// = Remembered state =
// ==================

- (NSString*)pairKey
{
	return [NSString stringWithFormat:@"%@\n%@", _leftPath, _rightPath];
}

- (NSArray<NSString*>*)savedExpandedPaths
{
	NSDictionary* saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kCompareExpandedDefaultsKey][self.pairKey];
	NSArray* paths = saved[@"paths"];
	return [paths isKindOfClass:NSArray.class] ? paths : @[ ];
}

- (void)saveState
{
	if(!_root)
		return;
	NSArray<NSString*>* paths = _search.length ? _expandedBeforeSearch : [self expandedRelativePaths];
	NSMutableDictionary* all = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kCompareExpandedDefaultsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
	all[self.pairKey] = @{ @"paths": paths ?: @[ ], @"date": NSDate.date };
	while(all.count > kCompareRememberedPairs)
	{
		NSString* oldest = [all keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary* lhs, NSDictionary* rhs){
			return [lhs[@"date"] compare:rhs[@"date"]];
		}].firstObject;
		[all removeObjectForKey:oldest];
	}
	[NSUserDefaults.standardUserDefaults setObject:all forKey:kCompareExpandedDefaultsKey];
}

// ================
// = Live refresh =
// ================

- (void)startWatching
{
	__weak CompareWindowController* weakSelf = self;
	if(_files)
	{
		// FSEvents watches folders: the ones holding the two files.
		NSArray* folders = [[NSOrderedSet orderedSetWithArray:@[ _leftPath.stringByDeletingLastPathComponent, _rightPath.stringByDeletingLastPathComponent ]] array];
		_watch.start(folders, @[ ], 0.5, ^(NSArray<NSString*>* paths){
			[weakSelf filesDidChange:paths];
		});
		return;
	}
	NSMutableArray* excluded = [NSMutableArray array];
	for(NSString* root in @[ RealPath(_leftPath), RealPath(_rightPath) ])
		[excluded addObject:[root stringByAppendingPathComponent:@".git"]];
	_watch.start(@[ _leftPath, _rightPath ], excluded, 0.5, ^(NSArray<NSString*>* paths){
		[weakSelf filesDidChange:paths];
	});
}

// The path relative to whichever root contains it, or nil.
- (NSString*)relativePathForEventPath:(NSString*)path left:(BOOL*)left
{
	for(BOOL isLeft : { YES, NO })
	{
		NSString* root = isLeft ? _leftPath : _rightPath;
		for(NSString* base in @[ root, RealPath(root) ])
		{
			if([path isEqualToString:base])
			{
				*left = isLeft;
				return @"";
			}
			NSString* prefix = [base stringByAppendingString:@"/"];
			if([path hasPrefix:prefix])
			{
				*left = isLeft;
				return [path substringFromIndex:prefix.length].precomposedStringWithCanonicalMapping;
			}
		}
	}
	return nil;
}

// Compare again after changes to anything compared, or to files that are not
// ignored; build output and Git's own files do not count.
- (void)filesDidChange:(NSArray<NSString*>*)paths
{
	_fileEventCount += paths.count;
	if(_files)
	{
		// Only the two files count, not their neighbours.
		NSSet* watched = [NSSet setWithObjects:_leftPath, _rightPath, RealPath(_leftPath), RealPath(_rightPath), nil];
		for(NSString* path in paths)
		{
			if([watched containsObject:path])
				return [self scheduleLiveRefresh];
		}
		return;
	}
	if(!_root)
		return;
	compare_excludes_t const excludes(CompareSettings.excludedNames);
	NSMutableArray<NSString*>* unknown[2] = { [NSMutableArray array], [NSMutableArray array] };
	for(NSString* path in paths)
	{
		BOOL left = NO;
		NSString* relativePath = [self relativePathForEventPath:path left:&left];
		if(!relativePath.length)
			continue;
		NSArray* components = relativePath.pathComponents;
		if([components containsObject:@".git"] || ([relativePath.lastPathComponent hasPrefix:@"."] && [relativePath.lastPathComponent containsString:@".tm-compare-"]))
			continue;
		if(excludes.matches(relativePath))
			continue; // Settings → Ignore folders and files (node_modules churn)
		if(_includeIgnored || [_root nodeAtRelativePath:relativePath])
		{
			[self scheduleLiveRefresh];
			return;
		}
		[unknown[left ? 0 : 1] addObject:relativePath];
	}
	if(!unknown[0].count && !unknown[1].count)
		return;

	NSString* git = CompareWindowController.gitExecutable;
	if(!git)
	{
		[self scheduleLiveRefresh];
		return;
	}
	NSArray* roots = @[ _leftPath, _rightPath ];
	NSArray* candidates[2] = { [unknown[0] copy], [unknown[1] copy] };
	NSArray* leftCandidates = candidates[0];
	NSArray* rightCandidates = candidates[1];
	__weak CompareWindowController* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		BOOL relevant = NO;
		NSArray* lists[2] = { leftCandidates, rightCandidates };
		for(size_t i = 0; i < 2 && !relevant; ++i)
		{
			NSSet* ignored = CompareIgnoredPaths(roots[i], lists[i], git);
			for(NSString* candidate in lists[i])
				relevant |= ![ignored containsObject:candidate];
		}
		if(relevant)
		{
			dispatch_async(dispatch_get_main_queue(), ^{
				[weakSelf scheduleLiveRefresh];
			});
		}
	});
}

- (void)scheduleLiveRefresh
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(liveRefresh) object:nil];
	[self performSelector:@selector(liveRefresh) withObject:nil afterDelay:0.3];
}

- (void)liveRefresh
{
	if(_comparing)
		_refreshPending = YES; // runs when the current comparison finishes
	else
		[self refresh:self];
}

// =========================
// = Name search and ignored files =
// =========================

- (void)searchChanged:(NSSearchField*)sender
{
	NSString* search = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	if([search isEqualToString:_search ?: @""])
		return;
	if(!_search.length && search.length)
		_expandedBeforeSearch = [self expandedRelativePaths];
	BOOL clearing = _search.length && !search.length;
	_search = [search copy];
	[self reloadOutlines];
	if(_search.length)
		[_sides[0].outlineView expandItem:nil expandChildren:YES];
	else if(clearing)
	{
		// Outline views keep items expanded across reloads: collapse what the
		// search opened, then restore what was open before.
		[_sides[0].outlineView collapseItem:nil collapseChildren:YES];
		[self expandRelativePaths:_expandedBeforeSearch ?: @[ ]];
	}
}

- (BOOL)nameMatches:(CompareNode*)node
{
	return [node.name rangeOfString:_search options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location != NSNotFound;
}

// The node or a folder above it matches the search by name.
- (BOOL)nameMatchesWithin:(CompareNode*)node
{
	for(CompareNode* current = node; current && current != _root; current = current.parent)
	{
		if([self nameMatches:current])
			return YES;
	}
	return NO;
}

// Shown by the search: it matches, it is inside a match, or something below it matches.
- (BOOL)searchShows:(CompareNode*)node
{
	if(!_search.length || [self nameMatchesWithin:node])
		return YES;
	CompareStatus mask = MaskForFilter(_filter);
	for(CompareNode* child in node.children)
	{
		if((child.mask & mask) && [self searchShows:child])
			return YES;
	}
	return NO;
}

// Settings → Ignore folders and files changed: compare again.
- (void)settingsDidChange:(NSNotification*)notification
{
	[self refresh:self];
}

// Another window's View menu choice.
- (void)displayDidChange:(NSNotification*)notification
{
	if(notification.object == self)
		return;
	if(NSNumber* filter = notification.userInfo[@"filter"])
		[self applyFilter:(CompareFilter)filter.integerValue];
	if(NSNumber* includeIgnored = notification.userInfo[@"includeIgnored"])
		[self applyIncludeIgnored:includeIgnored.boolValue];
}

// View → Show Ignored Files.
- (IBAction)toggleIgnoredFilesFromMenu:(id)sender
{
	[self selectTabAtIndex:0];
	[self setIncludeIgnored:!_includeIgnored];
}

- (void)setIncludeIgnored:(BOOL)flag
{
	if(flag == _includeIgnored)
		return;
	[self applyIncludeIgnored:flag];
	[NSNotificationCenter.defaultCenter postNotificationName:CompareDisplayDidChangeNotification object:self userInfo:@{ @"includeIgnored": @(flag) }];
}

- (void)applyIncludeIgnored:(BOOL)flag
{
	if(flag == _includeIgnored)
		return;
	_includeIgnored = flag;
	[NSUserDefaults.standardUserDefaults setBool:_includeIgnored forKey:kCompareIncludeIgnoredDefaultsKey];
	[self refresh:self];
}

// ==========
// = Layout =
// ==========

- (CompareLoadingView*)makeLoadingView
{
	_loadingSpinner = [NSProgressIndicator new];
	_loadingSpinner.style = NSProgressIndicatorStyleSpinning;
	_loadingSpinner.controlSize = NSControlSizeRegular;
	_loadingSpinner.displayedWhenStopped = NO;

	_loadingTitle = [NSTextField labelWithString:@"Comparing folders…"];
	_loadingTitle.font = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
	_loadingTitle.textColor = NSColor.secondaryLabelColor;
	_loadingTitle.alignment = NSTextAlignmentCenter;

	_loadingDetail = [NSTextField wrappingLabelWithString:@""];
	_loadingDetail.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
	_loadingDetail.textColor = NSColor.tertiaryLabelColor;
	_loadingDetail.alignment = NSTextAlignmentCenter;
	_loadingDetail.preferredMaxLayoutWidth = 420;

	NSStackView* stack = [NSStackView stackViewWithViews:@[ _loadingSpinner, _loadingTitle, _loadingDetail ]];
	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.alignment   = NSLayoutAttributeCenterX;
	stack.spacing     = 8;
	[stack setCustomSpacing:14 afterView:_loadingSpinner];
	stack.translatesAutoresizingMaskIntoConstraints = NO;

	CompareLoadingView* view = [CompareLoadingView new];
	view.hidden = YES;
	[view addSubview:stack];
	[NSLayoutConstraint activateConstraints:@[
		[stack.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
		[stack.centerYAnchor constraintEqualToAnchor:view.centerYAnchor constant:-20],
		[stack.widthAnchor constraintLessThanOrEqualToAnchor:view.widthAnchor constant:-40],
	]];
	return view;
}

// Shown while there is no tree yet (a new window, after Swap, after a
// failure); a refresh of a tree that is shown keeps it, with the bar's spinner.
- (void)showLoading
{
	_loadingTitle.stringValue = @"Comparing folders…";
	_loadingView.hidden = NO;
	[_loadingSpinner startAnimation:self];
	[self updateLoadingProgress];
	if(!_progressTimer)
	{
		__weak CompareWindowController* weakSelf = self;
		_progressTimer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer* timer){
			[weakSelf updateLoadingProgress];
		}];
		[NSRunLoop.currentRunLoop addTimer:_progressTimer forMode:NSRunLoopCommonModes];
	}
}

- (void)hideLoading
{
	[_progressTimer invalidate];
	_progressTimer = nil;
	[_loadingSpinner stopAnimation:self];
	_loadingView.hidden = YES;
}

- (void)showLoadingFailure:(NSString*)reason
{
	[self hideLoading];
	_loadingView.hidden = NO;
	_loadingTitle.stringValue  = @"The folders could not be compared.";
	_loadingDetail.stringValue = reason ?: @"Click ↻ or choose File → Compare Again to try again.";
}

- (void)updateLoadingProgress
{
	auto progress = _progress;
	if(!progress || !progress->listed)
	{
		_loadingDetail.stringValue = @"Listing the files in both folders…";
		return;
	}
	auto number = ^NSString*(long value){
		return [NSNumberFormatter localizedStringFromNumber:@(value) numberStyle:NSNumberFormatterDecimalStyle];
	};
	long files = progress->files, compared = MIN(progress->compared.load(), files);
	_loadingDetail.stringValue = [NSString stringWithFormat:@"%@ of %@ %@ compared", number(compared), number(files), files == 1 ? @"file" : @"files"];
}

- (BOOL)isShowingLoading
{
	return !_loadingView.hidden;
}

- (NSView*)makeBar
{
	_summaryLabel = Label(@"", [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.secondaryLabelColor);
	_summaryLabel.alignment = NSTextAlignmentRight;
	_summaryLabel.lineBreakMode = NSLineBreakByTruncatingTail; // keep the first counts readable

	_spinner = [NSProgressIndicator new];
	_spinner.style = NSProgressIndicatorStyleSpinning;
	_spinner.controlSize = NSControlSizeSmall;
	_spinner.displayedWhenStopped = NO;

	_searchField = [NSSearchField new];
	_searchField.placeholderString = @"Filter by name";
	_searchField.controlSize = NSControlSizeSmall;
	_searchField.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	_searchField.sendsSearchStringImmediately = NO;
	_searchField.target = self;
	_searchField.action = @selector(searchChanged:);
	[_searchField.widthAnchor constraintEqualToConstant:180].active = YES;

	NSButton* refresh = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"Refresh"] target:self action:@selector(refresh:)];
	refresh.bezelStyle = NSBezelStyleAccessoryBarAction;
	refresh.toolTip = @"Compare again (⌘R)";

	// The summary label takes the spare width.
	[_summaryLabel setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

	// Display modes and ignored files are in the View menu.
	NSStackView* bar = [NSStackView stackViewWithViews:@[ _summaryLabel, _searchField, _spinner, refresh ]];
	[bar setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
	bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	bar.spacing     = 8;
	bar.edgeInsets  = NSEdgeInsetsMake(6, 10, 6, 10);
	[bar.heightAnchor constraintEqualToConstant:32].active = YES;
	return bar;
}

- (CompareSide*)makeSideForRoot:(NSString*)root left:(BOOL)left
{
	CompareSide* side = [CompareSide new];
	side.left  = left;
	side.root  = root;
	side.items = [NSMapTable strongToStrongObjectsMapTable];

	side.nameLabel   = Label(root.lastPathComponent, [NSFont boldSystemFontOfSize:NSFont.systemFontSize], NSColor.labelColor);
	side.branchLabel = Label(@"", [NSFont systemFontOfSize:NSFont.systemFontSize], NSColor.secondaryLabelColor);
	[side.nameLabel setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
	[side.branchLabel setContentHuggingPriority:NSLayoutPriorityDefaultHigh + 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
	[side.branchLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSStackView* title = [NSStackView stackViewWithViews:@[ side.nameLabel, side.branchLabel ]];
	title.spacing = 6;
	[title setHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];

	NSTextField* location = Label(root.stringByAbbreviatingWithTildeInPath, [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.secondaryLabelColor);
	location.toolTip = root;
	side.locationLabel = location;

	NSStackView* header = [NSStackView stackViewWithViews:@[ title, location ]];
	header.orientation = NSUserInterfaceLayoutOrientationVertical;
	header.alignment   = NSLayoutAttributeLeading;
	header.spacing     = 2;
	header.edgeInsets  = NSEdgeInsetsMake(8, 10, 8, 10);

	// Configured like FileBrowserView’s outline view.
	FileBrowserOutlineView* outlineView = [[FileBrowserOutlineView alloc] initWithFrame:NSZeroRect];
	outlineView.accessibilityLabel       = left ? @"Left files" : @"Right files";
	outlineView.allowsMultipleSelection  = YES;
	outlineView.autoresizesOutlineColumn = NO;
	outlineView.focusRingType            = NSFocusRingTypeNone;
	outlineView.headerView               = nil;
	outlineView.style                    = NSTableViewStylePlain;
	outlineView.floatsGroupRows          = NO;
	outlineView.backgroundColor          = NSColor.controlBackgroundColor;
	NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"name"];
	[outlineView addTableColumn:column];
	outlineView.outlineTableColumn = column;
	[outlineView sizeLastColumnToFit];
	outlineView.dataSource = self;
	outlineView.delegate   = self;
	outlineView.target       = self;
	outlineView.doubleAction = @selector(openSelectedFiles:); // also ⌘↓ and ⌘O
	outlineView.menu       = [NSMenu new];
	outlineView.menu.delegate = self;
	side.outlineView = outlineView;

	NSScrollView* scrollView = [NSScrollView new];
	scrollView.borderType            = NSNoBorder;
	scrollView.documentView          = outlineView;
	scrollView.hasHorizontalScroller = NO;
	scrollView.hasVerticalScroller   = YES;
	scrollView.autohidesScrollers    = YES;
	scrollView.drawsBackground       = YES;
	side.scrollView = scrollView;

	CompareSeparatorView* divider = [[CompareSeparatorView alloc] initVertical:NO];

	NSStackView* pane = [NSStackView stackViewWithViews:@[ header, divider, scrollView ]];
	pane.orientation = NSUserInterfaceLayoutOrientationVertical;
	pane.alignment   = NSLayoutAttributeWidth;
	pane.spacing     = 0;
	// The header spans the pane, its text at the leading edge.
	[header.widthAnchor constraintEqualToAnchor:pane.widthAnchor].active = YES;
	[scrollView setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1 forOrientation:NSLayoutConstraintOrientationVertical];
	side.view = pane;
	return side;
}

- (CompareSide*)sideForOutlineView:(NSOutlineView*)outlineView
{
	return outlineView == _sides[0].outlineView ? _sides[0] : _sides[1];
}

// Used by tests/window_tests.mm.
- (NSOutlineView*)outlineViewForLeftSide:(BOOL)left
{
	return _sides[left ? 0 : 1].outlineView;
}

- (CompareSide*)otherSide:(CompareSide*)side
{
	return side == _sides[0] ? _sides[1] : _sides[0];
}

// ===========
// = Loading =
// ===========

- (IBAction)refresh:(id)sender
{
	[_loading cancel];
	NSProgress* loading = [NSProgress discreteProgressWithTotalUnitCount:1];
	_loading = loading;
	NSUInteger generation = ++_generation;

	[_spinner startAnimation:self];
	_summaryLabel.stringValue = @"Comparing…";
	_comparing = YES;
	_refreshPending = NO;
	BOOL includeIgnored = _includeIgnored;
	compare_excludes_t const excludes(CompareSettings.excludedNames);

	NSString* left  = _leftPath;
	NSString* right = _rightPath;
	if(_files)
	{
		NSString* git = CompareWindowController.gitExecutable;
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			CompareNode* pair = CompareFilePair(left, right);
			NSString* leftBranch  = CompareBranchLabel(left.stringByDeletingLastPathComponent, git);
			NSString* rightBranch = CompareBranchLabel(right.stringByDeletingLastPathComponent, git);
			dispatch_async(dispatch_get_main_queue(), ^{
				if(generation != _generation || loading.isCancelled)
					return;
				[_spinner stopAnimation:self];
				_comparing = NO;
				++_comparisonCount;
				_branches[0] = leftBranch;
				_branches[1] = rightBranch;
				[_tabs.firstObject.diffView setBranch:leftBranch onLeft:YES];
				[_tabs.firstObject.diffView setBranch:rightBranch onLeft:NO];
				[self showFilePair:pair reload:_reloadFiles];
				_reloadFiles = NO;
				if(_refreshPending)
					[self refresh:self];
			});
		});
		return;
	}
	NSString* git   = CompareWindowController.gitExecutable;
	BOOL foldersFirst = [NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsFoldersOnTopKey];
	auto progress = std::make_shared<compare_progress_t>();
	_progress = progress;
	if(!_root)
		[self showLoading];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		__block NSString* reason = nil;
		compare_options_t options;
		options.progress        = progress;
		options.failed          = ^(NSString* why){ reason = why; };
		options.git           = git;
		options.folders_first   = foldersFirst;
		options.include_ignored = includeIgnored;
		options.excludes        = excludes;
		options.cancelled       = ^BOOL{ return loading.isCancelled; };
		CompareNode* root     = CompareBuildTree(left, right, options);
		NSString* leftBranch  = root ? CompareBranchLabel(left, git) : nil;
		NSString* rightBranch = root ? CompareBranchLabel(right, git) : nil;
		dispatch_async(dispatch_get_main_queue(), ^{
			if(generation != _generation || loading.isCancelled)
				return;
			[_spinner stopAnimation:self];
			_comparing = NO;
			++_comparisonCount;
			if(!root)
			{
				_summaryLabel.stringValue = @"Comparison failed.";
				if(!_root)
					[self showLoadingFailure:reason];
			}
			else
			{
				[self hideLoading];
				[self showTree:root leftBranch:leftBranch rightBranch:rightBranch];
			}
			if(_refreshPending)
				[self refresh:self];
		});
	});
}

- (void)showTree:(CompareNode*)root leftBranch:(NSString*)leftBranch rightBranch:(NSString*)rightBranch
{
	BOOL first = !_root && !_keptExpanded;
	NSArray<NSString*>* expanded = _keptExpanded ?: (first ? self.savedExpandedPaths : [self expandedRelativePaths]);
	NSString* selected = _keptExpanded ? _keptSelection : [self selectedRelativePath];
	_keptExpanded  = nil;
	_keptSelection = nil;

	_root = root;
	[self reloadOutlines];
	[self expandRelativePaths:expanded];
	if(first)
		[self expandFoldersWithDifferences:_root];
	if(_revealFocusAfterLoad)
	{
		_revealFocusAfterLoad = NO;
		[self revealRelativePath:_focus select:NO];
	}
	else if(selected)
	{
		[self revealRelativePath:selected select:YES];
	}

	for(CompareSide* side : _sides)
	{
		NSString* branch = side.left ? leftBranch : rightBranch;
		side.branchLabel.stringValue = [branch isEqualToString:side.nameLabel.stringValue] ? @"" : branch ?: @"";
	}
	_branches[0] = leftBranch;
	_branches[1] = rightBranch;
	[self updateFileTabs]; // entries are new nodes after every comparison
	if(leftBranch && rightBranch)
		self.window.title = [NSString stringWithFormat:@"%@ ⇄ %@", leftBranch, rightBranch];
	self.window.subtitle = _leftPath.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath;
	[self updateSummary];
}

// Shows the files again, keeping the current change; unchanged files (as
// after a live refresh for something else) only take the new entry.
- (void)showFilePair:(CompareNode*)pair reload:(BOOL)reload
{
	CompareTab* tab = _tabs.firstObject;
	CompareNode* previous = tab.node;
	tab.node = pair;
	if(!reload && previous.leftStamp == pair.leftStamp && previous.rightStamp == pair.rightStamp && tab.diffView.node)
			[tab.diffView updateNode:pair];
	else	[tab.diffView showNode:pair keepingChange:YES];
}

- (void)updateSummary
{
	NSDictionary<NSNumber*, NSNumber*>* counts = CompareLeafCounts(_root);
	NSMutableArray* parts = [NSMutableArray array];
	auto add = ^(CompareStatus status, NSString* singular, NSString* plural){
		NSUInteger count = counts[@(status)].unsignedIntegerValue;
		if(count)
			[parts addObject:[NSString stringWithFormat:@"%lu %@", count, count == 1 ? singular : plural]];
	};
	add(CompareStatusModified,    @"modified",           @"modified");
	add(CompareStatusLeftOnly,    @"only on the left",   @"only on the left");
	add(CompareStatusRightOnly,   @"only on the right",  @"only on the right");
	add(CompareStatusTypeChanged, @"changed type",       @"changed type");
	_summaryLabel.stringValue = parts.count ? [parts componentsJoinedByString:@" · "] : @"No differences";
}

- (void)reloadOutlines
{
	_treeStrip.needsDisplay = YES;
	[_visibleChildren removeAllObjects];
	for(CompareSide* side : _sides)
	{
		[side.items removeAllObjects];
		[side.outlineView reloadData];
	}
}

// =============================
// = Expansion and reveal state =
// =============================

- (NSArray<NSString*>*)expandedRelativePaths
{
	NSMutableArray* paths = [NSMutableArray array];
	NSOutlineView* outlineView = _sides[0].outlineView;
	for(NSInteger row = 0; row < outlineView.numberOfRows; ++row)
	{
		CompareNode* node = [outlineView itemAtRow:row];
		if([outlineView isItemExpanded:node])
			[paths addObject:node.relativePath];
	}
	return paths;
}

- (NSString*)selectedRelativePath
{
	NSOutlineView* outlineView = _sides[0].outlineView;
	return outlineView.selectedRow == -1 ? nil : [[outlineView itemAtRow:outlineView.selectedRow] relativePath];
}

- (BOOL)isVisible:(CompareNode*)node
{
	return node == _root || ((node.mask & MaskForFilter(_filter)) && [self searchShows:node]);
}

// A new window opens with its changed entries in view: every folder that
// contains differences is expanded. Folders that are a difference themselves
// (only on one side, or a file on the other) stay collapsed; their row shows it.
- (void)expandFoldersWithDifferences:(CompareNode*)node
{
	for(CompareNode* child in node.children)
	{
		if(compare::contains_differences(child) && [self isVisible:child])
		{
			[_sides[0].outlineView expandItem:child];
			[self expandFoldersWithDifferences:child];
		}
	}
}

- (void)expandRelativePaths:(NSArray<NSString*>*)paths
{
	// Parents are listed before their children, so they expand first.
	for(NSString* path in paths)
	{
		CompareNode* node = [_root nodeAtRelativePath:path];
		if(node && [self isVisible:node])
			[_sides[0].outlineView expandItem:node];
	}
}

- (void)revealRelativePath:(NSString*)relativePath select:(BOOL)select
{
	CompareNode* node = relativePath.length ? [_root nodeAtRelativePath:relativePath] : nil;
	while(node && node != _root && ![self isVisible:node])
		node = node.parent;
	if(!node || node == _root)
		return;

	NSMutableArray<CompareNode*>* chain = [NSMutableArray array];
	for(CompareNode* ancestor = node.parent; ancestor && ancestor != _root; ancestor = ancestor.parent)
		[chain insertObject:ancestor atIndex:0];
	NSOutlineView* outlineView = _sides[0].outlineView;
	for(CompareNode* ancestor in chain)
		[outlineView expandItem:ancestor];
	if(!select && node.isFolder)
		[outlineView expandItem:node];

	NSInteger row = [outlineView rowForItem:node];
	if(row == -1)
		return;
	if(select)
		[outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	[outlineView scrollRowToVisible:row];
}

- (void)setFocus:(NSString*)focus
{
	_focus = [focus copy];
	if(_root)
		[self revealRelativePath:_focus select:NO];
	else
		_revealFocusAfterLoad = YES;
}

// ===========
// = Filters =
// ===========

// The display mode: which entries the trees show (View menu). Every open
// window follows, as the choice is also the default for new windows.
- (void)setFilter:(CompareFilter)filter
{
	if(filter == _filter)
		return;
	[self applyFilter:filter];
	[NSNotificationCenter.defaultCenter postNotificationName:CompareDisplayDidChangeNotification object:self userInfo:@{ @"filter": @(filter) }];
}

- (void)applyFilter:(CompareFilter)filter
{
	if(filter == _filter)
		return;
	NSArray* expanded = [self expandedRelativePaths];
	NSString* selected = [self selectedRelativePath];
	_filter = filter;
	[NSUserDefaults.standardUserDefaults setInteger:filter forKey:kCompareFilterDefaultsKey];
	[self reloadOutlines];
	[self expandRelativePaths:expanded];
	if(selected)
		[self revealRelativePath:selected select:YES];
}

// View → Changed Files / Only on the Left / Only on the Right / All Files (tag = mode).
- (IBAction)takeDisplayModeFrom:(NSMenuItem*)sender
{
	[self selectTabAtIndex:0];
	[self setFilter:(CompareFilter)MIN(MAX(sender.tag, 0), CompareFilterAll)];
}

// View → Expand All / Collapse All: every folder the trees show (in the
// current display mode and name filter), on both sides.
- (IBAction)expandAllFolders:(id)sender
{
	[self selectTabAtIndex:0];
	[_sides[0].outlineView expandItem:nil expandChildren:YES];
	[self scrollSelectionOrTopToVisible];
}

- (IBAction)collapseAllFolders:(id)sender
{
	[self selectTabAtIndex:0];
	[_sides[0].outlineView collapseItem:nil collapseChildren:YES];
	[self scrollSelectionOrTopToVisible];
}

- (void)scrollSelectionOrTopToVisible
{
	NSOutlineView* outlineView = _sides[0].outlineView;
	NSInteger row = outlineView.selectedRow;
	[outlineView scrollRowToVisible:row != -1 ? row : 0];
}

// ===================================
// = Outline data source (both sides) =
// ===================================

- (NSArray<CompareNode*>*)visibleChildrenOfNode:(CompareNode*)node
{
	NSArray* children = [_visibleChildren objectForKey:node];
	if(!children)
	{
		CompareStatus mask = MaskForFilter(_filter);
		BOOL searching = _search.length && ![self nameMatchesWithin:node];
		children = [node.children filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(CompareNode* child, NSDictionary*){
			return (child.mask & mask) != 0 && (!searching || [self searchShows:child]);
		}]] ?: @[ ];
		[_visibleChildren setObject:children forKey:node];
	}
	return children;
}

- (NSInteger)outlineView:(NSOutlineView*)outlineView numberOfChildrenOfItem:(CompareNode*)item
{
	return _root ? [self visibleChildrenOfNode:item ?: _root].count : 0;
}

- (id)outlineView:(NSOutlineView*)outlineView child:(NSInteger)index ofItem:(CompareNode*)item
{
	return [self visibleChildrenOfNode:item ?: _root][index];
}

- (BOOL)outlineView:(NSOutlineView*)outlineView isItemExpandable:(CompareNode*)item
{
	return item.isFolder && [self visibleChildrenOfNode:item].count;
}

- (FileItem*)fileItemForNode:(CompareNode*)node side:(CompareSide*)side
{
	FileItem* item = [side.items objectForKey:node];
	if(!item)
	{
		NSString* path = side.left ? node.leftPath : node.rightPath;
		CompareKind kind = side.left ? node.leftKind : node.rightKind;
		if(path)
		{
			item = [FileItem fileItemWithURL:[NSURL fileURLWithPath:path isDirectory:kind == CompareKindDirectory]];
		}
		else
		{
			// Placeholder where the other side has an entry: named like it, dimmed.
			item = [FileItem fileItemWithURL:[NSURL fileURLWithPath:[side.root stringByAppendingPathComponent:node.relativePath] isDirectory:node.isFolder]];
			item.localizedName = node.name;
			item.missing = YES;
		}
		item.toolTip = path ? path.stringByAbbreviatingWithTildeInPath : [NSString stringWithFormat:@"Not on the %@", side.left ? @"left" : @"right"];
		[side.items setObject:item forKey:node];
	}
	return item;
}

- (id)outlineView:(NSOutlineView*)outlineView objectValueForTableColumn:(NSTableColumn*)tableColumn byItem:(CompareNode*)item
{
	return [self fileItemForNode:item side:[self sideForOutlineView:outlineView]];
}

- (NSView*)outlineView:(NSOutlineView*)outlineView viewForTableColumn:(NSTableColumn*)tableColumn item:(CompareNode*)item
{
	FileItemTableCellView* cell = [outlineView makeViewWithIdentifier:tableColumn.identifier owner:self];
	if(!cell)
	{
		cell = [[FileItemTableCellView alloc] init];
		cell.identifier = tableColumn.identifier;
		cell.openButton.enabled = NO;
		// The comparison is read-only: no renaming from the tree.
		[cell.textField unbind:NSEditableBinding];
		cell.textField.editable = NO;
	}
	// Placeholders (no entry on this side) show the other side's name dimmed.
	CompareSide* side = [self sideForOutlineView:outlineView];
	cell.textField.textColor = (side.left ? item.leftPath : item.rightPath) ? NSColor.labelColor : NSColor.tertiaryLabelColor;
	return cell;
}

- (NSTableRowView*)outlineView:(NSOutlineView*)outlineView rowViewForItem:(CompareNode*)item
{
	CompareRowView* rowView = [outlineView makeViewWithIdentifier:@"compareRow" owner:self] ?: [CompareRowView new];
	rowView.identifier = @"compareRow";
	rowView.tintColor  = compare::row_color(item, [self sideForOutlineView:outlineView].left);
	rowView.marker     = compare::contains_differences(item);
	rowView.toolTip    = rowView.marker ? @"Something inside this folder differs" : nil;
	return rowView;
}

// ======================================
// = Keep both trees showing the same rows =
// ======================================

- (void)outlineViewItemDidExpand:(NSNotification*)notification
{
	_treeStrip.needsDisplay = YES;
	if(_synchronizing)
		return;
	_synchronizing = YES;
	[[self otherSide:[self sideForOutlineView:notification.object]].outlineView expandItem:notification.userInfo[@"NSObject"]];
	_synchronizing = NO;
}

- (void)outlineViewItemDidCollapse:(NSNotification*)notification
{
	_treeStrip.needsDisplay = YES;
	if(_synchronizing)
		return;
	_synchronizing = YES;
	[[self otherSide:[self sideForOutlineView:notification.object]].outlineView collapseItem:notification.userInfo[@"NSObject"]];
	_synchronizing = NO;
}

- (void)outlineViewSelectionDidChange:(NSNotification*)notification
{
	if(_synchronizing)
		return;
	_synchronizing = YES;
	NSOutlineView* source = notification.object;
	[[self otherSide:[self sideForOutlineView:source]].outlineView selectRowIndexes:source.selectedRowIndexes byExtendingSelection:NO];
	_synchronizing = NO;
}

// ==============================
// = File comparison tabs =
// ==============================

- (IBAction)openSelectedFiles:(id)sender
{
	NSOutlineView* outlineView = [sender isKindOfClass:NSOutlineView.class] ? sender : _sides[0].outlineView;
	NSInteger clicked = outlineView.clickedRow;
	NSIndexSet* rows = clicked != -1 && ![outlineView.selectedRowIndexes containsIndex:clicked] ? [NSIndexSet indexSetWithIndex:clicked] : outlineView.selectedRowIndexes;

	// Double-clicking a single folder expands or collapses it.
	if(rows.count == 1)
	{
		CompareNode* node = [outlineView itemAtRow:rows.firstIndex];
		if(node.isFolder)
		{
			if([outlineView isItemExpanded:node])
					[outlineView collapseItem:node];
			else	[outlineView expandItem:node];
			return;
		}
	}

	NSInteger last = NSNotFound;
	for(NSUInteger row = rows.firstIndex; row != NSNotFound; row = [rows indexGreaterThanIndex:row])
	{
		CompareNode* node = [outlineView itemAtRow:row];
		if(!node.isFolder)
			last = [self indexOfTabForNode:node];
	}
	if(last != NSNotFound)
		[self selectTabAtIndex:last];
}

// Returns the existing tab for the entry, or adds one.
- (NSUInteger)indexOfTabForNode:(CompareNode*)node
{
	for(NSUInteger i = 1; i < _tabs.count; ++i)
	{
		if([_tabs[i].relativePath isEqualToString:node.relativePath])
			return i;
	}

	[_tabs addObject:[self makeTabForNode:node]];
	[_tabBar reloadData];
	return _tabs.count - 1;
}

- (CompareTab*)makeTabForNode:(CompareNode*)node
{
	CompareTab* tab = [CompareTab new];
	tab.identifier   = [NSUUID UUID];
	tab.relativePath = node.relativePath;
	tab.node         = node;
	tab.diffView     = [[CompareDiffView alloc] initWithFrame:NSZeroRect];
	tab.diffView.hostWindow = self.window;
	__weak CompareWindowController* weakSelf = self;
	tab.diffView.changeHandler = ^(CompareDiffView* view, NSInteger change, BOOL toRight){
		[weakSelf copyChange:change inView:view toRight:toRight];
	};
	tab.view         = tab.diffView;
	[tab.diffView setBranch:_branches[0] onLeft:YES];
	[tab.diffView setBranch:_branches[1] onLeft:NO];
	[tab.diffView showNode:node];
	return tab;
}

- (void)updateFileTabs
{
	for(NSUInteger i = 1; i < _tabs.count; ++i)
	{
		CompareTab* tab = _tabs[i];
		[tab.diffView setBranch:_branches[0] onLeft:YES];
		[tab.diffView setBranch:_branches[1] onLeft:NO];
		CompareNode* previous = tab.node;
		tab.node = [_root nodeAtRelativePath:tab.relativePath];
		// A live refresh compares again often: reload only files that changed.
		if(previous && tab.node && previous.leftStamp == tab.node.leftStamp && previous.rightStamp == tab.node.rightStamp && tab.diffView.node)
		{
			// The old tree is gone: copies must use the new entry's paths.
			[tab.diffView updateNode:tab.node];
			continue;
		}
		if(tab.node)
				[tab.diffView showNode:tab.node keepingChange:YES];
		else	[tab.diffView showMessage:@"This file is no longer in either folder."];
	}
	[_tabBar reloadData];
}

- (void)selectTabAtIndex:(NSUInteger)index
{
	if(index >= _tabs.count)
		return;
	NSView* view = _tabs[index].view;
	if(view.superview != _tabContent)
	{
		[_tabContent.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
		view.translatesAutoresizingMaskIntoConstraints = NO;
		[_tabContent addSubview:view];
		[NSLayoutConstraint activateConstraints:@[
			[view.topAnchor constraintEqualToAnchor:_tabContent.topAnchor],
			[view.bottomAnchor constraintEqualToAnchor:_tabContent.bottomAnchor],
			[view.leadingAnchor constraintEqualToAnchor:_tabContent.leadingAnchor],
			[view.trailingAnchor constraintEqualToAnchor:_tabContent.trailingAnchor],
		]];
	}
	_selectedTab = index;
	_tabBar.selectedTabIndex = index;
	NSView* responder = _tabs[index].diffView ? _tabs[index].diffView.leftTextView : (NSView*)_sides[0].outlineView;
	[self.window makeFirstResponder:responder];
}

- (void)closeTabAtIndex:(NSUInteger)index
{
	if(index == 0 || index >= _tabs.count) // the tree tab stays
		return;
	[_tabs removeObjectAtIndex:index];
	NSUInteger selected = _selectedTab;
	if(selected == index)
		selected = MIN(index, _tabs.count - 1);
	else if(selected > index)
		--selected;
	[_tabBar reloadData];
	[self selectTabAtIndex:selected];
}

- (IBAction)closeTab:(id)sender
{
	if(_selectedTab == 0)
			[self.window performClose:sender];
	else	[self closeTabAtIndex:_selectedTab];
}

- (IBAction)selectNextTab:(id)sender     { [self selectTabAtIndex:(_selectedTab + 1) % _tabs.count]; }
- (IBAction)selectPreviousTab:(id)sender { [self selectTabAtIndex:(_selectedTab + _tabs.count - 1) % _tabs.count]; }

- (CompareDiffView*)selectedDiffView
{
	return _tabs[_selectedTab].diffView;
}

- (NSUInteger)tabCount         { return _tabs.count; }
- (NSUInteger)selectedTabIndex { return _selectedTab; }

// =============
// = Transfers =
// =============

typedef BOOL (^CompareChangeBlock)(CompareChangeSet* changes, NSString** error);

// For a redo while the folders are being compared again (after Swap).
static BOOL SetNotComparedError (NSString** error)
{
	if(error)
		*error = @"The folders are being compared. Try again once the comparison has finished.";
	return NO;
}

- (CompareNode*)rootNode
{
	return _root;
}

- (compare_options_t)restatOptions
{
	compare_options_t options;
	options.git             = CompareWindowController.gitExecutable;
	options.include_ignored = _includeIgnored;
	options.excludes        = compare_excludes_t(CompareSettings.excludedNames);
	options.folders_first = [NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsFoldersOnTopKey];
	return options;
}

// =====================
// = Edit in TextMate =
// =====================

// The side File → Edit in TextMate opens: the focused tree or text view, else
// the left (the project's own worktree).
- (BOOL)editsLeftSide
{
	NSResponder* responder = self.window.firstResponder;
	if(CompareDiffView* diff = self.selectedDiffView)
		return responder != diff.rightTextView;
	return responder != _sides[1].outlineView;
}

// What Edit in TextMate opens: files and links on that side (TextMate opens
// a link's target), at the current change's line in a file tab.
- (NSArray<NSURL*>*)editURLsForNodes:(NSArray<CompareNode*>*)nodes left:(BOOL)left line:(NSInteger)line
{
	NSMutableArray<NSURL*>* urls = [NSMutableArray array];
	for(CompareNode* node in nodes)
	{
		CompareKind kind = left ? node.leftKind : node.rightKind;
		NSString* path   = left ? node.leftPath : node.rightPath;
		if((kind == CompareKindFile || kind == CompareKindSymlink) && path)
		{
			if(NSURL* url = compare::textmate_url(path, line))
				[urls addObject:url];
		}
	}
	return urls;
}

- (NSArray<NSURL*>*)editURLs
{
	BOOL left = self.editsLeftSide;
	if(CompareDiffView* diff = self.selectedDiffView)
		return diff.node ? [self editURLsForNodes:@[ diff.node ] left:left line:[diff editingLineOnLeft:left]] : @[ ];
	NSOutlineView* outlineView = _sides[0].outlineView;
	return [self editURLsForNodes:[self topmostNodesInRows:outlineView.selectedRowIndexes outlineView:outlineView] left:left line:0];
}

- (IBAction)editInTextMate:(id)sender
{
	[self openInTextMate:self.editURLs];
}

- (void)editClickedEntries:(NSMenuItem*)sender
{
	[self openInTextMate:sender.representedObject];
}

- (void)openInTextMate:(NSArray<NSURL*>*)urls
{
	if(!urls.count)
		return;
	if(EditHandler)
		return EditHandler(urls);
	NSURL* app = TextMateApplicationURL();
	if(!app)
		return [self presentProblem:@"TextMate could not be found."];
	NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
	configuration.activates = YES;
	__weak CompareWindowController* weakSelf = self;
	[NSWorkspace.sharedWorkspace openURLs:urls withApplicationAtURL:app configuration:configuration completionHandler:^(NSRunningApplication* application, NSError* error){
		if(error)
		{
			dispatch_async(dispatch_get_main_queue(), ^{
				[weakSelf presentProblem:[NSString stringWithFormat:@"TextMate could not open the file: %@", error.localizedDescription]];
			});
		}
	}];
}

- (void)presentProblem:(NSString*)problem
{
	_lastProblem = [problem copy];
	if(!problem || !ConfirmsChanges)
		return;
	NSAlert* alert = [NSAlert new];
	alert.messageText     = @"The change could not be made.";
	alert.informativeText = problem;
	[alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (BOOL)confirm:(NSString*)message informative:(NSString*)informative button:(NSString*)button
{
	if(!ConfirmsChanges)
		return YES;
	NSAlert* alert = [NSAlert new];
	alert.messageText     = message;
	alert.informativeText = informative;
	[alert addButtonWithTitle:button];
	[alert addButtonWithTitle:@"Cancel"];
	return [alert runModal] == NSAlertFirstButtonReturn;
}

// Runs `block` with a fresh change set, registers its undo (whose redo runs
// `block` again), then re-reads the affected entries from disk.
- (BOOL)performChangesNamed:(NSString*)name affecting:(NSArray<NSString*>*)paths using:(CompareChangeBlock)block
{
	return [self performChangesNamed:name affecting:paths using:block expecting:nil];
}

// `expected`: for a redo, the disk as the undo left it. The original transfer
// is replayed only when nothing has changed since; otherwise a newer edit
// would become the redo's baseline and be overwritten.
- (BOOL)performChangesNamed:(NSString*)name affecting:(NSArray<NSString*>*)paths using:(CompareChangeBlock)block expecting:(CompareDiskSnapshot*)expected
{
	_lastProblem = nil;
	if(NSString* changed = expected.changedPath)
	{
		[self reloadAfterChangingRelativePaths:paths];
		[self presentProblem:[NSString stringWithFormat:@"“%@” has changed since the undo, so the change cannot be redone.", changed.lastPathComponent]];
		return NO;
	}
	CompareChangeSet* changes = [CompareChangeSet new];
	changes.roots = @[ _leftPath, _rightPath ]; // never write through a link out of them
	if(_files)
		changes.roots = @[ _leftPath.stringByDeletingLastPathComponent, _rightPath.stringByDeletingLastPathComponent ];
	NSString* problem = nil;
	BOOL ok = block(changes, &problem);
	if(changes.count)
	{
		NSUndoManager* undoManager = self.window.undoManager;
		[undoManager registerUndoWithTarget:self handler:^(CompareWindowController* target){
			[target undoChanges:changes named:name affecting:paths redo:block];
		}];
		[undoManager setActionName:name];
	}
	[self reloadAfterChangingRelativePaths:paths];
	if(!ok)
		[self presentProblem:problem ?: @"Unknown error."];
	return ok;
}

- (void)undoChanges:(CompareChangeSet*)changes named:(NSString*)name affecting:(NSArray<NSString*>*)paths redo:(CompareChangeBlock)block
{
	_lastProblem = nil;
	NSArray<NSString*>* touched = changes.paths;
	NSString* problem = nil;
	BOOL ok = [changes undo:&problem];
	[self reloadAfterChangingRelativePaths:paths];
	if(ok)
	{
		CompareDiskSnapshot* restored = [CompareDiskSnapshot snapshotOfPaths:touched];
		[self.window.undoManager registerUndoWithTarget:self handler:^(CompareWindowController* target){
			[target performChangesNamed:name affecting:paths using:block expecting:restored];
		}];
		[self.window.undoManager setActionName:name];
	}
	else
	{
		[self presentProblem:problem];
	}
}

// Re-reads changed entries and redraws, keeping expansion, selection and
// each open file tab's change number.
- (void)reloadAfterChangingRelativePaths:(NSArray<NSString*>*)paths
{
	if(_files)
	{
		// Reading the files can take long: compare again off the main thread.
		_reloadFiles = YES;
		return [self refresh:self];
	}
	if(!_root)
		return;
	NSArray<NSString*>* expanded = [self expandedRelativePaths];
	NSString* selected = [self selectedRelativePath];
	CompareRestatPaths(_root, paths, self.restatOptions);
	[self reloadOutlines];
	[self expandRelativePaths:expanded];
	if(selected)
		[self revealRelativePath:selected select:YES];
	[self updateSummary];

	auto affects = ^BOOL(NSString* tabPath){
		for(NSString* path in paths)
		{
			if(!path.length || [tabPath isEqualToString:path] || [tabPath hasPrefix:[path stringByAppendingString:@"/"]])
				return YES;
		}
		return NO;
	};
	for(NSUInteger i = 1; i < _tabs.count; ++i)
	{
		CompareTab* tab = _tabs[i];
		tab.node = [_root nodeAtRelativePath:tab.relativePath];
		if(!affects(tab.relativePath))
		{
			if(tab.node && tab.diffView.node)
				[tab.diffView updateNode:tab.node];
			continue;
		}
		if(tab.node)
				[tab.diffView showNode:tab.node keepingChange:YES];
		else	[tab.diffView showMessage:@"This file is no longer in either folder."];
	}
	[_tabBar reloadData];
}

- (void)copyEntriesAtRelativePaths:(NSArray<NSString*>*)paths toRight:(BOOL)toRight
{
	NSUInteger count = 0;
	BOOL replacesType = NO;
	for(NSString* path in paths)
	{
		CompareNode* node = [_root nodeAtRelativePath:path];
		count += CompareCountCopies(node, toRight);
		replacesType |= CompareCopyReplacesType(node, toRight);
	}
	if(count == 0)
	{
		NSBeep();
		return;
	}

	NSString* side = toRight ? @"right" : @"left";
	if(count > 1 || replacesType)
	{
		NSString* message = count == 1 ? [NSString stringWithFormat:@"Copy 1 item to the %@?", side] : [NSString stringWithFormat:@"Copy %lu items to the %@?", count, side];
		NSMutableString* informative = [NSMutableString stringWithFormat:@"Items with the same name on the %@ are replaced.", side];
		if(replacesType)
			[informative appendFormat:@" Where the %@ has a folder in place of a file, or a file in place of a folder, it is moved to the Trash.", side];
		[informative appendString:@" You can undo this."];
		if(![self confirm:message informative:informative button:@"Copy"])
			return;
	}

	// A redo runs this again, maybe after the sides were swapped: it copies
	// into the same folder, whichever side that is now.
	NSString* destination = toRight ? _rightPath : _leftPath;
	__weak CompareWindowController* weakSelf = self;
	[self performChangesNamed:toRight ? @"Copy to the Right" : @"Copy to the Left" affecting:paths using:^BOOL(CompareChangeSet* changes, NSString** error){
		CompareNode* root = weakSelf.rootNode;
		if(!root)
			return SetNotComparedError(error);
		BOOL right = [weakSelf.rightPath isEqualToString:destination];
		for(NSString* path in paths)
		{
			CompareNode* node = [root nodeAtRelativePath:path];
			if(node && !CompareCopyNode(node, right, changes, error))
				return NO;
		}
		return YES;
	}];
}

- (void)trashEntriesAtRelativePaths:(NSArray<NSString*>*)paths onLeft:(BOOL)left
{
	NSString* folder = left ? _leftPath : _rightPath; // as for copies: the same folder on redo
	__weak CompareWindowController* weakSelf = self;
	[self performChangesNamed:@"Move to Trash" affecting:paths using:^BOOL(CompareChangeSet* changes, NSString** error){
		CompareNode* root = weakSelf.rootNode;
		if(!root)
			return SetNotComparedError(error);
		BOOL onLeft = [weakSelf.leftPath isEqualToString:folder];
		for(NSString* path in paths)
		{
			CompareNode* node = [root nodeAtRelativePath:path];
			if(node && !CompareTrashNode(node, onLeft, changes, error))
				return NO;
		}
		return YES;
	}];
}

- (void)copyChange:(NSInteger)change inView:(CompareDiffView*)view toRight:(BOOL)toRight
{
	CompareNode* node = view.node;
	NSData* contents = [view contentsWithChange:change toRight:toRight];
	if(!node || !contents)
		return;
	NSData* expectedDestination = [view comparedDataOnLeft:!toRight];
	NSData* expectedSource      = [view comparedDataOnLeft:toRight];
	NSString* destination = [node pathOnLeft:!toRight];
	NSString* source      = [node pathOnLeft:toRight];
	mode_t mode = CompareStampAtPath(source).mode ?: 0644;
	NSString* relativePath = node.relativePath;

	[self performChangesNamed:toRight ? @"Copy Change to the Right" : @"Copy Change to the Left" affecting:@[ relativePath ] using:^BOOL(CompareChangeSet* changes, NSString** error){
		// Write only over exactly what was compared.
		auto current = ^NSData*(NSString* path){
			return CompareStampAtPath(path).exists ? [NSData dataWithContentsOfFile:path] : [NSData data];
		};
		if(![current(destination) isEqualToData:expectedDestination] || ![current(source) isEqualToData:expectedSource])
		{
			if(error)
				*error = [NSString stringWithFormat:@"“%@” changed since it was compared. Compare again, then try once more.", relativePath];
			return NO;
		}
		return [changes writeData:contents toPath:destination mode:mode error:error];
	}];
}

- (IBAction)copyToRight:(id)sender { [self copySelectionToRight:YES]; }
- (IBAction)copyToLeft:(id)sender  { [self copySelectionToRight:NO]; }

- (void)copySelectionToRight:(BOOL)toRight
{
	if(CompareDiffView* view = self.selectedDiffView)
	{
		if(view.currentChange >= 0 && view.currentChange < view.changeCount)
			[self copyChange:view.currentChange inView:view toRight:toRight];
		else
			NSBeep();
		return;
	}
	NSOutlineView* outlineView = _sides[0].outlineView;
	NSArray<CompareNode*>* nodes = [self topmostNodesInRows:outlineView.selectedRowIndexes outlineView:outlineView];
	[self copyEntriesAtRelativePaths:[nodes valueForKey:@"relativePath"] toRight:toRight];
}

- (BOOL)canCopySelectionToRight:(BOOL)toRight
{
	if(CompareDiffView* view = self.selectedDiffView)
		return view.currentChange >= 0 && view.currentChange < view.changeCount;
	NSOutlineView* outlineView = _sides[0].outlineView;
	for(CompareNode* node in [self topmostNodesInRows:outlineView.selectedRowIndexes outlineView:outlineView])
	{
		if(CompareCountCopies(node, toRight))
			return YES;
	}
	return NO;
}

- (IBAction)nextChange:(id)sender     { [self.selectedDiffView nextChange:sender]; }
- (IBAction)previousChange:(id)sender { [self.selectedDiffView previousChange:sender]; }

- (BOOL)validateMenuItem:(NSMenuItem*)item
{
	if(item.action == @selector(nextChange:) || item.action == @selector(previousChange:))
		return self.selectedDiffView && [self.selectedDiffView validateMenuItem:item];
	if(item.action == @selector(copyToRight:) || item.action == @selector(copyToLeft:))
	{
		BOOL fileTab = self.selectedDiffView != nil;
		BOOL toRight = item.action == @selector(copyToRight:);
		item.title = fileTab ? (toRight ? @"Copy Change to the Right" : @"Copy Change to the Left") : (toRight ? @"Copy to the Right" : @"Copy to the Left");
		return [self canCopySelectionToRight:toRight];
	}
	// Two files have no trees to filter, expand or open from.
	if(_files && (item.action == @selector(takeDisplayModeFrom:) || item.action == @selector(toggleIgnoredFilesFromMenu:) || item.action == @selector(openSelectedFiles:)))
		return NO;
	if(item.action == @selector(takeDisplayModeFrom:))
		item.state = item.tag == _filter ? NSControlStateValueOn : NSControlStateValueOff;
	if(item.action == @selector(toggleIgnoredFilesFromMenu:))
		item.state = _includeIgnored ? NSControlStateValueOn : NSControlStateValueOff;
	if(item.action == @selector(expandAllFolders:) || item.action == @selector(collapseAllFolders:))
		return _root != nil;
	if(item.action == @selector(editInTextMate:))
	{
		// In a file tab, say which side opens.
		item.title = self.selectedDiffView ? (self.editsLeftSide ? @"Edit Left in TextMate" : @"Edit Right in TextMate") : @"Edit in TextMate";
		return self.editURLs.count > 0;
	}
	if(item.action == @selector(openSelectedFiles:))
		return _selectedTab == 0 && _sides[0].outlineView.numberOfSelectedRows > 0;
	if(item.action == @selector(selectNextTab:) || item.action == @selector(selectPreviousTab:))
		return _tabs.count > 1;
	if(item.action == @selector(closeTab:))
		item.title = _selectedTab == 0 ? @"Close Window" : @"Close Tab";
	return YES;
}

// ===================================
// = Tab bar data source and delegate =
// ===================================

- (NSUInteger)numberOfRowsInTabBarView:(OakTabBarView*)aTabBarView
{
	return _tabs.count;
}

- (NSString*)tabBarView:(OakTabBarView*)aTabBarView titleForIndex:(NSUInteger)index
{
	CompareTab* tab = _tabs[index];
	if(!tab.relativePath)
		return @"Files";
	// Name clashes show the parent folder, as TextMate's tabs do.
	NSString* name = tab.relativePath.lastPathComponent;
	for(CompareTab* other in _tabs)
	{
		if(other != tab && [other.relativePath.lastPathComponent isEqualToString:name])
		{
			NSString* parent = tab.relativePath.stringByDeletingLastPathComponent.lastPathComponent;
			return parent.length ? [NSString stringWithFormat:@"%@ — %@", name, parent] : name;
		}
	}
	return name;
}

- (NSString*)tabBarView:(OakTabBarView*)aTabBarView pathForIndex:(NSUInteger)index
{
	CompareTab* tab = _tabs[index];
	return tab.node.leftPath ?: tab.node.rightPath ?: @"";
}

- (NSString*)tabBarView:(OakTabBarView*)aTabBarView toolTipForIndex:(NSUInteger)index
{
	return _tabs[index].relativePath ?: @"Folder comparison";
}

- (NSUUID*)tabBarView:(OakTabBarView*)aTabBarView UUIDForIndex:(NSUInteger)index
{
	return _tabs[index].identifier;
}

- (BOOL)tabBarView:(OakTabBarView*)aTabBarView isEditedAtIndex:(NSUInteger)index
{
	return NO;
}

- (BOOL)tabBarView:(OakTabBarView*)aTabBarView isClosableAtIndex:(NSUInteger)index
{
	return index != 0; // the Files tab stays
}

- (BOOL)tabBarView:(OakTabBarView*)aTabBarView shouldSelectIndex:(NSUInteger)index
{
	[self selectTabAtIndex:index];
	return YES;
}

- (void)performCloseTab:(OakTabBarView*)sender
{
	[self closeTabAtIndex:[sender isKindOfClass:OakTabBarView.class] ? sender.tag : _selectedTab];
}

- (void)clipViewBoundsDidChange:(NSNotification*)notification
{
	_treeStrip.needsDisplay = YES;
	if(_synchronizing)
		return;
	NSClipView* source = notification.object;
	CompareSide* other = source == _sides[0].scrollView.contentView ? _sides[1] : _sides[0];
	NSClipView* destination = other.scrollView.contentView;
	NSPoint origin = destination.bounds.origin;
	if(origin.y == source.bounds.origin.y)
		return;
	_synchronizing = YES;
	origin.y = source.bounds.origin.y;
	[destination scrollToPoint:origin];
	[other.scrollView reflectScrolledClipView:destination];
	_synchronizing = NO;
}

// ================
// = Context menu =
// ================

- (void)menuNeedsUpdate:(NSMenu*)menu
{
	[menu removeAllItems];
	for(CompareSide* side : _sides)
	{
		if(side.outlineView.menu != menu)
			continue;
		NSInteger row = side.outlineView.clickedRow;
		CompareNode* node = row == -1 ? nil : [side.outlineView itemAtRow:row];
		NSString* path = side.left ? node.leftPath : node.rightPath;
		NSArray<CompareNode*>* nodes = [self nodesForMenuInOutlineView:side.outlineView];
		BOOL present = NO;
		NSUInteger copies = 0;
		for(CompareNode* candidate in nodes)
		{
			present |= (side.left ? candidate.leftKind : candidate.rightKind) != CompareKindNone;
			copies  += CompareCountCopies(candidate, side.left);
		}
		NSMenuItem* copy = [menu addItemWithTitle:side.left ? @"Copy to the Right" : @"Copy to the Left" action:copies ? @selector(copyClickedEntries:) : NULL keyEquivalent:@""];
		copy.target = self;
		copy.representedObject = @{ @"toRight": @(side.left), @"paths": [nodes valueForKey:@"relativePath"] };
		NSMenuItem* trash = [menu addItemWithTitle:@"Move to Trash" action:present ? @selector(trashClickedEntries:) : NULL keyEquivalent:@""];
		trash.target = self;
		trash.representedObject = @{ @"left": @(side.left), @"paths": [nodes valueForKey:@"relativePath"] };
		[menu addItem:NSMenuItem.separatorItem];
		NSArray<NSURL*>* edits = [self editURLsForNodes:nodes left:side.left line:0];
		NSMenuItem* edit = [menu addItemWithTitle:@"Edit in TextMate" action:edits.count ? @selector(editClickedEntries:) : NULL keyEquivalent:@""];
		edit.target = self;
		edit.representedObject = edits;
		NSMenuItem* reveal = [menu addItemWithTitle:@"Reveal in Finder" action:path ? @selector(revealInFinder:) : NULL keyEquivalent:@""];
		reveal.target = self;
		reveal.representedObject = path;
	}
}

// The clicked row, or the selection when the click is inside it; without
// nested duplicates (an entry whose folder is also included).
- (NSArray<CompareNode*>*)nodesForMenuInOutlineView:(NSOutlineView*)outlineView
{
	NSInteger clicked = outlineView.clickedRow;
	NSIndexSet* rows = clicked == -1 || [outlineView.selectedRowIndexes containsIndex:clicked] ? outlineView.selectedRowIndexes : [NSIndexSet indexSetWithIndex:clicked];
	return [self topmostNodesInRows:rows outlineView:outlineView];
}

- (NSArray<CompareNode*>*)topmostNodesInRows:(NSIndexSet*)rows outlineView:(NSOutlineView*)outlineView
{
	NSMutableArray<CompareNode*>* nodes = [NSMutableArray array];
	for(NSUInteger row = rows.firstIndex; row != NSNotFound; row = [rows indexGreaterThanIndex:row])
	{
		CompareNode* node = [outlineView itemAtRow:row];
		BOOL nested = NO;
		for(CompareNode* ancestor = node.parent; ancestor && !nested; ancestor = ancestor.parent)
			nested = [nodes containsObject:ancestor];
		if(!nested)
			[nodes addObject:node];
	}
	return nodes;
}

- (void)copyClickedEntries:(NSMenuItem*)sender
{
	[self copyEntriesAtRelativePaths:sender.representedObject[@"paths"] toRight:[sender.representedObject[@"toRight"] boolValue]];
}

- (void)trashClickedEntries:(NSMenuItem*)sender
{
	[self trashEntriesAtRelativePaths:sender.representedObject[@"paths"] onLeft:[sender.representedObject[@"left"] boolValue]];
}

- (void)revealInFinder:(NSMenuItem*)sender
{
	if(NSString* path = sender.representedObject)
		[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:path] ]];
}
@end
