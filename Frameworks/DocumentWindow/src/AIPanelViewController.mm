#import "AIPanelViewController.h"
#import "OakSwiftUI-Swift.h"

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
@property (nonatomic) OakTerminalPanelController* terminalController;
@property (nonatomic) NSArray<NSColor*>* terminalColors;
@property (nonatomic) NSView* contentView;
@property (nonatomic) NSView* panelView;
@property (nonatomic) BOOL adjustingLayout;
@property (nonatomic) NSLayoutConstraint* minimumWidthConstraint;
@property (nonatomic) NSLayoutConstraint* minimumHeightConstraint;
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
		_minimumWidthConstraint = [_splitView.widthAnchor constraintGreaterThanOrEqualToConstant:0];
		_minimumHeightConstraint = [_splitView.heightAnchor constraintGreaterThanOrEqualToConstant:0];
		[NSLayoutConstraint activateConstraints:@[ _minimumWidthConstraint, _minimumHeightConstraint ]];

		NSBox* panel = [[NSBox alloc] initWithFrame:NSZeroRect];
		panel.boxType = NSBoxCustom;
		panel.borderWidth = 0;
		panel.fillColor = NSColor.windowBackgroundColor;
		panel.contentViewMargins = NSZeroSize;
		panel.accessibilityLabel = @"Terminal Panel";
		_panelView = panel;
		[self rebuildLayout];
	}
	return self;
}

- (void)startTerminalInDirectory:(NSString*)directory
{
	if(!_terminalController)
	{
		_terminalController = [[OakTerminalPanelController alloc] init];
		[_panelView removeFromSuperview];
		_panelView = _terminalController.view;
		[self rebuildLayout];
	}
	if(_terminalColors)
		[_terminalController applyThemeWithBackground:_terminalColors[0] foreground:_terminalColors[1] caret:_terminalColors[2] selection:_terminalColors[3]];
	[_terminalController startSessionInDirectory:directory ?: NSHomeDirectory()];
}

- (void)applyTerminalBackground:(NSColor*)background foreground:(NSColor*)foreground caret:(NSColor*)caret selection:(NSColor*)selection
{
	self.terminalColors = @[ background, foreground, caret, selection ];
	[_terminalController applyThemeWithBackground:background foreground:foreground caret:caret selection:selection];
}

- (void)focusTerminal { [_terminalController focusTerminal]; }
- (BOOL)confirmTerminalClose { return !_terminalController || [_terminalController confirmClose]; }
- (void)stopTerminal { [_terminalController stopSession]; }

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
	if(_adjustingLayout)
		return;
	_adjustingLayout = YES;
	NSSize minimum = _contentView.fittingSize;
	CGFloat divider = _panelVisible ? _splitView.dividerThickness : 0;
	// Expose the existing layout's required minimum to the window's layout engine.
	_minimumWidthConstraint.constant = minimum.width + (_splitView.isVertical ? divider : 0);
	_minimumHeightConstraint.constant = minimum.height + (_splitView.isVertical ? 0 : divider);
	NSRect bounds = _splitView.bounds;
	// A resize can reach this delegate before Auto Layout applies the new minimum.
	bounds.size.width = MAX(bounds.size.width, _minimumWidthConstraint.constant);
	bounds.size.height = MAX(bounds.size.height, _minimumHeightConstraint.constant);
	if(!_panelVisible)
		_contentView.frame = bounds;
	else
	{
		BOOL vertical = _splitView.isVertical;
		CGFloat available = MAX(0, (vertical ? NSWidth(bounds) : NSHeight(bounds)) - _splitView.dividerThickness);
		// Preserve the preferred size when a small window temporarily compresses the panel.
		CGFloat contentMinimum = vertical ? MAX(240, minimum.width) : MAX(120, minimum.height);
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
	NSSize minimum = _contentView.fittingSize;
	CGFloat contentMinimum = MIN(splitView.isVertical ? MAX(240, minimum.width) : MAX(120, minimum.height), available);
	panelMinimum = MIN(panelMinimum, MAX(0, available - contentMinimum));
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
