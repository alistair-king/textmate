#import <Foundation/Foundation.h>
#import "EditorContextService.h"

// Task state and terminal registration are confined to the main thread.
@interface TerminalA2A : NSObject
- (instancetype)initWithDirectory:(NSString*)directory;
- (NSDictionary*)perform:(NSString*)method arguments:(NSDictionary*)arguments
                 session:(NSString*)session peer:(pid_t)peer provider:(EditorContextProvider)provider;
- (void)revokeSession:(NSString*)session;
- (void)shutdown;
@end
