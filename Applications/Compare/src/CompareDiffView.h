#import <Cocoa/Cocoa.h>

@class CompareNode;

// Side-by-side contents of one compared entry. Rows line up across the two
// text views: a line missing on one side shows as a tinted gap.
@interface CompareDiffView : NSView
// Shows the entry's contents, loading files on a worker queue; nil clears.
- (void)showNode:(CompareNode*)node;
- (void)showMessage:(NSString*)message;

@property (nonatomic, readonly, getter = isLoading) BOOL loading;
@property (nonatomic, readonly) NSInteger changeCount;   // hunks in the shown file
@property (nonatomic, readonly) NSInteger currentChange; // -1 before the first

- (IBAction)nextChange:(id)sender;
- (IBAction)previousChange:(id)sender;

// For tests.
@property (nonatomic, readonly) NSTextView* leftTextView;
@property (nonatomic, readonly) NSTextView* rightTextView;
@property (nonatomic, readonly) NSString* message;   // nil while showing text
@property (nonatomic, readonly) NSString* statusText;
@end

// A 1 pt separator line with an intrinsic thickness, so Auto Layout never
// has to guess its size (unlike an NSBox separator).
@interface CompareSeparatorView : NSView
- (instancetype)initVertical:(BOOL)vertical;
@end

// The attribute CompareDiffView uses for full-width line backgrounds.
extern NSAttributedStringKey const CompareLineTintAttributeName;
