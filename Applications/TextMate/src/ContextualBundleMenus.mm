#import "ContextualBundleMenus.h"
#import <BundleMenu/BundleMenu.h>
#import <DocumentWindow/DocumentWindowController.h>
#import <document/OakDocument.h>
#import <Preferences/Keys.h>
#import <OakFoundation/NSString Additions.h>
#import <bundles/bundles.h>
#import <text/parse.h>
#import <text/ctype.h>
#import <text/case.h>
#import <ns/ns.h>

static NSInteger const kMaxPromotedMenus = 4;

// A bundle is relevant when at least this fraction of its scoped items match
// the context specifically (i.e. not merely via a generic parent scope).
static double const kMinimumMatchingFraction = 0.5;

namespace
{
	struct candidate_t
	{
		bundles::item_ptr bundle;
		std::vector<bundles::item_ptr> scopedItems;
	};

	struct promoted_t
	{
		oak::uuid_t uuid;
		std::string name;
		bool projectWide = false;
		bool operator== (promoted_t const& rhs) const { return uuid == rhs.uuid && name == rhs.name; }
	};
}

static std::string join (std::vector<std::string> const& atoms, std::string const& prefix = "")
{
	std::string res = prefix;
	for(auto const& atom : atoms)
		res += (res.empty() ? "" : " ") + atom;
	return res;
}

// Fraction of items whose selector matches `context` but not `generic`. The
// generic context is `context` with its most specific part removed, so a
// selector such as `source` or `text.html` does not make a bundle relevant
// for every Rust or Markdown file.
static double specific_match_fraction (std::vector<bundles::item_ptr> const& items, scope::context_t const& context, scope::context_t const& generic)
{
	if(items.empty())
		return 0;

	size_t matches = 0;
	for(auto const& item : items)
	{
		if(item->scope_selector().does_match(context) && !item->scope_selector().does_match(generic))
			++matches;
	}
	return double(matches) / items.size();
}

// Bundle names implied by project attributes: attr.scm.git → “git”, attr.project.ninja
// → “ninja”. This catches bundles whose items carry no scope selector (common in
// personal forks), which the selector-based rule cannot see.
static std::set<std::string> bundle_names_for_attributes (std::vector<std::string> const& attributes)
{
	static std::map<std::string, std::string> const aliases = {
		{ "hg",  "mercurial"  },
		{ "svn", "subversion" },
		{ "p4",  "perforce"   },
	};

	std::set<std::string> res;
	for(std::string const prefix : { "attr.scm.", "attr.project." })
	{
		for(auto const& attr : attributes)
		{
			if(attr.find(prefix) != 0)
				continue;

			std::string name = attr.substr(prefix.size());
			if(name.empty() || name.find('.') != std::string::npos) // Skip attr.scm.branch.*, attr.scm.status.*
				continue;

			name = text::lowercase(name);
			auto alias = aliases.find(name);
			res.insert(alias != aliases.end() ? alias->second : name);
		}
	}
	return res;
}

