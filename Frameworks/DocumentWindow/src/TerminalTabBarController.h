#import <Cocoa/Cocoa.h>
@class OakTabBarView, OakTerminalPanelController;

@interface TerminalTabBarController : NSObject
@property (nonatomic, copy) void (^detachSessionHandler)(NSUUID*);
@property (nonatomic, readonly) OakTabBarView* tabBar;
- (instancetype)initWithTerminalController:(OakTerminalPanelController*)controller;
@end
