#import "AppController.h"
#import "CommandPaletteProjects.h"
#import "ProjectCreation.h"
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <scm/drivers/api.h>

static NSString* const kUserDefaultsNewProjectParentKey = @"newProjectParentFolder";
static NSString* const kUserDefaultsNewProjectLayoutKey = @"newProjectLayout";

static NSString* GitExecutable ()
{
	std::string executable = scm::find_executable("git", "TM_GIT");
	return executable == NULL_STR ? nil : @(executable.c_str());
}

static void ShowError (NSString* message, NSString* detail)
{
	NSAlert* alert = [NSAlert new];
	alert.alertStyle      = NSAlertStyleWarning;
	alert.messageText     = message;
	alert.informativeText = detail ?: @"";
	[alert runModal];
}

// Runs work on a worker thread behind a small progress window, then opens the
// returned folder as a project or reports the failure.
static void RunProjectTask (NSString* progressText, NSString* failureText, NSString* (^work)(NSError**))
{
	NSProgressIndicator* spinner = [NSProgressIndicator new];
	spinner.style = NSProgressIndicatorStyleSpinning;
	spinner.controlSize = NSControlSizeSmall;
	[spinner startAnimation:nil];

	NSStackView* stack = [NSStackView stackViewWithViews:@[ spinner, OakCreateLabel(progressText) ]];
	stack.edgeInsets = NSEdgeInsetsMake(16, 20, 16, 20);

	NSPanel* panel = [[NSPanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskUtilityWindow backing:NSBackingStoreBuffered defer:NO];
	panel.title = @"Project";
	panel.releasedWhenClosed = NO;
	panel.hidesOnDeactivate  = NO;
	panel.contentView = stack;
	[panel setContentSize:stack.fittingSize];
	[panel center];
	[panel orderFront:nil];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSError* error = nil;
		NSString* path = work(&error);
		dispatch_async(dispatch_get_main_queue(), ^{
			[spinner stopAnimation:nil];
			[panel close];
			if(path)
				OakOpenDocuments(@[ path ]);
			else
				ShowError(failureText, error.localizedDescription);
		});
	});
}

static NSTextField* CreateTextField (NSString* placeholder)
{
	NSTextField* field = [NSTextField textFieldWithString:@""];
	field.placeholderString = placeholder;
	[field.widthAnchor constraintEqualToConstant:320].active = YES;
	return field;
}

