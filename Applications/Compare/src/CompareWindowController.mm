#import "CompareWindowController.h"
#import "compare_tree.h"
#import "compare_colors.h"
#import <FileBrowser/FileItem.h>
#import <FileBrowser/FileBrowserOutlineView.h>
#import <FileBrowser/FileItemTableCellView.h>
#import <Preferences/Keys.h>

typedef NS_ENUM(NSInteger, CompareFilter) {
	CompareFilterChanged = 0,
	CompareFilterLeftOnly,
	CompareFilterRightOnly,
	CompareFilterAll,
};

static NSString* const kCompareFilterDefaultsKey = @"compareFilter";

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
@end

@implementation CompareRowView
- (void)setTintColor:(NSColor*)color
{
	if(_tintColor == color)
		return;
	_tintColor = color;
	self.needsDisplay = YES;
}

- (void)drawBackgroundInRect:(NSRect)dirtyRect
{
	[super drawBackgroundInRect:dirtyRect];
	if(_tintColor)
	{
		[_tintColor set];
		NSRectFillUsingOperation(NSIntersectionRect(self.bounds, dirtyRect), NSCompositingOperationSourceOver);
	}
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

@interface CompareWindowController () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate>
@end

@implementation CompareWindowController
{
	CompareSide* _sides[2];
	CompareNode* _root;
	CompareFilter _filter;
	NSMapTable<CompareNode*, NSArray<CompareNode*>*>* _visibleChildren;

	NSSegmentedControl* _filterControl;
	NSTextField* _summaryLabel;
	NSProgressIndicator* _spinner;

	NSProgress* _loading;
	NSUInteger _generation;
	BOOL _synchronizing;
	BOOL _revealFocusAfterLoad;
}

static NSString* GitExecutable;

+ (NSString*)gitExecutable              { return GitExecutable; }
+ (void)setGitExecutable:(NSString*)git { GitExecutable = [git copy]; }

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

		window.title              = [NSString stringWithFormat:@"%@ ⇄ %@", left.lastPathComponent, right.lastPathComponent];
		window.minSize            = NSMakeSize(560, 320);
		window.releasedWhenClosed = NO;
		window.delegate           = self;
		window.tabbingMode        = NSWindowTabbingModeDisallowed;

		_sides[0] = [self makeSideForRoot:left left:YES];
		_sides[1] = [self makeSideForRoot:right left:NO];

		NSSplitView* split = [NSSplitView new];
		split.vertical     = YES;
		split.dividerStyle = NSSplitViewDividerStyleThin;
		[split addArrangedSubview:_sides[0].view];
		[split addArrangedSubview:_sides[1].view];

		NSBox* divider = [NSBox new];
		divider.boxType = NSBoxSeparator;

		NSView* bar = [self makeBar];
		NSView* content = [NSView new];
		for(NSView* view in @[ bar, divider, split ])
		{
			view.translatesAutoresizingMaskIntoConstraints = NO;
			[content addSubview:view];
			[view.leadingAnchor constraintEqualToAnchor:content.leadingAnchor].active = YES;
			[view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor].active = YES;
		}
		[bar.topAnchor constraintEqualToAnchor:content.topAnchor].active = YES;
		[divider.topAnchor constraintEqualToAnchor:bar.bottomAnchor].active = YES;
		[split.topAnchor constraintEqualToAnchor:divider.bottomAnchor].active = YES;
		[split.bottomAnchor constraintEqualToAnchor:content.bottomAnchor].active = YES;
		window.contentView = content;

		[window center];
		[window setFrameAutosaveName:@"CompareWindow"];
		[content layoutSubtreeIfNeeded];
		[split setPosition:NSWidth(split.bounds) / 2 ofDividerAtIndex:0];

		for(CompareSide* side : _sides)
		{
			side.scrollView.contentView.postsBoundsChangedNotifications = YES;
			[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clipViewBoundsDidChange:) name:NSViewBoundsDidChangeNotification object:side.scrollView.contentView];
		}

		[self refresh:self];
	}
	return self;
}

- (void)dealloc
{
	[_loading cancel];
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)windowWillClose:(NSNotification*)notification
{
	[_loading cancel];
}

// ==========
// = Layout =
// ==========

