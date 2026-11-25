#ifndef COMPARE_SYNTAX_H_W8F3KD2N
#define COMPARE_SYNTAX_H_W8F3KD2N

#import <Cocoa/Cocoa.h>
#include <vector>
#include <atomic>

// Syntax highlighting for file tabs, chosen the way TextMate's editor
// chooses it for a document (OakDocumentEditor, OakTextView):
//   file type   file::type() from the path and the first bytes
//   settings    settings_for_path(path, file type, folder)
//   font        the fontName and fontSize settings (default: the user's
//               fixed-pitch font at 11 pt)
//   theme       the theme setting, else the dark or light theme preference
//               for the current appearance
//   grammar     the bundle grammar for the file type, parsed line by line
//               with the parser state carried from line to line
// Requires the bundle index (load_bundle_index) to be set.

namespace compare {

	struct syntax_run_t
	{
		NSRange range;                // UTF-16, within its line
		NSColor* foreground = nil;
		NSFontTraitMask traits = 0;   // NSBoldFontMask, NSItalicFontMask
		BOOL underline = NO;
		BOOL strikethrough = NO;
	};

	struct side_syntax_t
	{
		NSFont* font = nil;           // the editor's font for the file
		NSColor* foreground = nil;    // the theme's
		NSColor* background = nil;
		BOOL dark = NO;               // the theme is dark
		NSString* fileType = nil;     // nil without a grammar
		std::vector<std::vector<syntax_run_t>> lines; // runs per line; empty without a grammar
	};

	// Loads the bundle index as ThemeEditor does; call once on the main thread.
	void load_bundle_index ();

	// Any thread. `lines` are the file's lines without terminators; `path`
	// names the file (it may not exist: the other side's path gives the theme
	// and font of a side without the file). `darkAppearance` is the window's
	// effective appearance, used when the theme preference is automatic.
	// `parsedLines`, when given, counts the lines as they are parsed (for a
	// view showing how far loading a large file has got).
	side_syntax_t syntax_for_lines (NSArray<NSString*>* lines, NSString* path, NSData* contents, BOOL darkAppearance, std::atomic<long>* parsedLines = nullptr);

	// Files larger than this are shown in the theme's colors without parsing.
	static NSUInteger const kSyntaxSizeLimit = 2 * 1024 * 1024;

} /* compare */

#endif /* end of include guard: COMPARE_SYNTAX_H_W8F3KD2N */