static NSView* CreateForm (NSArray<NSArray<NSView*>*>* rows)
{
	NSMutableArray* gridRows = [NSMutableArray array];
	for(NSArray<NSView*>* row in rows)
		[gridRows addObject:@[ OakCreateLabel((NSString*)row[0], nil, NSTextAlignmentRight), row[1] ]];
	NSGridView* grid = [NSGridView gridViewWithViews:gridRows];
	grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
	grid.rowSpacing   = 8;
	[grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
	[grid layoutSubtreeIfNeeded];
	grid.frame = { NSZeroPoint, grid.fittingSize };
	return grid;
}

@interface NewProjectForm : NSObject <NSTextFieldDelegate>
@property (nonatomic) NSTextField*   nameField;
@property (nonatomic) NSTextField*   remoteField;
@property (nonatomic) NSPopUpButton* layoutPopUp;
@property (nonatomic) NSTextField*   locationLabel;
@property (nonatomic) NSURL*         location;
@property (nonatomic) NSView*        view;
@property (nonatomic) BOOL           nameEdited;
@end

@implementation NewProjectForm
- (instancetype)init
{
	if(self = [super init])
	{
		NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
		NSString* parent = [defaults stringForKey:kUserDefaultsNewProjectParentKey] ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Development"];
		BOOL isDirectory = NO;
		if(![NSFileManager.defaultManager fileExistsAtPath:parent isDirectory:&isDirectory] || !isDirectory)
			parent = NSHomeDirectory();

		_nameField   = CreateTextField(@"Project name");
		_remoteField = CreateTextField(@"Optional — leave empty for a new repository");
		_nameField.delegate = _remoteField.delegate = self;

		_layoutPopUp = OakCreatePopUpButton();
		[_layoutPopUp addItemsWithTitles:@[ @"Worktrees — Name/branch/", @"Single checkout — Name/" ]];
		[_layoutPopUp selectItemAtIndex:[defaults integerForKey:kUserDefaultsNewProjectLayoutKey] == ProjectCreationLayoutPlain ? 1 : 0];

		_locationLabel = OakCreateLabel();
		NSButton* choose = OakCreateButton(@"Choose…");
		choose.target = self;
		choose.action = @selector(chooseLocation:);
		NSStackView* locationRow = [NSStackView stackViewWithViews:@[ _locationLabel, choose ]];
		[_locationLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
		[locationRow.widthAnchor constraintEqualToConstant:320].active = YES;
		self.location = [NSURL fileURLWithPath:parent isDirectory:YES];

		_view = CreateForm(@[
			@[ @"Name:",       _nameField     ],
			@[ @"Clone from:", _remoteField   ],
			@[ @"Layout:",     _layoutPopUp   ],
			@[ @"Location:",   locationRow    ],
		]);
	}
	return self;
}

- (void)setLocation:(NSURL*)url
{
	_location = url;
	_locationLabel.stringValue = url.path.stringByAbbreviatingWithTildeInPath;
}

- (ProjectCreationLayout)layout
{
	return _layoutPopUp.indexOfSelectedItem == 1 ? ProjectCreationLayoutPlain : ProjectCreationLayoutWorktrees;
}

- (void)controlTextDidChange:(NSNotification*)notification
{
	if(notification.object == _nameField)
		_nameEdited = _nameField.stringValue.length != 0;
	else if(notification.object == _remoteField && !_nameEdited)
		_nameField.stringValue = CommandPaletteRepositoryName(_remoteField.stringValue) ?: @"";
}

- (void)chooseLocation:(id)sender
{
	NSOpenPanel* panel = NSOpenPanel.openPanel;
	panel.canChooseFiles          = NO;
	panel.canChooseDirectories    = YES;
	panel.canCreateDirectories    = YES;
	panel.prompt                  = @"Choose";
	panel.message                 = @"Choose the folder new projects are created in.";
	panel.directoryURL            = _location;
	if([panel runModal] == NSModalResponseOK)
		self.location = panel.URL;
}
@end

@implementation AppController (Projects)
- (IBAction)newProject:(id)sender
{
	NSString* git = GitExecutable();
	if(!git)
		return ShowError(@"Git was not found.", @"Install Git or set TM_GIT to its location.");

	NewProjectForm* form = [NewProjectForm new];
	NSString* name;
	while(true)
	{
		NSAlert* alert = [NSAlert new];
		alert.messageText     = @"New Project";
		alert.informativeText = @"With Worktrees, the project folder holds one folder per branch, starting with the default branch. Single checkout puts the repository in the project folder itself.";
		alert.accessoryView   = form.view;
		[alert addButtonWithTitle:@"Create"];
		[alert addButtonWithTitle:@"Cancel"];
		[alert layout];
		alert.window.initialFirstResponder = form.nameField;
		if([alert runModal] != NSAlertFirstButtonReturn)
			return;

		name = [form.nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		NSString* problem = ProjectCreationNameProblem(name);
		if(!problem && [NSFileManager.defaultManager fileExistsAtPath:[form.location.path stringByAppendingPathComponent:name]])
			problem = [NSString stringWithFormat:@"“%@” already exists in %@.", name, form.location.path.stringByAbbreviatingWithTildeInPath];
		if(!problem)
			break;
		ShowError(@"The project could not be created.", problem);
	}

	NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
	[defaults setObject:form.location.path forKey:kUserDefaultsNewProjectParentKey];
	[defaults setInteger:form.layout forKey:kUserDefaultsNewProjectLayoutKey];

	NSString* parent = form.location.path;
	NSString* remote = form.remoteField.stringValue;
	ProjectCreationLayout layout = form.layout;
	NSString* progress = remote.length ? [NSString stringWithFormat:@"Cloning “%@”…", name] : [NSString stringWithFormat:@"Creating “%@”…", name];
	RunProjectTask(progress, @"The project could not be created.", ^NSString*(NSError** error){
		return ProjectCreationCreate(parent, name, layout, remote, git, error);
	});
}

- (IBAction)importProject:(id)sender
{
	NSOpenPanel* panel = NSOpenPanel.openPanel;
	panel.canChooseFiles       = NO;
	panel.canChooseDirectories = YES;
	panel.prompt               = @"Import";
	panel.message              = @"Choose a project folder. For a folder of worktrees, its main checkout is opened.";
	if([panel runModal] == NSModalResponseOK)
		OakOpenDocuments(@[ ProjectCreationImportPath(panel.URL.path) ]);
}

- (void)newWorktreeForRepository:(NSString*)repositoryPath projectName:(NSString*)projectName
{
	NSString* git = GitExecutable();
	if(!git)
		return ShowError(@"Git was not found.", @"Install Git or set TM_GIT to its location.");

	NSTextField* branchField = CreateTextField(@"feature/my-change");
	NSView* form = CreateForm(@[ @[ @"Branch:", branchField ] ]);
	NSString* container = ProjectCreationWorktreeContainer(repositoryPath).stringByAbbreviatingWithTildeInPath;

	NSString* branch;
	while(true)
	{
		NSAlert* alert = [NSAlert new];
		alert.messageText     = [NSString stringWithFormat:@"New Worktree in “%@”", projectName];
		alert.informativeText = [NSString stringWithFormat:@"The branch is checked out in %@/, in a folder named after it. An existing local or origin branch is used; otherwise a new branch starts from the main checkout’s current commit.", container];
		alert.accessoryView   = form;
		[alert addButtonWithTitle:@"Create"];
		[alert addButtonWithTitle:@"Cancel"];
		[alert layout];
		alert.window.initialFirstResponder = branchField;
		if([alert runModal] != NSAlertFirstButtonReturn)
			return;

		branch = [branchField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		if(branch.length)
			break;
		ShowError(@"The worktree could not be created.", @"Enter a branch name.");
	}

	RunProjectTask([NSString stringWithFormat:@"Creating worktree “%@”…", branch], @"The worktree could not be created.", ^NSString*(NSError** error){
		return ProjectCreationAddWorktree(repositoryPath, branch, git, error);
	});
}
@end
