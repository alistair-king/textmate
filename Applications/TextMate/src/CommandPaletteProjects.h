#import <Foundation/Foundation.h>

// Worker-thread, read-only discovery. Each entry is keyed by its canonical
// worktree root; projects below that root inherit its branch information.
NSDictionary<NSString*, NSDictionary*>* CommandPaletteWorktrees(NSArray<NSString*>* paths, NSString* git, NSProgress* progress = nil);
NSString* CommandPaletteCanonicalPath(NSString* path);
NSDictionary* CommandPaletteWorktreeForPath(NSDictionary<NSString*, NSDictionary*>* worktrees, NSString* path);
NSArray<NSString*>* CommandPaletteWorkspacePaths(NSArray<NSString*>* paths, NSDictionary<NSString*, NSDictionary*>* worktrees);
