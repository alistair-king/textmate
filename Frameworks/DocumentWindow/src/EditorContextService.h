#import <Foundation/Foundation.h>

// Capture on the main thread; render the immutable snapshot on a worker thread.
@interface EditorContextSnapshot : NSObject
+ (instancetype)response:(NSDictionary*)response;
+ (instancetype)renderer:(NSDictionary* (^)(double deadline))renderer;
- (NSDictionary*)renderBefore:(double)deadline;
@end

typedef EditorContextSnapshot* (^EditorContextProvider)(NSString* method, NSDictionary* arguments);
@interface EditorContextService : NSObject
+ (instancetype)sharedService;
- (NSDictionary<NSString*, NSString*>*)environmentForSession:(NSUUID*)session provider:(EditorContextProvider)provider;
- (void)revokeSession:(NSUUID*)session;
- (NSUInteger)contentGenerationForDocument:(id)document;
@end
