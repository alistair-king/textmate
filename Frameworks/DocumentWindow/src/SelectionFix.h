#import <Cocoa/Cocoa.h>
#import <selection/types.h>
@class OakDocument;

// One immutable selection request. Proposals never write to disk or apply
// themselves: only the review sheet's Apply action calls applyToDocument:.
@interface SelectionFix : NSObject
- (instancetype)initWithContext:(NSDictionary*)context byteRanges:(ng::ranges_t const&)ranges diagnostics:(NSDictionary*)diagnostics error:(NSString**)error;
@property (nonatomic, readonly) NSString* identifier;
@property (nonatomic, readonly) NSString* documentId;
@property (nonatomic, readonly) NSString* status;
@property (nonatomic, readonly) NSString* summary;
@property (nonatomic, readonly) NSString* diff;
- (NSString*)prompt;
- (BOOL)matchesDocument:(OakDocument*)document;
- (NSString*)prepareReplacements:(NSArray<NSString*>*)replacements summary:(NSString*)summary;
- (BOOL)applyToDocument:(OakDocument*)document;
- (void)discard;
- (void)markStale;
- (NSAlert*)reviewAlert;
@end
