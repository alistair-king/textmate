#import <Cocoa/Cocoa.h>

// Last-used panel edge, seeding new windows like the file browser's placement/width.
extern NSString* const kUserDefaultsTerminalPanelPlacementKey;

// Hosts the existing project layout alongside an independently docked terminal panel.
@interface TerminalPanelViewController : NSViewController
@property (nonatomic) BOOL panelVisible;
@property (nonatomic, copy) NSString* (^terminalDirectoryProvider)(void);
@property (nonatomic, copy) NSDictionary<NSString*, NSString*>* (^terminalEnvironmentProvider)(NSString* directory); // base environment for new shells
@property (nonatomic, copy) NSString* panelPosition; // left, right, bottom
@property (nonatomic) CGFloat panelWidth;
@property (nonatomic) CGFloat panelHeight;
- (void)takeTerminalSession:(NSUUID*)identifier fromPanel:(TerminalPanelViewController*)source;
// Placement precedence: user defaults seed new windows, saved session state overrides them on restore, and a detached window copies its source panel.
- (void)takePlacementFromPanel:(TerminalPanelViewController*)source;
@property (nonatomic, copy) void (^detachSessionHandler)(NSUUID*);
@property (nonatomic, copy) void (^lastSessionClosedHandler)(void); // not called when sessions are moved out or the panel is stopped
@property (nonatomic, copy) void (^openTerminalFile)(NSURL*, NSInteger, NSInteger);
@property (nonatomic, copy) NSString* terminalShellPath;                // overrides the account's login shell; for tests
@property (nonatomic, copy) NSArray<NSString*>* terminalShellArguments; // used with terminalShellPath
@property (nonatomic, readonly) NSArray<NSUUID*>* terminalSessionIdentifiers;
- (void)closeTerminalSessions:(NSArray<NSUUID*>*)identifiers; // asks for confirmation when work is running
@property (nonatomic, readonly) BOOL hasTerminal; // YES once a shell has been started or received
- (void)startTerminalInDirectory:(NSString*)directory;
- (void)focusTerminal;
- (void)applyTerminalFont:(NSFont*)font;
- (void)applyTerminalBackground:(NSColor*)background foreground:(NSColor*)foreground caret:(NSColor*)caret selection:(NSColor*)selection;
@property (nonatomic, readonly) BOOL terminalHasRunningWork; // a session is running a foreground program
- (void)confirmTerminalCloseInWindow:(NSWindow*)window completionHandler:(void(^)(BOOL canClose))callback; // sheet on window; immediate when idle
- (void)stopTerminal;
- (instancetype)initWithContentView:(NSView*)contentView;
@end
