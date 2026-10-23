#import <Cocoa/Cocoa.h>
#import <OakTabBarView/OakTabBarView.h>
#import "../src/TerminalPanelViewController.h"
void test_terminal_panel_layout ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
	@autoreleasepool {
  NSView* content = [[NSView alloc] initWithFrame:NSZeroRect];
  TerminalPanelViewController* controller = [[TerminalPanelViewController alloc] initWithContentView:content];
  // Test a defined geometry independently of the user's saved panel settings.
  controller.panelPosition = @"right";
  controller.panelWidth = 320;
  controller.panelHeight = 220;
  NSSplitView* split = (NSSplitView*)controller.view;
  split.frame = NSMakeRect(0, 0, 1000, 700);
  [split adjustSubviews];
  OAK_ASSERT(split.subviews.count == 1 && NSWidth(content.frame) == 1000);
  controller.panelVisible = YES;
  OAK_ASSERT(split.subviews.count == 2 && split.subviews[0] == content);
  OAK_ASSERT(NSWidth(split.subviews[1].frame) == 320);
  controller.panelPosition = @"left";
  OAK_ASSERT(split.subviews[1] == content && NSMinX(content.frame) > 0);
  controller.panelPosition = @"bottom";
  OAK_ASSERT(!split.isVertical && split.subviews[0] == content);
  OAK_ASSERT(NSHeight(split.subviews[1].frame) == 220);
  controller.panelHeight = 260;
  controller.panelPosition = @"right";
  controller.panelWidth = 380;
  split.frame = NSMakeRect(0, 0, 400, 300);
  [split adjustSubviews];
  OAK_ASSERT(NSWidth(content.frame) >= 240);
  OAK_ASSERT(controller.panelWidth == 380);
  split.frame = NSMakeRect(0, 0, 1000, 700);
  [split adjustSubviews];
  OAK_ASSERT(NSWidth(split.subviews[1].frame) == 380);
  controller.panelVisible = NO;
  OAK_ASSERT(split.subviews.count == 1 && NSWidth(content.frame) == 1000);
  controller.panelVisible = YES;
  controller.panelPosition = @"bottom";
  OAK_ASSERT(NSHeight(split.subviews[1].frame) == 260);
  controller.panelPosition = @"invalid";
  OAK_ASSERT([controller.panelPosition isEqualToString:@"bottom"]);
 }
	});
}

void test_terminal_panel_constrained_resize ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		@autoreleasepool
		{
 [NSApplication sharedApplication];
 NSView* content = [[NSView alloc] initWithFrame:NSMakeRect(0,0,1000,700)];
 NSView* child = [[NSView alloc] initWithFrame:NSZeroRect];
 child.translatesAutoresizingMaskIntoConstraints = NO;
 [content addSubview:child];
 [NSLayoutConstraint activateConstraints:@[[child.widthAnchor constraintGreaterThanOrEqualToConstant:460], [child.heightAnchor constraintGreaterThanOrEqualToConstant:180], [child.leftAnchor constraintEqualToAnchor:content.leftAnchor], [child.rightAnchor constraintEqualToAnchor:content.rightAnchor], [child.topAnchor constraintEqualToAnchor:content.topAnchor], [child.bottomAnchor constraintEqualToAnchor:content.bottomAnchor]]];
 TerminalPanelViewController* c = [[TerminalPanelViewController alloc] initWithContentView:content];
 NSSplitView* split = (NSSplitView*)c.view;
 split.frame = NSMakeRect(0,0,1000,700);
 NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1000,700) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
 window.releasedWhenClosed = NO;
 split.translatesAutoresizingMaskIntoConstraints = NO;
 [window.contentView addSubview:split];
 [NSLayoutConstraint activateConstraints:@[[split.leftAnchor constraintEqualToAnchor:window.contentView.leftAnchor], [split.rightAnchor constraintEqualToAnchor:window.contentView.rightAnchor], [split.topAnchor constraintEqualToAnchor:window.contentView.topAnchor], [split.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor]]];
 c.panelVisible = YES;
 [c startTerminalInDirectory:NSTemporaryDirectory()];
 OakTabBarView* bar = [[c valueForKey:@"terminalTabBarController"] valueForKey:@"tabBar"];
 OAK_ASSERT([bar isKindOfClass:OakTabBarView.class]);
 OAK_ASSERT([bar.dataSource numberOfRowsInTabBarView:bar] == 1);
 NSUUID* firstSession = [bar.dataSource tabBarView:bar UUIDForIndex:0];
 [bar.delegate tabBarViewDidDoubleClick:bar];
 OAK_ASSERT([bar.dataSource numberOfRowsInTabBarView:bar] == 2);
 OAK_ASSERT([bar.delegate performDropOfTabItem:firstSession fromTabBar:bar index:0 toTabBar:bar index:2 operation:NSDragOperationMove]);
 OAK_ASSERT([[bar.dataSource tabBarView:bar UUIDForIndex:1] isEqual:firstSession]);
 for(NSString* position in @[@"right", @"left", @"bottom"]) {
  c.panelPosition = position;
  c.panelVisible = NO;
  c.panelVisible = YES;
  for(int i=1000;i>=470;--i) {
   [window setContentSize:NSMakeSize(i,300)];
   [window.contentView layoutSubtreeIfNeeded];
   [split layoutSubtreeIfNeeded];
   OAK_ASSERT(NSWidth(content.frame)>=460);
   OAK_ASSERT(NSHeight(content.frame)>=180);
  }
 }
 [c stopTerminal];

		}
	});
}
