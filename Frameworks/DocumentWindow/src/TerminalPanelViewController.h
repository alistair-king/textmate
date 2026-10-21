#import <Cocoa/Cocoa.h>

// Last-used panel geometry, shared by all windows like the file browser's placement/width.
extern NSString* const kUserDefaultsTerminalPanelPlacementKey;
extern NSString* const kUserDefaultsTerminalPanelWidthKey;
extern NSString* const kUserDefaultsTerminalPanelHeightKey;

// Hosts the existing project layout alongside an independently docked terminal panel.
@interface TerminalPanelViewController : NSViewController
@property (nonatomic) BOOL panelVisible;
@property (nonatomic, copy) NSString* panelPosition; // left, right, bottom
@property (nonatomic) CGFloat panelWidth;
@property (nonatomic) CGFloat panelHeight;
- (void)startTerminalInDirectory:(NSString*)directory;
- (void)focusTerminal;
- (void)applyTerminalBackground:(NSColor*)background foreground:(NSColor*)foreground caret:(NSColor*)caret selection:(NSColor*)selection;
- (BOOL)confirmTerminalClose;
- (void)stopTerminal;
- (instancetype)initWithContentView:(NSView*)contentView;
@end