static std::vector<promoted_t> relevant_bundles (std::vector<std::string> const& attributes, std::string const& fileType, std::set<std::string> const& reservedTitles, std::set<std::string> const& shownUUIDs)
{
	std::map<oak::uuid_t, candidate_t> candidates;
	for(auto const& bundle : bundles::query(bundles::kFieldAny, NULL_STR, scope::wildcard, bundles::kItemTypeBundle))
	{
		if(!bundle->menu().empty() && reservedTitles.find(bundle->name()) == reservedTitles.end())
			candidates.emplace(bundle->uuid(), candidate_t{ bundle });
	}

	// Drag commands are scoped by drop target rather than by what the bundle is for
	int const kinds = bundles::kItemTypeCommand|bundles::kItemTypeMacro|bundles::kItemTypeSnippet;
	for(auto const& item : bundles::query(bundles::kFieldAny, NULL_STR, scope::wildcard, kinds, oak::uuid_t(), false))
	{
		auto it = candidates.find(item->bundle_uuid());
		if(it != candidates.end() && !to_s(item->scope_selector()).empty())
			it->second.scopedItems.push_back(item);
	}

	std::set<oak::uuid_t> grammarBundles;
	if(fileType != NULL_STR)
	{
		for(auto const& grammar : bundles::query(bundles::kFieldGrammarScope, fileType, scope::wildcard, bundles::kItemTypeGrammar, oak::uuid_t(), false))
			grammarBundles.insert(grammar->bundle_uuid());
	}

	scope::context_t const projectContext(join(attributes));
	scope::context_t const projectGeneric("");

	scope::context_t fileContext, fileGeneric;
	if(fileType != NULL_STR)
	{
		std::string::size_type dot = fileType.rfind('.');
		std::string const parentType = dot == std::string::npos ? "" : fileType.substr(0, dot);
		// Without window attributes, so file relevance does not vary with the project
		fileContext = scope::context_t(fileType);
		fileGeneric = scope::context_t(parentType);
	}

	std::set<std::string> const projectBundleNames = bundle_names_for_attributes(attributes);

	std::multimap<std::string, promoted_t, text::less_t> projectWide, projectWideByName, fileSpecific;
	for(auto const& pair : candidates)
	{
		candidate_t const& candidate = pair.second;
		std::string const& name = candidate.bundle->name();
		promoted_t const asProject = { candidate.bundle->uuid(), name, true };
		promoted_t const asFile    = { candidate.bundle->uuid(), name, false };

		if(!attributes.empty() && specific_match_fraction(candidate.scopedItems, projectContext, projectGeneric) >= kMinimumMatchingFraction)
			projectWide.emplace(name, asProject);
		else if(projectBundleNames.count(text::lowercase(name)))
			projectWideByName.emplace(name, asProject);
		else if(fileType != NULL_STR && (grammarBundles.count(pair.first) || specific_match_fraction(candidate.scopedItems, fileContext, fileGeneric) >= kMinimumMatchingFraction))
			fileSpecific.emplace(name, asFile);
	}

	// The name rule is a fallback: it only fills a slot when no selector-qualified
	// bundle has that name.
	std::set<std::string> projectNames;
	for(auto const& pair : projectWide)
		projectNames.insert(text::lowercase(pair.first));
	for(auto const& pair : projectWideByName)
	{
		if(!projectNames.count(text::lowercase(pair.first)))
			projectWide.insert(pair);
	}

	// Never promote two menus with the same (indistinguishable) title. Project-wide
	// beats file-specific; within a group an already-shown menu wins the tie.
	std::vector<promoted_t> res;
	std::set<std::string> seenNames;
	for(auto const* group : { &projectWide, &fileSpecific })
	{
		for(bool const shown : { true, false })
		{
			for(auto const& pair : *group)
			{
				if(shownUUIDs.count(to_s(pair.second.uuid)) == (shown ? 1 : 0) && seenNames.insert(text::lowercase(pair.first)).second)
					res.push_back(pair.second);
			}
		}
	}
	return res; // Uncapped, see -update
}

// Top-level menus display their submenu’s title, so unlike nested bundle menus
// we cannot use the title to carry the bundle UUID: keep it in the delegate.
@interface PromotedBundleMenuDelegate : NSObject <NSMenuDelegate>
@property (nonatomic, readonly) NSString* bundleUUID;
@end

@implementation PromotedBundleMenuDelegate
- (instancetype)initWithBundleUUID:(NSString*)uuid
{
	if(self = [super init])
		_bundleUUID = uuid;
	return self;
}

// Key equivalents for bundle items are handled by OakTextView / OakMainMenu
- (BOOL)menuHasKeyEquivalent:(NSMenu*)aMenu forEvent:(NSEvent*)theEvent target:(id*)aTarget action:(SEL*)anAction
{
	return NO;
}

