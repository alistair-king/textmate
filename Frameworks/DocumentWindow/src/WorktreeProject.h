#import <Foundation/Foundation.h>

// For a checkout in a worktrees project layout (a container folder holding the
// main checkout and its linked worktrees as siblings) return the container's
// name, e.g. “textmate” for ~/Development/textmate/feature-x. Returns nil for
// anything else. Only reads files below .git, so it is cheap to call when a
// window's project changes.
NSString* WorktreeProjectName (NSString* checkout);
