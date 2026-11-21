#import <Cocoa/Cocoa.h>

// One comparison window for an ordered pair of worktree roots. The left root
// is the worktree TextMate requested the comparison from. Given two files
// instead, it shows just their comparison: one file tab, no trees.
@interface CompareWindowController : NSWindowController <NSWindowDelegate>
// Git used for listing files and branch names; nil compares plain folders.
@property (class, nonatomic, copy) NSString* gitExecutable;
// NO skips confirmation alerts and shows problems only in `lastProblem` (tests).
@property (class, nonatomic) BOOL confirmsChanges;
// Opens txmt:// URLs (Edit in TextMate); tests replace it. By default they go
// to the TextMate.app this Compare is embedded in, or else an installed one.
@property (class, nonatomic, copy) void (^editHandler)(NSArray<NSURL*>* urls);
@property (nonatomic, readonly) NSString* lastProblem;

- (instancetype)initWithLeftPath:(NSString*)left rightPath:(NSString*)right focus:(NSString*)focus;
@property (nonatomic, readonly) NSString* leftPath;
@property (nonatomic, readonly) NSString* rightPath;
@property (nonatomic, readonly, getter = isFileComparison) BOOL fileComparison; // two files, not folders
// Folder below both roots to reveal; nil for the roots themselves. Setting it
// on a loaded window reveals the folder.
@property (nonatomic, copy) NSString* focus;

- (IBAction)refresh:(id)sender;
@property (nonatomic, readonly) NSUInteger comparisonCount; // finished comparisons, for tests
@property (nonatomic, readonly) NSUInteger fileEventCount;  // file system events received, for tests
// Remembers expanded folders for this pair of folders (also done on close).
- (void)saveState;

// The tree tab copies the selected entries; a file tab copies its current change.
- (IBAction)copyToRight:(id)sender;
- (IBAction)copyToLeft:(id)sender;
@end
