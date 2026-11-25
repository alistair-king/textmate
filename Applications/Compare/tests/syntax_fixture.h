#ifndef SYNTAX_FIXTURE_H_Q3T8MZ5B
#define SYNTAX_FIXTURE_H_Q3T8MZ5B

#import <Foundation/Foundation.h>
#import <bundles/bundles.h>
#import <bundles/load.h>
#import <plist/fs_cache.h>
#import <ns/ns.h>

// A bundle of our own (a grammar for *.cmpt and a light and a dark theme) so
// syntax checks do not depend on what is installed. Shared by the syntax and
// window tests; installs the bundle index and the theme preferences once.

namespace syntax_fixture {

	static NSString* const kLightTheme = @"6C4A1F8E-5C1B-4E0B-9A40-3B3D3C6E8F01";
	static NSString* const kDarkTheme  = @"0B1E4F2C-7D3A-4C5B-8E6F-9A0B1C2D3E02";

	inline BOOL write_plist (NSString* path, NSDictionary* plist)
	{
		[NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
		return [plist writeToURL:[NSURL fileURLWithPath:path] error:nil];
	}

	// Returns NO when the bundle could not be written. `defaults` are added to
	// the argument domain along with the theme preferences.
	inline BOOL install (NSDictionary* defaults = nil)
	{
		// Once: the index and preferences are process-wide.
		static BOOL const installed = [defaults]{
			NSString* bundles = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"compare-syntax-" stringByAppendingString:NSUUID.UUID.UUIDString]];
			NSString* bundle  = [bundles stringByAppendingPathComponent:@"Compare Test.tmbundle"];
			auto theme = ^(NSString* uuid, NSString* background, NSString* foreground){
				return @{
					@"name": uuid, @"uuid": uuid,
					@"colorSpaceName": @"sRGB", // otherwise TextMate reads theme colors as Generic RGB
					@"settings": @[
						@{ @"settings": @{ @"background": background, @"foreground": foreground } },
						@{ @"scope": @"comment", @"settings": @{ @"foreground": @"#FF0000", @"fontStyle": @"italic" } },
						@{ @"scope": @"keyword", @"settings": @{ @"foreground": @"#0000FF", @"fontStyle": @"bold underline" } },
					],
				};
			};
			BOOL ok = write_plist([bundle stringByAppendingPathComponent:@"info.plist"], @{ @"name": @"Compare Test", @"uuid": @"5D0E6A3B-2C1F-4B8A-9E7D-6C5B4A3F2E03" })
				&& write_plist([bundle stringByAppendingPathComponent:@"Syntaxes/Test.tmLanguage"], @{
					@"name": @"Compare Test", @"scopeName": @"source.comparetest", @"fileTypes": @[ @"cmpt" ],
					@"uuid": @"8A7B6C5D-4E3F-4A1B-8C9D-0E1F2A3B4C04",
					@"patterns": @[
						@{ @"match": @"//.*", @"name": @"comment.line.double-slash" },
						@{ @"begin": @"/\\*", @"end": @"\\*/", @"name": @"comment.block" },
						@{ @"match": @"\\bkeyword\\b", @"name": @"keyword.control" },
					],
				})
				&& write_plist([bundle stringByAppendingPathComponent:@"Themes/Light.tmTheme"], theme(kLightTheme, @"#FAFAFA", @"#111111"))
				&& write_plist([bundle stringByAppendingPathComponent:@"Themes/Dark.tmTheme"], theme(kDarkTheme, @"#101010", @"#EEEEEE"));
			if(!ok)
				return NO;

			plist::cache_t cache;
			auto index = create_bundle_index({ to_s(bundles) }, cache);
			bundles::set_index(index.first, index.second);

			NSMutableDictionary* arguments = [defaults mutableCopy] ?: [NSMutableDictionary dictionary];
			arguments[@"universalThemeUUID"] = kLightTheme;
			arguments[@"darkModeThemeUUID"]  = kDarkTheme;
			[NSUserDefaults.standardUserDefaults setVolatileDomain:arguments forName:NSArgumentDomain];
			return YES;
		}();
		return installed;
	}

	// sRGB "#RRGGBB" of a color, for comparisons.
	inline NSString* hex (NSColor* color)
	{
		NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
		return rgb ? [NSString stringWithFormat:@"#%02X%02X%02X", (int)round(rgb.redComponent * 255), (int)round(rgb.greenComponent * 255), (int)round(rgb.blueComponent * 255)] : @"none";
	}

} /* syntax_fixture */

#endif /* end of include guard: SYNTAX_FIXTURE_H_Q3T8MZ5B */
