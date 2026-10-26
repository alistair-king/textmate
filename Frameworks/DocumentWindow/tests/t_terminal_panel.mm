#import "AgentStatusTabSource.h"
#import <Cocoa/Cocoa.h>
#import <OakTabBarView/OakTabBarView.h>
#import "../src/TerminalPanelViewController.h"
#import "../src/ProjectLayoutView.h"
#import <FileBrowser/FileBrowserViewController.h>

void test_terminal_panel_open_project ()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		@autoreleasepool
		{
			[NSApplication sharedApplication];
			ProjectLayoutView* content = [[ProjectLayoutView alloc] initWithFrame:NSZeroRect];
			content.documentView = [[NSView alloc] initWithFrame:NSZeroRect];
			[content.documentView.heightAnchor constraintGreaterThanOrEqualToConstant:25].active = YES;
			TerminalPanelViewController* controller = [[TerminalPanelViewController alloc] initWithContentView:content];
			NSView* split = controller.view;
			NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 700) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
			window.releasedWhenClosed = NO;
			split.translatesAutoresizingMaskIntoConstraints = NO;
			[window.contentView addSubview:split];
			[NSLayoutConstraint activateConstraints:@[
				[split.leftAnchor constraintEqualToAnchor:window.contentView.leftAnchor],
				[split.rightAnchor constraintEqualToAnchor:window.contentView.rightAnchor],
				[split.topAnchor constraintEqualToAnchor:window.contentView.topAnchor],
				[split.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor],
			]];
			// Project restoration adds the browser before the window's first layout pass.
			[window.contentView updateConstraintsForSubtreeIfNeeded];
			controller.panelHeight = 220;
			FileBrowserViewController* browser = [[FileBrowserViewController alloc] init];
			CGFloat minimumBrowserHeight = browser.view.fittingSize.height;
			content.fileBrowserView = browser.view;
			[window.contentView updateConstraintsForSubtreeIfNeeded];
			[content layoutSubtreeIfNeeded];
			OAK_ASSERT(NSHeight(browser.view.frame) >= minimumBrowserHeight);
			[window setContentSize:NSMakeSize(1100, 700)];
			[window.contentView layoutSubtreeIfNeeded];
			OAK_ASSERT(NSHeight(browser.view.frame) >= minimumBrowserHeight);
			OAK_ASSERT(NSHeight(content.frame) == NSHeight(split.bounds));
			[window close];
		}
	});
}

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
  OAK_ASSERT(split.subviews.count == 2 && content.superview == split.subviews[0]);
  OAK_ASSERT(NSWidth(split.subviews[1].frame) == 320);
  controller.panelPosition = @"left";
  OAK_ASSERT(content.superview == split.subviews[1] && NSMinX(content.superview.frame) > 0);
  controller.panelPosition = @"bottom";
  OAK_ASSERT(!split.isVertical && content.superview == split.subviews[0]);
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


void test_terminal_tab_status_presentation ()
{
    dispatch_sync(dispatch_get_main_queue(), ^{
        [NSApplication sharedApplication];
        AgentStatusTabSource* source = [AgentStatusTabSource new];
        source.identifier = NSUUID.UUID;
        source.status = OakTabStatusWorking;
        source.statusDescription = @"Working";
        OakTabBarView* bar = [[OakTabBarView alloc] initWithFrame:NSMakeRect(0, 0, 400, 23)];
        bar.dataSource = source;
        [bar reloadData];
        [bar layoutSubtreeIfNeeded];
        NSView* tab = nil;
        for(NSView* view in bar.subviews)
            if([view.accessibilityLabel isEqualToString:@"Agent, Working"]) tab = view;
        OAK_ASSERT(tab != nil);
        OAK_ASSERT([tab.toolTip isEqualToString:@"Working"]);
        NSProgressIndicator* spinner = nil;
        for(NSView* view in tab.subviews)
            for(NSView* child in view.subviews)
                if([child isKindOfClass:NSProgressIndicator.class]) spinner = (NSProgressIndicator*)child;
        OAK_ASSERT(spinner != nil && !spinner.superview.hidden);
        OAK_ASSERT(NSWidth(spinner.superview.frame) == 18);
        source.status = OakTabStatusBlocked;
        source.statusDescription = @"Needs approval";
        [bar reloadData];
        OAK_ASSERT([tab.accessibilityLabel isEqualToString:@"Agent, Needs approval"]);
        OAK_ASSERT([tab.toolTip isEqualToString:@"Needs approval"]);
        source.status = OakTabStatusNone;
        source.statusDescription = @"";
        [bar reloadData];
        [bar layoutSubtreeIfNeeded];
        OAK_ASSERT([tab.accessibilityLabel isEqualToString:@"Agent"]);
        OAK_ASSERT(spinner.superview.hidden && NSWidth(spinner.superview.frame) == 0);
    });
}
