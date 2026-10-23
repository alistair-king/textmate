#import <Foundation/Foundation.h>

// Build from an immutable editor snapshot, never a later live selection.
NSString* SelectionExplanationPrompt(NSDictionary* context, NSString** error);
NSString* SelectionExplanationLauncher(NSString* agent);
NSArray<NSString*>* SelectionExplanationArguments(NSString* agent, NSString* prompt);
