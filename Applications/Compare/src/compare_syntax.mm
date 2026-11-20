#import "compare_syntax.h"
#import <io/path.h>
#import "../../ThemeEditor/src/bundle_index.h"
#import <bundles/bundles.h>
#import <file/type.h>
#import <file/bytes.h>
#import <parse/grammar.h>
#import <parse/parse.h>
#import <settings/settings.h>
#import <settings/keys.h>
#import <theme/theme.h>
#import <text/utf16.h>
#import <ns/ns.h>
#include <map>
#include <mutex>

namespace compare {

	void load_bundle_index ()
	{
		auto index = theme_editor::load_bundle_index();
		bundles::set_index(index.first, index.second);
	}

	// As OakTextView's effectiveThemeUUID.
	static std::string ThemeUUID (settings_t const& settings, BOOL darkAppearance)
	{
		std::string const scoped = settings.get(kSettingsThemeKey);
		if(scoped != NULL_STR)
			return scoped;
		NSString* appearance = [NSUserDefaults.standardUserDefaults stringForKey:@"themeAppearance"];
		BOOL dark = [appearance isEqualToString:@"dark"] || (![appearance isEqualToString:@"light"] && darkAppearance);
		return to_s([NSUserDefaults.standardUserDefaults stringForKey:dark ? @"darkModeThemeUUID" : @"universalThemeUUID"]);
	}

	static NSColor* Color (CGColorRef color)
	{
		return color ? [NSColor colorWithCGColor:color] : nil;
	}

	static NSFontTraitMask Traits (CTFontRef font)
	{
		NSFontTraitMask traits = 0;
		if(font)
		{
			CTFontSymbolicTraits symbolic = CTFontGetSymbolicTraits(font);
			if(symbolic & kCTFontBoldTrait)
				traits |= NSBoldFontMask;
			if(symbolic & kCTFontItalicTrait)
				traits |= NSItalicFontMask;
		}
		return traits;
	}

	side_syntax_t syntax_for_lines (NSArray<NSString*>* lines, NSString* path, NSData* contents, BOOL darkAppearance)
	{
		side_syntax_t result;
		std::string const filePath = path ? to_s(path) : NULL_STR;

		// File type from the path and the first bytes, as for a document.
		io::bytes_ptr bytes;
		if(contents.length)
			bytes = std::make_shared<io::bytes_t>((char const*)contents.bytes, MIN(contents.length, (NSUInteger)4096), false);
		std::string const fileType = file::type(filePath, bytes);

		settings_t const settings = settings_for_path(filePath, fileType, path ? to_s(path.stringByDeletingLastPathComponent) : NULL_STR);
		NSString* fontName = to_ns(settings.get(kSettingsFontNameKey, NULL_STR));
		CGFloat fontSize = settings.get(kSettingsFontSizeKey, 11.0);
		result.font = (fontName ? [NSFont fontWithName:fontName size:fontSize] : nil) ?: [NSFont userFixedPitchFontOfSize:fontSize];

		theme_ptr theme;
		if(bundles::item_ptr themeItem = bundles::lookup(ThemeUUID(settings, darkAppearance)))
			theme = std::make_shared<theme_t>(themeItem, to_s(result.font.fontName), result.font.pointSize, false);
		if(!theme)
			return result;
		result.foreground = Color(theme->foreground());
		result.background = Color(theme->background(fileType));
		result.dark       = theme->is_dark();

		parse::grammar_ptr grammar;
		if(fileType != NULL_STR)
		{
			for(auto const& item : bundles::query(bundles::kFieldGrammarScope, fileType, scope::wildcard, bundles::kItemTypeGrammar))
			{
				if((grammar = parse::parse_grammar(item)))
					break;
			}
		}
		if(!grammar || contents.length > kSyntaxSizeLimit)
			return result;
		result.fileType = to_ns(fileType);

		// Line by line, as the buffer parses (buffer/src/parsing.cc): the
		// grammar's lock held, the state and the current scope carried over.
		std::lock_guard<std::mutex> lock(grammar->mutex());
		parse::stack_ptr state = grammar->seed();
		scope::scope_t current;
		result.lines.reserve(lines.count);
		for(NSUInteger n = 0; n < lines.count; ++n)
		{
			std::string const line = to_s(lines[n]) + "\n";
			std::map<size_t, scope::scope_t> scopes;
			state = parse::parse(line.data(), line.data() + line.size(), state, scopes, n == 0);

			std::vector<syntax_run_t> runs;
			size_t const end = line.size() - 1; // without the newline
			size_t from = 0;
			NSUInteger location = 0;
			auto emit = [&](size_t to){
				if(to <= from)
					return;
				NSUInteger length = utf16::distance(line.data() + from, line.data() + to);
				styles_t const& styles = theme->styles_for_scope(current);
				syntax_run_t run;
				run.range         = NSMakeRange(location, length);
				run.foreground    = Color(styles.foreground());
				run.traits        = Traits(styles.font());
				run.underline     = styles.underlined();
				run.strikethrough = styles.strikethrough();
				runs.push_back(run);
				location += length;
				from = to;
			};
			for(auto const& pair : scopes)
			{
				emit(std::min(pair.first, end));
				current = pair.second;
			}
			emit(end);
			result.lines.push_back(std::move(runs));
		}
		return result;
	}

} /* compare */
