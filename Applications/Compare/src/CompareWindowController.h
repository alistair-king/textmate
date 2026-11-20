#import <Cocoa/Cocoa.h>

// One comparison window for an ordered pair of worktree roots. The left root
// is the worktree TextMate requested the comparison from.
@interface CompareWindowController : NSWindowController <NSWindowDelegate>
- (instancetype)initWithLeftPath:(NSString*)left rightPath:(NSString*)right focus:(NSString*)focus;
@property (nonatomic, readonly) NSString* leftPath;
@property (nonatomic, readonly) NSString* rightPath;
// Folder below both roots to reveal; nil for the roots themselves.
@property (nonatomic, copy) NSString* focus;
@end
