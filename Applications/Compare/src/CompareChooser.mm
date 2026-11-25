#import "CompareChooser.h"

static BOOL IsFolder (NSString* path)
{
	BOOL folder = NO;
	return path && [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&folder] && folder;
}

// ================
// = One side’s card =
// ================

// A rounded card for one side: the chosen item's icon, name and path, and a
// Choose… button. The whole card takes a dropped folder or file. Empty, it
// has a dashed outline and says what to do.
@interface CompareChooserCard : NSView
- (instancetype)initWithSide:(NSString*)side;
@property (nonatomic, copy) NSString* path;
@property (nonatomic, readonly) NSButton* chooseButton;
@property (nonatomic, copy) void (^pathChanged)(NSString* path); // a drop
@end

@implementation CompareChooserCard
{
	NSImageView* _iconView;
	NSTextField* _nameLabel;
	NSTextField* _pathLabel;
	BOOL _dropTarget;
}

- (instancetype)initWithSide:(NSString*)side
{
	if(self = [super initWithFrame:NSZeroRect])
	{
		[self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
		self.accessibilityLabel = [side stringByAppendingString:@" folder or file"];

		_iconView = [NSImageView imageViewWithImage:[NSImage new]];
		_iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
		[_iconView.widthAnchor constraintEqualToConstant:56].active = YES;
		[_iconView.heightAnchor constraintEqualToConstant:56].active = YES;

		_nameLabel = [NSTextField labelWithString:@""];
		_nameLabel.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
		_nameLabel.alignment = NSTextAlignmentCenter;
		_nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

		_pathLabel = [NSTextField labelWithString:@""];
		_pathLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
		_pathLabel.textColor = NSColor.secondaryLabelColor;
		_pathLabel.alignment = NSTextAlignmentCenter;
		_pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

		for(NSTextField* label in @[ _nameLabel, _pathLabel ])
			[label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

		_chooseButton = [NSButton buttonWithTitle:@"Choose…" target:nil action:NULL];
		_chooseButton.controlSize = NSControlSizeRegular;
		_chooseButton.accessibilityLabel = [NSString stringWithFormat:@"Choose %@", side.lowercaseString];

		NSStackView* stack = [NSStackView stackViewWithViews:@[ _iconView, _nameLabel, _pathLabel, _chooseButton ]];
		stack.orientation = NSUserInterfaceLayoutOrientationVertical;
		stack.alignment   = NSLayoutAttributeCenterX;
		stack.spacing     = 4;
		[stack setCustomSpacing:10 afterView:_iconView];
		[stack setCustomSpacing:14 afterView:_pathLabel];
		stack.translatesAutoresizingMaskIntoConstraints = NO;
		[self addSubview:stack];
		[NSLayoutConstraint activateConstraints:@[
			[stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:18],
			[stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16],
			[stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
			[stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
			[_nameLabel.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor],
			[_pathLabel.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor],
		]];
		[self update];
	}
	return self;
}

- (void)setPath:(NSString*)path
{
	_path = [path copy];
	[self update];
}

- (void)update
{
	if(_path)
	{
		_iconView.image = [NSWorkspace.sharedWorkspace iconForFile:_path];
		_iconView.contentTintColor = nil;
		_nameLabel.stringValue = [NSFileManager.defaultManager displayNameAtPath:_path];
		_nameLabel.textColor   = NSColor.labelColor;
		_pathLabel.stringValue = _path.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath;
		_pathLabel.toolTip     = _path;
	}
	else
	{
		NSImageSymbolConfiguration* configuration = [NSImageSymbolConfiguration configurationWithPointSize:30 weight:NSFontWeightLight];
		_iconView.image = [[NSImage imageWithSystemSymbolName:@"plus.rectangle.on.folder" accessibilityDescription:nil] imageWithSymbolConfiguration:configuration];
		_iconView.contentTintColor = NSColor.tertiaryLabelColor;
		_nameLabel.stringValue = @"No folder or file";
		_nameLabel.textColor   = NSColor.secondaryLabelColor;
		_pathLabel.stringValue = @"Drop one here, or choose it";
		_pathLabel.toolTip     = nil;
	}
	self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
	NSRect rect = NSInsetRect(self.bounds, 1, 1);
	NSBezierPath* card = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:10 yRadius:10];
	[(_dropTarget ? [NSColor.controlAccentColor colorWithAlphaComponent:0.12] : NSColor.controlBackgroundColor) setFill];
	[card fill];

	card.lineWidth = _dropTarget ? 2 : 1;
	if(!_path && !_dropTarget)
	{
		CGFloat dash[] = { 5, 4 };
		[card setLineDash:dash count:2 phase:0];
		[NSColor.tertiaryLabelColor setStroke];
	}
	else
	{
		[(_dropTarget ? NSColor.controlAccentColor : NSColor.separatorColor) setStroke];
	}
	[card stroke];
}

// ==================
// = Drag and drop =
// ==================

- (NSString*)droppedPath:(id<NSDraggingInfo>)info
{
	NSArray<NSURL*>* urls = [info.draggingPasteboard readObjectsForClasses:@[ NSURL.class ] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
	return urls.count == 1 ? urls.firstObject.path.stringByStandardizingPath : nil;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info
{
	_dropTarget = [self droppedPath:info] != nil;
	self.needsDisplay = YES;
	return _dropTarget ? NSDragOperationCopy : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)info
{
	_dropTarget = NO;
	self.needsDisplay = YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
{
	_dropTarget = NO;
	NSString* path = [self droppedPath:info];
	if(!path)
		return NO;
	self.path = path;
	if(_pathChanged)
		_pathChanged(path);
	return YES;
}
@end

// ======================
// = The chooser window =
// ======================

@interface CompareChooserWindowController () <NSWindowDelegate>
@end

@implementation CompareChooserWindowController
{
	CompareChooserCard* _cards[2];
	NSImageView* _problemIcon;
	NSTextField* _problemLabel;
}

static NSTextField* Caption (NSString* text)
{
	NSTextField* caption = [NSTextField labelWithString:text.uppercaseString];
	caption.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold];
	caption.textColor = NSColor.secondaryLabelColor;
	return caption;
}

- (instancetype)init
{
	NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 10) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:YES];
	if(self = [super initWithWindow:window])
	{
		window.title                      = @"New Comparison";
		window.titleVisibility            = NSWindowTitleHidden; // the header says it
		window.titlebarAppearsTransparent = YES;
		window.releasedWhenClosed         = NO;
		window.delegate                   = self;

		// Header: the app's icon, a title and what to do.
		NSImageView* appIcon = [NSImageView imageViewWithImage:NSApp.applicationIconImage ?: [NSImage imageNamed:NSImageNameApplicationIcon]];
		[appIcon.widthAnchor constraintEqualToConstant:64].active = YES;
		[appIcon.heightAnchor constraintEqualToConstant:64].active = YES;
		NSTextField* title = [NSTextField labelWithString:@"New Comparison"];
		title.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
		NSTextField* subtitle = [NSTextField wrappingLabelWithString:@"Choose two folders or two files to compare side by side."];
		subtitle.textColor = NSColor.secondaryLabelColor;
		NSStackView* titles = [NSStackView stackViewWithViews:@[ title, subtitle ]];
		titles.orientation = NSUserInterfaceLayoutOrientationVertical;
		titles.alignment   = NSLayoutAttributeLeading;
		titles.spacing     = 4;
		NSStackView* header = [NSStackView stackViewWithViews:@[ appIcon, titles ]];
		header.spacing   = 16;
		header.alignment = NSLayoutAttributeCenterY;

		// The two sides, with a swap button between them.
		NSMutableArray<NSView*>* columns = [NSMutableArray array];
		for(size_t i = 0; i < 2; ++i)
		{
			NSString* side = i == 0 ? @"Left" : @"Right";
			CompareChooserCard* card = [[CompareChooserCard alloc] initWithSide:side];
			card.chooseButton.target = self;
			card.chooseButton.action = @selector(choose:);
			card.chooseButton.tag    = i;
			__weak CompareChooserWindowController* weakSelf = self;
			card.pathChanged = ^(NSString* path){ [weakSelf update]; };
			_cards[i] = card;

			NSStackView* column = [NSStackView stackViewWithViews:@[ Caption(side), card ]];
			column.orientation = NSUserInterfaceLayoutOrientationVertical;
			column.alignment   = NSLayoutAttributeLeading;
			column.spacing     = 6;
			[card.widthAnchor constraintEqualToAnchor:column.widthAnchor].active = YES;
			[columns addObject:column];
		}

		NSButton* swap = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.left.arrow.right" accessibilityDescription:@"Swap Left and Right"] target:self action:@selector(swapSides:)];
		swap.bordered = NO;
		swap.toolTip  = @"Swap Left and Right";
		swap.contentTintColor = NSColor.secondaryLabelColor;
		[swap setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

		NSStackView* sides = [NSStackView stackViewWithViews:@[ columns[0], swap, columns[1] ]];
		sides.spacing   = 12;
		sides.alignment = NSLayoutAttributeCenterY;
		sides.distribution = NSStackViewDistributionFill;
		[columns[0].widthAnchor constraintEqualToAnchor:columns[1].widthAnchor].active = YES;
		[_cards[0].heightAnchor constraintEqualToAnchor:_cards[1].heightAnchor].active = YES;

		// Footer: what is missing or wrong, and the buttons.
		_problemIcon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"exclamationmark.triangle.fill" accessibilityDescription:@"Problem"]];
		_problemIcon.contentTintColor = NSColor.systemOrangeColor;
		_problemLabel = [NSTextField wrappingLabelWithString:@""];
		_problemLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
		[_problemLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
		NSStackView* status = [NSStackView stackViewWithViews:@[ _problemIcon, _problemLabel ]];
		status.spacing = 6;
		status.alignment = NSLayoutAttributeFirstBaseline;

		NSButton* cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
		cancel.keyEquivalent = @"\e";
		_compareButton = [NSButton buttonWithTitle:@"Compare" target:self action:@selector(compare:)];
		_compareButton.keyEquivalent = @"\r";
		for(NSButton* button in @[ cancel, _compareButton ])
			[button.widthAnchor constraintGreaterThanOrEqualToConstant:88].active = YES;
		// The message on the leading side, the buttons always at the trailing edge.
		NSStackView* footer = [NSStackView new];
		footer.spacing = 12;
		[footer addView:status inGravity:NSStackViewGravityLeading];
		[footer addView:cancel inGravity:NSStackViewGravityTrailing];
		[footer addView:_compareButton inGravity:NSStackViewGravityTrailing];
		[footer setCustomSpacing:20 afterView:status];

		NSView* content = [NSView new];
		for(NSView* view in @[ header, sides, footer ])
		{
			view.translatesAutoresizingMaskIntoConstraints = NO;
			[content addSubview:view];
			[view.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:28].active = YES;
			[view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-28].active = YES;
		}
		[NSLayoutConstraint activateConstraints:@[
			[content.widthAnchor constraintEqualToConstant:620],
			[header.topAnchor constraintEqualToAnchor:content.topAnchor constant:36], // below the transparent title bar
			[sides.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:24],
			[_cards[0].heightAnchor constraintGreaterThanOrEqualToConstant:170],
			[footer.topAnchor constraintEqualToAnchor:sides.bottomAnchor constant:24],
			[footer.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24],
		]];
		window.contentView = content;
		[self update];
		[window center];
	}
	return self;
}

// ==================
// = Chosen paths =
// ==================

- (NSString*)leftPath                 { return _cards[0].path; }
- (NSString*)rightPath                { return _cards[1].path; }
- (void)setLeftPath:(NSString*)path   { _cards[0].path = path.stringByStandardizingPath; [self update]; }
- (void)setRightPath:(NSString*)path  { _cards[1].path = path.stringByStandardizingPath; [self update]; }

- (NSString*)problem
{
	NSString* left = self.leftPath, *right = self.rightPath;
	if(!left || !right)
		return @"Choose two folders, or two files.";
	for(NSString* path in @[ left, right ])
	{
		if(![NSFileManager.defaultManager fileExistsAtPath:path])
			return [NSString stringWithFormat:@"“%@” no longer exists.", path.lastPathComponent];
	}
	if(IsFolder(left) != IsFolder(right))
		return [NSString stringWithFormat:@"“%@” is a %@ and “%@” is a %@: choose two folders, or two files.", left.lastPathComponent, IsFolder(left) ? @"folder" : @"file", right.lastPathComponent, IsFolder(right) ? @"folder" : @"file"];
	if([left.stringByResolvingSymlinksInPath isEqualToString:right.stringByResolvingSymlinksInPath])
		return [NSString stringWithFormat:@"Both sides are “%@”: choose another %@ for one of them.", left.lastPathComponent, IsFolder(left) ? @"folder" : @"file"];
	return nil;
}

// Something still to choose is a hint; a pair that can't be compared is a problem.
- (void)update
{
	NSString* problem = self.problem;
	BOOL incomplete = !self.leftPath || !self.rightPath;
	_problemIcon.hidden = problem == nil || incomplete;
	_problemLabel.textColor = problem && !incomplete ? NSColor.labelColor : NSColor.secondaryLabelColor;
	_problemLabel.stringValue = problem ?: (IsFolder(self.leftPath) ? @"Two folders: their files are compared side by side." : @"Two files: their contents are compared side by side.");
	_compareButton.enabled = problem == nil;
}

// ===========
// = Actions =
// ===========

- (void)choose:(NSButton*)sender
{
	size_t index = sender.tag == 0 ? 0 : 1;
	NSOpenPanel* panel = [NSOpenPanel openPanel];
	panel.canChooseFiles          = YES;
	panel.canChooseDirectories    = YES;
	panel.allowsMultipleSelection = NO;
	panel.resolvesAliases         = YES;
	panel.prompt  = @"Choose";
	panel.message = index == 0 ? @"Choose the folder or file for the left side." : @"Choose the folder or file for the right side.";
	// Start next to what the other side has, often a sibling.
	if(NSString* other = _cards[1 - index].path ?: _cards[index].path)
		panel.directoryURL = [NSURL fileURLWithPath:other.stringByDeletingLastPathComponent isDirectory:YES];
	[panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result){
		if(result == NSModalResponseOK && panel.URL)
		{
			_cards[index].path = panel.URL.path.stringByStandardizingPath;
			[self update];
		}
	}];
}

- (IBAction)swapSides:(id)sender
{
	NSString* left = self.leftPath;
	_cards[0].path = self.rightPath;
	_cards[1].path = left;
	[self update];
}

- (IBAction)compare:(id)sender
{
	if(self.problem)
		return NSBeep();
	NSString* left = self.leftPath, *right = self.rightPath;
	// Open the comparison before closing, so the app never has no window.
	if(_compareHandler)
		_compareHandler(left, right);
	[self close];
}

- (void)cancel:(id)sender
{
	[self close];
}
@end
