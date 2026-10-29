#import "TerminalPanelViewController.h"
#import "TerminalTabBarController.h"
#if HAVE_OAK_SWIFTUI
	#import "OakSwiftUI-Swift.h"
#endif

NSString* const kUserDefaultsTerminalPanelPlacementKey = @"terminalPanelPlacement";
NSString* const kTerminalPanelPositionLeft   = @"left";
NSString* const kTerminalPanelPositionRight  = @"right";
NSString* const kTerminalPanelPositionBottom = @"bottom";
static NSString* const kUserDefaultsTerminalPanelWidthKey  = @"terminalPanelWidth";
static NSString* const kUserDefaultsTerminalPanelHeightKey = @"terminalPanelHeight";

static CGFloat const kDefaultPanelWidth  = 320;
static CGFloat const kDefaultPanelHeight = 220;
static CGFloat const kMinimumPanelWidth  = 120;
static CGFloat const kMinimumPanelHeight = 100;
static CGFloat const kMinimumContentWidth  = 240;
static CGFloat const kMinimumContentHeight = 120;

static BOOL IsPanelPosition (NSString* position)
{
	return [@[ kTerminalPanelPositionLeft, kTerminalPanelPositionRight, kTerminalPanelPositionBottom ] containsObject:position];
}

@interface TerminalPanelSplitView : NSSplitView
@property (nonatomic) BOOL trackingDivider;
@property (nonatomic, copy) void (^didFinishTrackingDivider)(void);
@end

@implementation TerminalPanelSplitView
- (void)mouseDown:(NSEvent*)event
{
	self.trackingDivider = YES;
	[super mouseDown:event];
	self.trackingDivider = NO;
	if(self.didFinishTrackingDivider)
		self.didFinishTrackingDivider();
}
@end

#if HAVE_OAK_SWIFTUI
@interface TerminalPanelViewController () <NSSplitViewDelegate, OakTerminalPanelControllerDelegate>
#else
@interface TerminalPanelViewController () <NSSplitViewDelegate>
#endif
@property (nonatomic) TerminalPanelSplitView* splitView;
#if HAVE_OAK_SWIFTUI
@property (nonatomic) OakTerminalPanelController* terminalController;
@property (nonatomic) TerminalTabBarController* terminalTabBarController;
#endif
#if HAVE_OAK_SWIFTUI
@property (nonatomic) OakTerminalTheme* terminalTheme;
#endif
@property (nonatomic) NSFont* terminalFont;
@property (nonatomic) NSView* contentView;
@property (nonatomic) NSView* panelView;
@property (nonatomic) BOOL adjustingLayout;
@property (nonatomic) NSLayoutConstraint* minimumWidthConstraint;
@property (nonatomic) NSLayoutConstraint* minimumHeightConstraint;
@end

@implementation TerminalPanelViewController
+ (void)initialize
{
	[NSUserDefaults.standardUserDefaults registerDefaults:@{
		kUserDefaultsTerminalPanelPlacementKey: kTerminalPanelPositionBottom,
		kUserDefaultsTerminalPanelWidthKey:     @(kDefaultPanelWidth),
		kUserDefaultsTerminalPanelHeightKey:    @(kDefaultPanelHeight),
	}];
}