- (void)menuNeedsUpdate:(NSMenu*)aMenu
{
	OakPopulateMenuWithBundleMenuItem(aMenu, bundles::lookup(to_s(_bundleUUID)));
}
@end

@interface ContextualBundleMenus ()
{
	NSMenu* _bundlesMenu;
	NSMutableDictionary<NSString*, NSMenuItem*>* _itemsByUUID;
	NSMutableDictionary<NSString*, PromotedBundleMenuDelegate*>* _delegatesByUUID; // NSMenu.delegate is weak
	std::vector<promoted_t> _promoted;
	std::string _contextKey;
}
@end

@interface ContextualBundleMenus (Private)
- (void)bundlesDidChange;
@end

namespace
{
	struct bundles_callback_t : bundles::callback_t
	{
		bundles_callback_t (ContextualBundleMenus* self) : _self(self) { }
		void bundles_did_change () override
		{
			__weak ContextualBundleMenus* weakSelf = _self;
			dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf bundlesDidChange]; });
		}
	private:
		__weak ContextualBundleMenus* _self;
	};
}

@implementation ContextualBundleMenus
{
	std::unique_ptr<bundles_callback_t> _bundlesCallback;
}

- (instancetype)initWithBundlesMenu:(NSMenu*)bundlesMenu
{
	if(self = [super init])
	{
		_bundlesMenu   = bundlesMenu;
		_itemsByUUID     = [NSMutableDictionary dictionary];
		_delegatesByUUID = [NSMutableDictionary dictionary];

		_bundlesCallback = std::make_unique<bundles_callback_t>(self);
		bundles::add_callback(_bundlesCallback.get());

		NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
		for(NSNotificationName name in @[ DocumentWindowControllerScopeContextDidChangeNotification, NSWindowDidBecomeMainNotification, NSWindowWillCloseNotification, NSWindowDidMiniaturizeNotification, NSWindowDidDeminiaturizeNotification, NSUserDefaultsDidChangeNotification ])
			[nc addObserver:self selector:@selector(contextMayHaveChanged:) name:name object:nil];

		[self scheduleUpdate];
	}
	return self;
}

- (void)dealloc
{
	bundles::remove_callback(_bundlesCallback.get());
	[NSNotificationCenter.defaultCenter removeObserver:self];
	[NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (void)bundlesDidChange
{
	_contextKey.clear(); // Force re-evaluation
	[self scheduleUpdate];
}

- (void)contextMayHaveChanged:(NSNotification*)aNotification
{
	[self scheduleUpdate];
}

// Trailing debounce: coalesces bursts of notifications and skips the transient
// states seen while switching documents (e.g. no selected document, or SCM and
// project attributes not yet computed), which would otherwise remove a menu
// only to insert it again moments later. Also lets a closing window leave
// orderedWindows first.
- (void)scheduleUpdate
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(update) object:nil];
	[self performSelector:@selector(update) withObject:nil afterDelay:0.15];
}

- (DocumentWindowController*)frontmostDocumentWindowController
{
	for(NSWindow* window in NSApp.orderedWindows)
	{
		if(window.isVisible && [window.delegate isKindOfClass:[DocumentWindowController class]])
			return (DocumentWindowController*)window.delegate;
	}
	return nil;
}

