#import "CompareWindowController.h"

static NSTextField* Label (NSString* text, NSFont* font, NSColor* color)
{
	NSTextField* label = [NSTextField labelWithString:text];
	label.font = font;
	label.textColor = color;
	label.lineBreakMode = NSLineBreakByTruncatingMiddle;
	label.cell.truncatesLastVisibleLine = YES;
	[label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	return label;
}

// Header and (from phase 1) file tree for one side of the comparison.
static NSView* SidePane (NSString* path)
{
	NSTextField* name = Label(path.lastPathComponent, [NSFont boldSystemFontOfSize:NSFont.systemFontSize], NSColor.labelColor);
	NSTextField* location = Label(path.stringByAbbreviatingWithTildeInPath, [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.secondaryLabelColor);
	location.toolTip = path;

	NSStackView* header = [NSStackView stackViewWithViews:@[ name, location ]];
	header.orientation = NSUserInterfaceLayoutOrientationVertical;
	header.alignment   = NSLayoutAttributeLeading;
	header.spacing     = 2;
	header.edgeInsets  = NSEdgeInsetsMake(8, 10, 8, 10);

	NSBox* divider = [NSBox new];
	divider.boxType = NSBoxSeparator;

	NSView* content = [NSView new];

	NSStackView* pane = [NSStackView stackViewWithViews:@[ header, divider, content ]];
	pane.orientation  = NSUserInterfaceLayoutOrientationVertical;
	pane.alignment    = NSLayoutAttributeWidth;
	pane.spacing      = 0;
	pane.distribution = NSStackViewDistributionFill;
	[content setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1 forOrientation:NSLayoutConstraintOrientationVertical];
	return pane;
}

@implementation CompareWindowController
- (instancetype)initWithLeftPath:(NSString*)left rightPath:(NSString*)right focus:(NSString*)focus
{
	NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 600) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
	if(self = [super initWithWindow:window])
	{
		_leftPath  = [left copy];
		_rightPath = [right copy];
		_focus     = [focus copy];

		window.title              = [NSString stringWithFormat:@"%@ ⇄ %@", left.lastPathComponent, right.lastPathComponent];
		window.subtitle           = left.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath;
		window.minSize            = NSMakeSize(500, 300);
		window.releasedWhenClosed = NO;
		window.delegate           = self;
		window.tabbingMode        = NSWindowTabbingModeDisallowed;

		NSSplitView* split = [NSSplitView new];
		split.vertical     = YES;
		split.dividerStyle = NSSplitViewDividerStyleThin;
		[split addArrangedSubview:SidePane(left)];
		[split addArrangedSubview:SidePane(right)];
		window.contentView = split;

		[window center];
		[window setFrameAutosaveName:@"CompareWindow"];
		[split layoutSubtreeIfNeeded];
		[split setPosition:NSWidth(split.bounds) / 2 ofDividerAtIndex:0];
	}
	return self;
}
@end
