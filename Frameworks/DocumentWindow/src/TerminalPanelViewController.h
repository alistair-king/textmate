#import <Cocoa/Cocoa.h>

// Last-used panel geometry, shared by all windows like the file browser's placement/width.
extern NSString* const kUserDefaultsTerminalPanelPlacementKey;
extern NSString* const kUserDefaultsTerminalPanelWidthKey;
extern NSString* const kUserDefaultsTerminalPanelHeightKey;

// Hosts the existing project layout alongside an independently docked terminal panel.
@interface TerminalPanelViewController : NSViewController
@property (nonatomic) BOOL panelVisible;
@property (nonatomic, copy) NSString* (^terminalDirectoryProvider)(void);
@property (nonatomic, copy) NSDictionary<NSString*, NSString*>* (^contextEnvironmentProvider)(NSUUID*);
@property (nonatomic, copy) void (^contextSessionClosed)(NSUUID*);
@property (nonatomic, copy) NSString* panelPosition; // left, right, bottom
@property (nonatomic) CGFloat panelWidth;
@property (nonatomic) CGFloat panelHeight;
- (void)takeTerminalSession:(NSUUID*)identifier fromPanel:(TerminalPanelViewController*)source;
@property (nonatomic, copy) void (^detachSessionHandler)(NSUUID*);
@property (nonatomic, copy) void (^openTerminalFile)(NSURL*, NSInteger, NSInteger);
- (void)startTerminalInDirectory:(NSString*)directory;
- (BOOL)startCommand:(NSString*)executable arguments:(NSArray<NSString*>*)arguments title:(NSString*)title inDirectory:(NSString*)directory;
- (void)focusTerminal;
- (void)applyTerminalFont:(NSFont*)font;
- (void)applyTerminalBackground:(NSColor*)background foreground:(NSColor*)foreground caret:(NSColor*)caret selection:(NSColor*)selection syntaxColors:(NSArray<NSColor*>*)syntaxColors;
- (BOOL)confirmTerminalClose;
- (void)stopTerminal;
- (instancetype)initWithContentView:(NSView*)contentView;
@end
