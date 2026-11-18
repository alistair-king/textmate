#import <Foundation/Foundation.h>

typedef NSDictionary* (^TerminalA2ARequest)(NSString* method, NSString* target, NSDictionary* headers, NSData* body, double deadline);

@interface TerminalA2AHTTP : NSObject
@property (readonly) NSString* origin;
- (instancetype)initWithRequest:(TerminalA2ARequest)request;
- (void)stop;
@end

NSDictionary* TerminalA2AProblem(NSInteger status, NSString* code, NSString* detail);