- (void)update
{
	std::vector<std::string> attributes;
	std::string fileType = NULL_STR;
	bool hasWindow = false;

	DocumentWindowController* controller = [NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsShowContextualBundleMenusKey] ? [self frontmostDocumentWindowController] : nil;
	if(controller.scopeAttributesPending)
		return; // Re-scheduled by the controller’s notification when the scan completes

	if(controller)
	{
		hasWindow = true;
		// Project-level attributes only, so per-document ones cannot make a bundle project-wide
		for(auto const& attr : text::split(to_s(controller.projectScopeAttributes), " "))
		{
			if(!attr.empty())
				attributes.push_back(attr);
		}

		if(OakDocument* doc = controller.selectedDocument; doc.fileType)
			fileType = to_s(doc.fileType);
	}

	std::string const contextKey = (hasWindow ? "1" : "0") + join(attributes) + "|" + fileType;
	if(contextKey == _contextKey)
		return;
	_contextKey = contextKey;

	std::set<std::string> reservedTitles;
	for(NSMenuItem* item in NSApp.mainMenu.itemArray)
	{
		if(![_itemsByUUID.allValues containsObject:item])
			reservedTitles.insert(to_s(item.title));
	}

	std::set<std::string> shownUUIDs;
	for(NSString* uuid in _itemsByUUID)
		shownUUIDs.insert(to_s(uuid));

	std::vector<promoted_t> const relevant = hasWindow ? relevant_bundles(attributes, fileType, reservedTitles, shownUUIDs) : std::vector<promoted_t>();

	// Apply the cap: project-wide menus (Git, …) always get a slot before
	// file-specific ones; within each tier, menus already shown come first so a
	// still-relevant menu is not evicted by a new one that sorts earlier.
	std::vector<promoted_t> promoted;
	for(bool const projectWide : { true, false })
	{
		for(bool const shown : { true, false })
		{
			for(auto const& bundle : relevant)
			{
				if(promoted.size() < kMaxPromotedMenus && bundle.projectWide == projectWide && (_itemsByUUID[to_ns(to_s(bundle.uuid))] != nil) == shown)
					promoted.push_back(bundle);
			}
		}
	}
	if(promoted == _promoted)
		return;
	_promoted = promoted;

	[self rebuildMenus];
}

// Reconcile the menu bar with _promoted. Menus that stay promoted are never
// removed or moved: they keep their current relative order, and newly promoted
// menus are added after them. Only menus no longer relevant are removed.
- (void)rebuildMenus
{
	NSMenu* mainMenu = NSApp.mainMenu;

	std::map<std::string, std::string> wanted; // uuid → title
	for(auto const& bundle : _promoted)
		wanted.emplace(to_s(bundle.uuid), bundle.name);

	for(NSString* uuid in _itemsByUUID.allKeys)
	{
		if(wanted.count(to_s(uuid)))
			continue;
		NSMenuItem* item = _itemsByUUID[uuid];
		if(item.menu == mainMenu)
			[mainMenu removeItem:item];
		[_itemsByUUID removeObjectForKey:uuid];
		[_delegatesByUUID removeObjectForKey:uuid];
	}

	NSInteger index = [mainMenu indexOfItemWithSubmenu:_bundlesMenu];
	if(index == -1)
		return;

	// Skip past the surviving menus, which are contiguous after the Bundles menu
	while(index + 1 < mainMenu.numberOfItems && [_itemsByUUID.allValues containsObject:[mainMenu itemAtIndex:index + 1]])
	{
		NSMenuItem* item = [mainMenu itemAtIndex:++index];
		for(NSString* uuid in _itemsByUUID)
		{
			if(_itemsByUUID[uuid] != item)
				continue;
			NSString* title = to_ns(wanted[to_s(uuid)]);
			if(![item.title isEqualToString:title]) // Bundle renamed
				item.title = item.submenu.title = title;
			break;
		}
	}

	for(auto const& bundle : _promoted)
	{
		NSString* uuid = [NSString stringWithCxxString:bundle.uuid];
		if(_itemsByUUID[uuid])
			continue;

		NSString* title = [NSString stringWithCxxString:bundle.name];
		PromotedBundleMenuDelegate* delegate = [[PromotedBundleMenuDelegate alloc] initWithBundleUUID:uuid];
		NSMenuItem* menuItem = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
		menuItem.submenu = [[NSMenu alloc] initWithTitle:title];
		menuItem.submenu.delegate = delegate;
		_itemsByUUID[uuid]     = menuItem;
		_delegatesByUUID[uuid] = delegate;
		[mainMenu insertItem:menuItem atIndex:++index];
	}
}
@end
