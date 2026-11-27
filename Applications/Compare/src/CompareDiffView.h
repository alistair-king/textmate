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
// A spinner with `title` over the text area, until a node or message is shown.
- (void)showLoading:(NSString*)title;
@property (nonatomic, readonly, getter = isShowingLoading) BOOL showingLoading;
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

// Edit → Find: a bar above both sides. Matches on both sides are
// highlighted; the current one is selected and scrolled to.
- (IBAction)showFindBar:(id)sender;
- (IBAction)hideFindBar:(id)sender;
- (IBAction)findNext:(id)sender;     // wraps around
- (IBAction)findPrevious:(id)sender;
@property (nonatomic, readonly, getter = isFindBarVisible) BOOL findBarVisible;
@property (nonatomic, copy) NSString* findString;
@property (nonatomic) BOOL matchesCase;
@property (nonatomic, readonly) NSInteger findMatchCount;
@property (nonatomic, readonly) NSInteger currentFindMatch; // -1 for none
@property (nonatomic, readonly) BOOL currentFindMatchIsOnLeft;

// Copying a change: the arrows between the sides call this handler (the
// window controller writes the file). The view only computes contents.
@property (nonatomic, copy) void (^changeHandler)(CompareDiffView* view, NSInteger change, BOOL toRight);
// The bytes the shown comparison was made from.
- (NSData*)comparedDataOnLeft:(BOOL)left;
// The destination file's contents with `change` copied from the other side.
- (NSData*)contentsWithChange:(NSInteger)change toRight:(BOOL)toRight;

// Language servers, as TextMate's editor sets them up (the lspCommand
// setting): ⌘-click or Go to Definition goes to the definition of what is
// under the click or the caret on that side, Show Hover Info shows its type
// and documentation. A definition in the same file is shown here; one in
// another file goes to `definitionHandler`.
- (IBAction)goToDefinition:(id)sender;
- (IBAction)showHoverInfo:(id)sender;
// `line` and `character` are 0-based (`character` in UTF-16 units), as the
// server reports them.
@property (nonatomic, copy) void (^definitionHandler)(CompareDiffView* view, NSString* path, NSUInteger line, NSUInteger character, BOOL left);
// Scrolls to the line on one side and selects the word at `character`. While
// the file loads, this happens once it is shown.
- (void)revealLine:(NSUInteger)line character:(NSUInteger)character onLeft:(BOOL)left;

// For tests.
- (BOOL)hasLanguageServerOnLeft:(BOOL)left;     // one is set up for that side's file
- (BOOL)isLanguageServerReadyOnLeft:(BOOL)left; // and has answered `initialize`
- (void)goToDefinitionAtIndex:(NSUInteger)index onLeft:(BOOL)left; // as a ⌘-click there
- (void)showHoverAtIndex:(NSUInteger)index onLeft:(BOOL)left;
@property (nonatomic, readonly) NSString* hoverText; // nil while no hover is shown
@property (nonatomic, readonly) NSTextView* leftTextView;
@property (nonatomic, readonly) NSTextView* rightTextView;
@property (nonatomic, readonly) NSString* message;   // nil while showing text
@property (nonatomic, readonly) NSString* statusText;
- (NSString*)sideHeaderTextOnLeft:(BOOL)left; // “name|branch|path”
- (NSColor*)stripTintForRow:(long)row;        // the middle strip's color for a row
- (NSString*)loadingText;                     // “title|detail” of the loading overlay
@end

// A 1 pt separator line with an intrinsic thickness, so Auto Layout never
// has to guess its size (unlike an NSBox separator).
@interface CompareSeparatorView : NSView
- (instancetype)initVertical:(BOOL)vertical;
@end

// The attribute CompareDiffView uses for full-width line backgrounds.
extern NSAttributedStringKey const CompareLineTintAttributeName;
