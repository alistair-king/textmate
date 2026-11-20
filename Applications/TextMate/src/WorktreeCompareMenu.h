#import <Cocoa/Cocoa.h>

// Drives Text → Compare To ▸. The item is visible only while the main
// window's project belongs to a Git repository with other worktrees, and each
// submenu item opens Compare.app for the current and the chosen worktree.
//
// Worktree discovery runs on a worker queue, so opening a menu never waits
// for Git; the cache is refreshed when the main window's project changes,
// when TextMate becomes active, and when the repository's worktrees change.
@interface WorktreeCompareMenu : NSObject <NSMenuDelegate>
@property (class, readonly) WorktreeCompareMenu* sharedInstance;
@property (nonatomic, weak) NSMenuItem* menuItem;
// Cheap enough to call from -applicationDidUpdate:.
- (void)updateMenuItemVisibility;
- (IBAction)compareToWorktree:(id)sender;

// For tests (tests/worktree_compare_menu.mm); nil keeps TextMate's behaviour.
@property (nonatomic, copy) NSString* (^projectPathProvider)(void); // default: the main window's project
@property (nonatomic, copy) NSString* gitExecutable;                // default: found like TextMate's SCM support
@property (nonatomic, copy) void (^openHandler)(NSURL* url);       // default: opens Compare.app with the URL
@property (nonatomic, readonly) NSArray<NSString*>* otherWorktreePaths; // the current project's, as cached
@property (nonatomic, readonly) NSUInteger discoveryCount;              // worktree lookups started
@end
