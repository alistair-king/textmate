#import "AIPanelViewController.h"

@interface AIPanelSplitView : NSSplitView
@property (nonatomic) BOOL trackingDivider;
@end

@implementation AIPanelSplitView
- (void)mouseDown:(NSEvent*)event
{
	self.trackingDivider = YES;
	[super mouseDown:event];
	self.trackingDivider = NO;
}
@end

@interface AIPanelViewController () <NSSplitViewDelegate>
@property (nonatomic) AIPanelSplitView* splitView;
@property (nonatomic) NSView* contentView;
@property (nonatomic) NSView* panelView;
@property (nonatomic) BOOL adjustingLayout;
@end

@implementation AIPanelViewController
- (instancetype)initWithContentView:(NSView*)contentView
{
	if(self = [super initWithNibName:nil bundle:nil])
	{
		_contentView = contentView;
		_panelPosition = @"right";
		_panelWidth = 320;
		_panelHeight = 220;
		_splitView = [[AIPanelSplitView alloc] initWithFrame:NSZeroRect];
		_splitView.dividerStyle = NSSplitViewDividerStyleThin;
		_splitView.delegate = self;
		self.view = _splitView;

		NSBox* panel = [[NSBox alloc] initWithFrame:NSZeroRect];
		panel.boxType = NSBoxCustom;
		panel.borderWidth = 0;
		panel.fillColor = NSColor.windowBackgroundColor;
		panel.contentViewMargins = NSZeroSize;
		panel.accessibilityLabel = @"AI Panel";
		_panelView = panel;
		[self rebuildLayout];
	}
	return self;
}

- (void)setPanelVisible:(BOOL)visible
{
	if(_panelVisible == visible)
		return;
	_panelVisible = visible;
	[self rebuildLayout];
}

- (void)setPanelPosition:(NSString*)position
{
	if(![@[ @"left", @"right", @"bottom" ] containsObject:position] || [_panelPosition isEqualToString:position])
		return;
	_panelPosition = [position copy];
	[self rebuildLayout];
}

- (void)setPanelWidth:(CGFloat)width
{
	_panelWidth = isfinite(width) ? MAX(120, width) : 320;
	[self layoutPanels];
}

- (void)setPanelHeight:(CGFloat)height
{
	_panelHeight = isfinite(height) ? MAX(100, height) : 220;
	[self layoutPanels];
}

- (void)rebuildLayout
{
	NSWindow* window = _splitView.window;
	NSResponder* responder = window.firstResponder;
	BOOL restoreFocus = [responder isKindOfClass:NSView.class] &&
		([(NSView*)responder isDescendantOf:_contentView] ||
		 (_panelVisible && [(NSView*)responder isDescendantOf:_panelView]));
	_adjustingLayout = YES;
	[_contentView removeFromSuperview];
	[_panelView removeFromSuperview];
	_splitView.vertical = ![_panelPosition isEqualToString:@"bottom"];
	if(_panelVisible && [_panelPosition isEqualToString:@"left"])
		[_splitView addSubview:_panelView];
	[_splitView addSubview:_contentView];
	if(_panelVisible && ![_panelPosition isEqualToString:@"left"])
		[_splitView addSubview:_panelView];
	_adjustingLayout = NO;
	[self layoutPanels];
	if(restoreFocus)
		[window makeFirstResponder:responder];
}

- (void)layoutPanels
{
	_adjustingLayout = YES;
	NSRect bounds = _splitView.bounds;
	if(!_panelVisible)
		_contentView.frame = bounds;
	else
	{
		BOOL vertical = _splitView.isVertical;
		CGFloat available = MAX(0, (vertical ? NSWidth(bounds) : NSHeight(bounds)) - _splitView.dividerThickness);
		// Preserve the preferred size when a small window temporarily compresses the panel.
		CGFloat contentMinimum = vertical ? 240 : 120;
		CGFloat size = MIN(vertical ? _panelWidth : _panelHeight, MAX(0, available - contentMinimum));
		CGFloat firstSize = [_panelPosition isEqualToString:@"left"] ? size : available - size;
		NSRect first = bounds, second = bounds;
		if(vertical)
		{
			first.size.width = firstSize;
			second.origin.x += firstSize + _splitView.dividerThickness;
			second.size.width = available - firstSize;
		}
		else
		{
			first.size.height = firstSize;
			second.origin.y += firstSize + _splitView.dividerThickness;
			second.size.height = available - firstSize;
		}
		_splitView.subviews[0].frame = first;
		_splitView.subviews[1].frame = second;
	}
	_adjustingLayout = NO;
}

- (void)splitView:(NSSplitView*)splitView resizeSubviewsWithOldSize:(NSSize)oldSize
{
	[self layoutPanels];
}

- (CGFloat)splitView:(NSSplitView*)splitView constrainSplitPosition:(CGFloat)position ofSubviewAt:(NSInteger)index
{
	CGFloat available = MAX(0, (splitView.isVertical ? NSWidth(splitView.bounds) : NSHeight(splitView.bounds)) - splitView.dividerThickness);
	CGFloat panelMinimum = MIN(splitView.isVertical ? 120 : 100, available / 2);
	CGFloat contentMinimum = MIN(splitView.isVertical ? 240 : 120, available / 2);
	BOOL panelFirst = [_panelPosition isEqualToString:@"left"];
	return MAX(panelFirst ? panelMinimum : contentMinimum, MIN(position, available - (panelFirst ? contentMinimum : panelMinimum)));
}

- (void)splitViewDidResizeSubviews:(NSNotification*)notification
{
	if(!_adjustingLayout && _panelVisible && _splitView.trackingDivider)
	{
		if(_splitView.isVertical)
			_panelWidth = NSWidth(_panelView.frame);
		else
			_panelHeight = NSHeight(_panelView.frame);
	}
}
@end
