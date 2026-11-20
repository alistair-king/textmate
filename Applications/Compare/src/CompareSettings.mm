#import "CompareSettings.h"

NSString* const CompareExcludedNamesDefaultsKey      = @"compareExcludedNames";
NSString* const CompareSettingsDidChangeNotification = @"CompareSettingsDidChangeNotification";

static NSToolbarItemIdentifier const kGeneralPaneIdentifier = @"general";

@implementation CompareSettings
+ (NSString*)defaultExcludedNames
{
	return @"node_modules";
}

// An empty list is a choice (show everything); only a missing value is the default.
+ (NSString*)excludedNames
{
	return [NSUserDefaults.standardUserDefaults stringForKey:CompareExcludedNamesDefaultsKey] ?: self.defaultExcludedNames;
}

+ (void)setExcludedNames:(NSString*)names
{
	names = names ?: @"";
	if([names isEqualToString:self.excludedNames])
		return;
	[NSUserDefaults.standardUserDefaults setObject:names forKey:CompareExcludedNamesDefaultsKey];
	[NSNotificationCenter.defaultCenter postNotificationName:CompareSettingsDidChangeNotification object:self];
}
@end

@interface CompareSettingsWindowController () <NSToolbarDelegate, NSTextFieldDelegate, NSWindowDelegate>
@end

@implementation CompareSettingsWindowController
+ (CompareSettingsWindowController*)sharedController
{
	static CompareSettingsWindowController* controller = [self new];
	return controller;
}

- (instancetype)init
{
	NSWindow* window = [[NSWindow alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:YES];
	if(self = [super initWithWindow:window])
	{
		window.title = @"General";
		window.releasedWhenClosed = NO;
		window.delegate = self;
		window.toolbarStyle = NSWindowToolbarStylePreference;

		NSToolbar* toolbar = [[NSToolbar alloc] initWithIdentifier:@"CompareSettings"];
		toolbar.delegate = self;
		toolbar.displayMode = NSToolbarDisplayModeIconAndLabel;
		toolbar.allowsUserCustomization = NO;
		window.toolbar = toolbar;
		toolbar.selectedItemIdentifier = kGeneralPaneIdentifier;

		window.contentView = [self makeGeneralPane];
		[window center];
		[window setFrameAutosaveName:@"CompareSettings"];
	}
	return self;
}

- (NSView*)makeGeneralPane
{
	NSTextField* label = [NSTextField labelWithString:@"Ignore folders and files:"];
	label.alignment = NSTextAlignmentRight;

	_excludedNamesField = [NSTextField textFieldWithString:CompareSettings.excludedNames];
	_excludedNamesField.placeholderString = @"node_modules, *.log, docs/build";
	_excludedNamesField.delegate = self;
	_excludedNamesField.target = self;
	_excludedNamesField.action = @selector(takeExcludedNamesFrom:);
	_excludedNamesField.accessibilityLabel = @"Ignore folders and files";
	[_excludedNamesField.widthAnchor constraintGreaterThanOrEqualToConstant:320].active = YES;

	NSTextField* help = [NSTextField wrappingLabelWithString:@"Comma-separated names of folders and files that never appear in a comparison, on either side, together with everything inside them. Wildcards: * ? [abc]. A name with a slash, such as docs/build, matches a path from the top of the compared folders. Case is ignored."];
	help.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	help.textColor = NSColor.secondaryLabelColor;
	help.preferredMaxLayoutWidth = 320;

	NSGridView* grid = [NSGridView gridViewWithViews:@[
		@[ label, _excludedNamesField ],
		@[ NSGridCell.emptyContentView, help ],
	]];
	grid.rowSpacing = 6;
	grid.columnSpacing = 8;
	[grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
	[grid rowAtIndex:0].rowAlignment = NSGridRowAlignmentFirstBaseline;
	grid.translatesAutoresizingMaskIntoConstraints = NO;

	NSView* pane = [NSView new];
	[pane addSubview:grid];
	[NSLayoutConstraint activateConstraints:@[
		[grid.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor constant:20],
		[grid.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor constant:-20],
		[grid.topAnchor constraintEqualToAnchor:pane.topAnchor constant:20],
		[grid.bottomAnchor constraintEqualToAnchor:pane.bottomAnchor constant:-20],
	]];
	return pane;
}

- (void)showWindow:(id)sender
{
	if(!self.window.isVisible)
		_excludedNamesField.stringValue = CompareSettings.excludedNames;
	[super showWindow:sender];
}

// ==========
// = Saving =
// ==========

- (void)takeExcludedNamesFrom:(NSTextField*)sender
{
	CompareSettings.excludedNames = sender.stringValue;
}

- (void)controlTextDidEndEditing:(NSNotification*)notification
{
	[self takeExcludedNamesFrom:_excludedNamesField];
}

- (void)commitEditing
{
	[self.window makeFirstResponder:nil]; // ends editing, which saves
	[self takeExcludedNamesFrom:_excludedNamesField];
}

- (void)windowWillClose:(NSNotification*)notification
{
	[self commitEditing];
}

// =============
// = Toolbar =
// =============

- (NSArray<NSToolbarItemIdentifier>*)toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar    { return @[ kGeneralPaneIdentifier ]; }
- (NSArray<NSToolbarItemIdentifier>*)toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar    { return @[ kGeneralPaneIdentifier ]; }
- (NSArray<NSToolbarItemIdentifier>*)toolbarSelectableItemIdentifiers:(NSToolbar*)toolbar { return @[ kGeneralPaneIdentifier ]; }

- (NSToolbarItem*)toolbar:(NSToolbar*)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier willBeInsertedIntoToolbar:(BOOL)flag
{
	NSToolbarItem* item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
	item.label  = @"General";
	item.image  = [NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:@"General"];
	item.target = self;
	item.action = @selector(selectPane:);
	return item;
}

- (void)selectPane:(NSToolbarItem*)sender
{
	self.window.title = sender.label;
}
@end
