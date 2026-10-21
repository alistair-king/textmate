#import <Cocoa/Cocoa.h>

// Hosts the existing project layout alongside an independently docked terminal panel.
@interface AIPanelViewController : NSViewController
@property (nonatomic) BOOL panelVisible;
@property (nonatomic, copy) NSString* panelPosition; // left, right, bottom
@property (nonatomic) CGFloat panelWidth;
@property (nonatomic) CGFloat panelHeight;
- (void)startTerminalInDirectory:(NSString*)directory;
- (void)focusTerminal;
- (BOOL)confirmTerminalClose;
- (void)stopTerminal;
- (instancetype)initWithContentView:(NSView*)contentView;
@end
