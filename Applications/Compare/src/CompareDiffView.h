#import <Cocoa/Cocoa.h>

@class CompareNode;

// Side-by-side contents of one compared entry. Rows line up across the two
// text views: a line missing on one side shows as a tinted gap.
@interface CompareDiffView : NSView
// Shows the entry's contents, loading files on a worker queue; nil clears.
- (void)showNode:(CompareNode*)node;
// After a change was copied: stays on the same change number when it still exists.
- (void)showNode:(CompareNode*)node keepingChange:(BOOL)keep;
@property (nonatomic, readonly) CompareNode* node;
// The same entry from a newer comparison, when its files are unchanged:
// keeps what is shown, but copies use the new tree's paths.
- (void)updateNode:(CompareNode*)node;
- (void)showMessage:(NSString*)message;
// The branch (or “detached 1a2b3c4”) shown beside each side's file name; nil
// outside a Git work tree.
- (void)setBranch:(NSString*)branch onLeft:(BOOL)left;
- (NSString*)branchOnLeft:(BOOL)left;

@property (nonatomic, readonly, getter = isLoading) BOOL loading;
@property (nonatomic, readonly) CGFloat rowHeight; // every row's height, on both sides
// The window whose appearance picks the theme while this view is not in it.
@property (nonatomic, weak) NSWindow* hostWindow;
@property (nonatomic, readonly) NSInteger changeCount;   // hunks in the shown file
@property (nonatomic, readonly) NSInteger currentChange; // -1 before the first
// The 1-based line to edit one side at: where the current change (or the
// first, before any) starts on that side; 1 without changes.
- (NSInteger)editingLineOnLeft:(BOOL)left;

- (IBAction)nextChange:(id)sender;
- (IBAction)previousChange:(id)sender;

// Copying a change: the arrows between the sides call this handler (the
// window controller writes the file). The view only computes contents.
@property (nonatomic, copy) void (^changeHandler)(CompareDiffView* view, NSInteger change, BOOL toRight);
// The bytes the shown comparison was made from.
- (NSData*)comparedDataOnLeft:(BOOL)left;
// The destination file's contents with `change` copied from the other side.
- (NSData*)contentsWithChange:(NSInteger)change toRight:(BOOL)toRight;

// For tests.
@property (nonatomic, readonly) NSTextView* leftTextView;
@property (nonatomic, readonly) NSTextView* rightTextView;
@property (nonatomic, readonly) NSString* message;   // nil while showing text
@property (nonatomic, readonly) NSString* statusText;
- (NSString*)sideHeaderTextOnLeft:(BOOL)left; // “name|branch|path”
@end

// A 1 pt separator line with an intrinsic thickness, so Auto Layout never
// has to guess its size (unlike an NSBox separator).
@interface CompareSeparatorView : NSView
- (instancetype)initVertical:(BOOL)vertical;
@end

// The attribute CompareDiffView uses for full-width line backgrounds.
extern NSAttributedStringKey const CompareLineTintAttributeName;