- (NSView*)makeBar
{
	_filterControl = [NSSegmentedControl segmentedControlWithLabels:@[ @"Changed", @"Left Only", @"Right Only", @"All" ] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(takeFilterFrom:)];
	_filterControl.selectedSegment = _filter;
	_filterControl.controlSize = NSControlSizeSmall;
	_filterControl.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];

	_summaryLabel = Label(@"", [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.secondaryLabelColor);
	_summaryLabel.alignment = NSTextAlignmentRight;

	_spinner = [NSProgressIndicator new];
	_spinner.style = NSProgressIndicatorStyleSpinning;
	_spinner.controlSize = NSControlSizeSmall;
	_spinner.displayedWhenStopped = NO;

	NSButton* refresh = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"Refresh"] target:self action:@selector(refresh:)];
	refresh.bezelStyle = NSBezelStyleAccessoryBarAction;
	refresh.toolTip = @"Compare again (⌘R)";

	NSView* spacer = [NSView new];
	[spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];

	NSStackView* bar = [NSStackView stackViewWithViews:@[ _filterControl, spacer, _summaryLabel, _spinner, refresh ]];
	bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	bar.spacing     = 8;
	bar.edgeInsets  = NSEdgeInsetsMake(6, 10, 6, 10);
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
	[side.branchLabel setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSStackView* title = [NSStackView stackViewWithViews:@[ side.nameLabel, side.branchLabel ]];
	title.spacing = 6;

	NSTextField* location = Label(root.stringByAbbreviatingWithTildeInPath, [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.secondaryLabelColor);
	location.toolTip = root;

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

	NSBox* divider = [NSBox new];
	divider.boxType = NSBoxSeparator;

	NSStackView* pane = [NSStackView stackViewWithViews:@[ header, divider, scrollView ]];
	pane.orientation = NSUserInterfaceLayoutOrientationVertical;
	pane.alignment   = NSLayoutAttributeWidth;
	pane.spacing     = 0;
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

	NSString* left  = _leftPath;
	NSString* right = _rightPath;
	NSString* git   = CompareWindowController.gitExecutable;
	BOOL foldersFirst = [NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsFoldersOnTopKey];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		compare_options_t options;
		options.git           = git;
		options.folders_first = foldersFirst;
		options.cancelled     = ^BOOL{ return loading.isCancelled; };
		CompareNode* root     = CompareBuildTree(left, right, options);
		NSString* leftBranch  = root ? CompareBranchLabel(left, git) : nil;
		NSString* rightBranch = root ? CompareBranchLabel(right, git) : nil;
		dispatch_async(dispatch_get_main_queue(), ^{
			if(generation != _generation || loading.isCancelled)
				return;
			[_spinner stopAnimation:self];
			if(!root)
			{
				_summaryLabel.stringValue = @"Comparison failed.";
				return;
			}
			[self showTree:root leftBranch:leftBranch rightBranch:rightBranch];
		});
	});
}

- (void)showTree:(CompareNode*)root leftBranch:(NSString*)leftBranch rightBranch:(NSString*)rightBranch
{
	NSArray<NSString*>* expanded = _root ? [self expandedRelativePaths] : @[ ];
	NSString* selected = [self selectedRelativePath];

	_root = root;
	[self reloadOutlines];
	[self expandRelativePaths:expanded];
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
	if(leftBranch && rightBranch)
		self.window.title = [NSString stringWithFormat:@"%@ ⇄ %@", leftBranch, rightBranch];
	self.window.subtitle = _leftPath.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath;
	[self updateSummary];
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
	return node == _root || (node.mask & MaskForFilter(_filter));
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

- (void)takeFilterFrom:(NSSegmentedControl*)sender
{
	CompareFilter filter = (CompareFilter)sender.selectedSegment;
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

// ===================================
// = Outline data source (both sides) =
// ===================================

- (NSArray<CompareNode*>*)visibleChildrenOfNode:(CompareNode*)node
{
	NSArray* children = [_visibleChildren objectForKey:node];
	if(!children)
	{
		CompareStatus mask = MaskForFilter(_filter);
		children = [node.children filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(CompareNode* child, NSDictionary*){
			return (child.mask & mask) != 0;
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
	return rowView;
}

// ======================================
// = Keep both trees showing the same rows =
// ======================================

- (void)outlineViewItemDidExpand:(NSNotification*)notification
{
	if(_synchronizing)
		return;
	_synchronizing = YES;
	[[self otherSide:[self sideForOutlineView:notification.object]].outlineView expandItem:notification.userInfo[@"NSObject"]];
	_synchronizing = NO;
}

- (void)outlineViewItemDidCollapse:(NSNotification*)notification
{
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

- (void)clipViewBoundsDidChange:(NSNotification*)notification
{
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
		NSMenuItem* reveal = [menu addItemWithTitle:@"Reveal in Finder" action:path ? @selector(revealInFinder:) : NULL keyEquivalent:@""];
		reveal.target = self;
		reveal.representedObject = path;
	}
}

- (void)revealInFinder:(NSMenuItem*)sender
{
	if(NSString* path = sender.representedObject)
		[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:path] ]];
}
@end