- (instancetype)initWithContentView:(NSView*)contentView
{
	if(self = [super initWithNibName:nil bundle:nil])
	{
		_contentView = contentView;
		NSString* placement = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsTerminalPanelPlacementKey];
		_panelPosition = IsPanelPosition(placement) ? placement : kTerminalPanelPositionBottom;
		_panelWidth    = MAX(kMinimumPanelWidth, [NSUserDefaults.standardUserDefaults doubleForKey:kUserDefaultsTerminalPanelWidthKey]);
		_panelHeight   = MAX(kMinimumPanelHeight, [NSUserDefaults.standardUserDefaults doubleForKey:kUserDefaultsTerminalPanelHeightKey]);
		_splitView = [[TerminalPanelSplitView alloc] initWithFrame:NSZeroRect];
		_splitView.dividerStyle = NSSplitViewDividerStyleThin;
		_splitView.delegate = self;
		__weak TerminalPanelViewController* weakSelf = self;
		_splitView.didFinishTrackingDivider = ^{
			// Persist once per drag; the resize delegate fires for every pixel.
			NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
			[defaults setDouble:weakSelf.panelWidth forKey:kUserDefaultsTerminalPanelWidthKey];
			[defaults setDouble:weakSelf.panelHeight forKey:kUserDefaultsTerminalPanelHeightKey];
		};
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

- (void)prepareTerminalController
{
#if HAVE_OAK_SWIFTUI
	if(!_terminalController)
	{
		_terminalController = [[OakTerminalPanelController alloc] init];
		_terminalTabBarController = [[TerminalTabBarController alloc] initWithTerminalController:_terminalController];
		__weak TerminalPanelViewController* weakSelf = self;
		_terminalTabBarController.detachSessionHandler = ^(NSUUID* identifier){
			if(weakSelf.detachSessionHandler) weakSelf.detachSessionHandler(identifier);
		};
		_terminalController.shellPath = self.terminalShellPath;
		_terminalController.shellArguments = self.terminalShellArguments;
		_terminalController.delegate = self;
		[_panelView removeFromSuperview];
		_panelView = _terminalController.view;
		[self rebuildLayout];
	}
	if(_terminalFont)
		[_terminalController applyFont:_terminalFont];
	if(_terminalTheme)
		[_terminalController applyTheme:_terminalTheme];
#endif
}

#if HAVE_OAK_SWIFTUI
- (void)terminalPanel:(OakTerminalPanelController*)panel openFile:(NSURL*)url line:(NSInteger)line column:(NSInteger)column
{
	if(self.openTerminalFile)
		self.openTerminalFile(url, line, column);
}

- (NSString*)terminalPanelWorkingDirectory:(OakTerminalPanelController*)panel
{
	return self.terminalDirectoryProvider ? self.terminalDirectoryProvider() : nil;
}

- (NSDictionary<NSString*, NSString*>*)terminalPanel:(OakTerminalPanelController*)panel environmentForDirectory:(NSString*)directory
{
	return self.terminalEnvironmentProvider ? self.terminalEnvironmentProvider(directory) : NSProcessInfo.processInfo.environment;
}

- (void)terminalPanelDidCloseLastSession:(OakTerminalPanelController*)panel
{
	if(self.lastSessionClosedHandler)
		self.lastSessionClosedHandler();
}
#endif

- (BOOL)hasTerminal
{
#if HAVE_OAK_SWIFTUI
	return _terminalController != nil;
#else
	return NO;
#endif
}

- (NSArray<NSUUID*>*)terminalSessionIdentifiers
{
#if HAVE_OAK_SWIFTUI
	return _terminalController.sessionIdentifiers ?: @[ ];
#else
	return @[ ];
#endif
}

- (void)closeTerminalSessions:(NSArray<NSUUID*>*)identifiers
{
#if HAVE_OAK_SWIFTUI
	[_terminalController closeSessionsWithIdentifiers:identifiers];
#endif
}

- (void)startTerminal
{
#if HAVE_OAK_SWIFTUI
	[self prepareTerminalController];
	[_terminalController startSession];
#endif
}

- (void)takeTerminalSession:(NSUUID*)identifier fromPanel:(TerminalPanelViewController*)source
{
#if HAVE_OAK_SWIFTUI
	[self prepareTerminalController];
	[source.terminalController transferSessionWithIdentifier:identifier to:self.terminalController at:self.terminalController.sessionIdentifiers.count];
#endif
}

- (void)takePlacementFromPanel:(TerminalPanelViewController*)source
{
	self.panelPosition = source.panelPosition;
	self.panelWidth    = source.panelWidth;
	self.panelHeight   = source.panelHeight;
}

- (void)applyTerminalBackground:(NSColor*)background foreground:(NSColor*)foreground caret:(NSColor*)caret selection:(NSColor*)selection
{
#if HAVE_OAK_SWIFTUI
	self.terminalTheme = [[OakTerminalTheme alloc] initWithBackground:background foreground:foreground caret:caret selection:selection];
	[_terminalController applyTheme:self.terminalTheme];
#endif
}

- (void)applyTerminalFont:(NSFont*)font
{
	self.terminalFont = font;
#if HAVE_OAK_SWIFTUI
	[_terminalController applyFont:font];
#endif
}

- (void)focusTerminal
{
#if HAVE_OAK_SWIFTUI
	[_terminalController focusTerminal];
#endif
}

- (BOOL)terminalHasRunningWork
{
#if HAVE_OAK_SWIFTUI
	return _terminalController.hasRunningWork;
#else
	return NO;
#endif
}

- (void)confirmTerminalCloseInWindow:(NSWindow*)window completionHandler:(void(^)(BOOL canClose))callback
{
#if HAVE_OAK_SWIFTUI
	if(_terminalController)
		return [_terminalController confirmCloseIn:window completion:callback];
#endif
	callback(YES);
}

- (void)stopTerminal
{
#if HAVE_OAK_SWIFTUI
	[_terminalController stopSession];
#endif
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
	if(!IsPanelPosition(position) || [_panelPosition isEqualToString:position])
		return;
	_panelPosition = [position copy];
	[self rebuildLayout];
}

- (void)setPanelWidth:(CGFloat)width
{
	_panelWidth = isfinite(width) ? MAX(kMinimumPanelWidth, width) : kDefaultPanelWidth;
	[self layoutPanels];
}

- (void)setPanelHeight:(CGFloat)height
{
	_panelHeight = isfinite(height) ? MAX(kMinimumPanelHeight, height) : kDefaultPanelHeight;
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
	_splitView.vertical = ![_panelPosition isEqualToString:kTerminalPanelPositionBottom];
	if(_panelVisible && [_panelPosition isEqualToString:kTerminalPanelPositionLeft])
		[_splitView addSubview:_panelView];
	[_splitView addSubview:_contentView];
	if(_panelVisible && ![_panelPosition isEqualToString:kTerminalPanelPositionLeft])
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
		CGFloat contentMinimum = vertical ? MAX(kMinimumContentWidth, minimum.width) : MAX(kMinimumContentHeight, minimum.height);
		CGFloat size = MIN(vertical ? _panelWidth : _panelHeight, MAX(0, available - contentMinimum));
		CGFloat firstSize = [_panelPosition isEqualToString:kTerminalPanelPositionLeft] ? size : available - size;
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
	CGFloat panelMinimum = MIN(splitView.isVertical ? kMinimumPanelWidth : kMinimumPanelHeight, available / 2);
	NSSize minimum = _contentView.fittingSize;
	CGFloat contentMinimum = MIN(splitView.isVertical ? MAX(kMinimumContentWidth, minimum.width) : MAX(kMinimumContentHeight, minimum.height), available);
	panelMinimum = MIN(panelMinimum, MAX(0, available - contentMinimum));
	BOOL panelFirst = [_panelPosition isEqualToString:kTerminalPanelPositionLeft];
	return MAX(panelFirst ? panelMinimum : contentMinimum, MIN(position, available - (panelFirst ? contentMinimum : panelMinimum)));
}

- (void)splitViewDidResizeSubviews:(NSNotification*)notification
{
	if(!_adjustingLayout && _panelVisible && _splitView.trackingDivider)
	{
		if(_splitView.isVertical)
		{
			_panelWidth = NSWidth(_panelView.frame);
		}
		else
		{
			_panelHeight = NSHeight(_panelView.frame);
		}
	}
}
@end
