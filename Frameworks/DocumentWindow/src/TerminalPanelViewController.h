#import <Cocoa/Cocoa.h>

// Last-used panel geometry, shared by all windows like the file browser's placement/width.
extern NSString* const kUserDefaultsTerminalPanelPlacementKey;
extern NSString* const kUserDefaultsTerminalPanelWidthKey;
extern NSString* const kUserDefaultsTerminalPanelHeightKey;

// Hosts the existing project layout alongside an independently docked terminal panel.
@interface TerminalPanelViewController : NSViewController
@property (nonatomic) BOOL panelVisible;
@property (nonatomic, copy) NSString* (^terminalDirectoryProvider)(void);
@property (nonatomic, copy) NSString* panelPosition; // left, right, bottom
@property (nonatomic) CGFloat panelWidth;
@property (nonatomic) CGFloat panelHeight;
- (void)takeTerminalSession:(NSUUID*)identifier fromPanel:(TerminalPanelViewController*)source;
// Placement precedence: user defaults seed new windows, saved session state overrides them on restore, and a detached window copies its source panel.
- (void)takePlacementFromPanel:(TerminalPanelViewController*)source;
@property (nonatomic, copy) void (^detachSessionHandler)(NSUUID*);
@property (nonatomic, copy) void (^lastSessionClosedHandler)(void); // not called when sessions are moved out or the panel is stopped
@property (nonatomic, copy) void (^openTerminalFile)(NSURL*, NSInteger, NSInteger);
- (void)startTerminalInDirectory:(NSString*)directory;
- (void)focusTerminal;
- (void)applyTerminalFont:(NSFont*)font;
- (void)applyTerminalBackground:(NSColor*)background foreground:(NSColor*)foreground caret:(NSColor*)caret selection:(NSColor*)selection;
- (BOOL)confirmTerminalClose;
- (void)stopTerminal;
- (instancetype)initWithContentView:(NSView*)contentView;
@end
