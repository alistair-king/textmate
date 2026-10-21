#import <Cocoa/Cocoa.h>
#import "../src/AIPanelViewController.h"
void test_ai_panel_layout ()
{
	@autoreleasepool {
  NSView* content = [[NSView alloc] initWithFrame:NSZeroRect];
  AIPanelViewController* controller = [[AIPanelViewController alloc] initWithContentView:content];
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
}
