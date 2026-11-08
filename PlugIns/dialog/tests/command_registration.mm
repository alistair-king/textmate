#import <Foundation/Foundation.h>

@protocol DialogCommandRegistry
+ (id)objectForCommand:(NSString*)command;
@end

int main (int argc, char const* argv[])
{
	@autoreleasepool
	{
		if(argc != 2)
			return 2;
		NSError* error = nil;
		NSBundle* plugin = [NSBundle bundleWithPath:@(argv[1])];
		if(![plugin loadAndReturnError:&error])
		{
			fprintf(stderr, "Could not load Dialog2: %s\n", error.description.UTF8String);
			return 1;
		}
		Class<DialogCommandRegistry> registry = NSClassFromString(@"TMDCommand");
		// Check the actual compiled plugin, without showing any dialogs. Bundle
		// helpers need menu for choices, nib for text input, and alert for errors.
		for(NSString* command in @[@"menu", @"nib", @"alert", @"help", @"filepanel", @"defaults", @"images", @"x-insert", @"popup", @"tooltip", @"prototype"])
		{
			if(![registry objectForCommand:command])
			{
				fprintf(stderr, "Dialog2 did not register command: %s\n", command.UTF8String);
				return 1;
			}
		}
	}
	return 0;
}
