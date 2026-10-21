#import <Cocoa/Cocoa.h>

// Hosts the existing project layout alongside an independently docked AI panel.
@interface AIPanelViewController : NSViewController
@property (nonatomic) BOOL panelVisible;
@property (nonatomic, copy) NSString* panelPosition; // left, right, bottom
@property (nonatomic) CGFloat panelWidth;
@property (nonatomic) CGFloat panelHeight;
- (instancetype)initWithContentView:(NSView*)contentView;
@end
