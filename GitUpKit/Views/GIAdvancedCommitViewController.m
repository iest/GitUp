//  Copyright (C) 2015-2019 Pierre-Olivier Latour <info@pol-online.net>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.

#if !__has_feature(objc_arc)
#error This file requires ARC
#endif

#import "GIAdvancedCommitViewController.h"
#import "GIDiffFilesViewController.h"
#import "GIDiffContentsViewController.h"
#import "GIRemappingExplanationPopover.h"
#import "GIViewController+Utilities.h"

#import "GIColorView.h"
#import "GIInterface.h"
#import "GIWindowController.h"
#import "XLFacilityMacros.h"

@interface GIAdvancedCommitViewController () <GIDiffFilesViewControllerDelegate, GIDiffContentsViewControllerDelegate>
@property(nonatomic, weak) IBOutlet GIColorView* workdirHeaderView;
@property(nonatomic, weak) IBOutlet NSView* workdirFilesView;
@property(nonatomic, weak) IBOutlet GIColorView* indexHeaderView;
@property(nonatomic, weak) IBOutlet NSView* indexFilesView;
@property(nonatomic, weak) IBOutlet NSView* diffContentsView;
@property(nonatomic, weak) IBOutlet NSButton* unstageButton;
@property(nonatomic, weak) IBOutlet NSButton* commitButton;
@property(nonatomic, weak) IBOutlet NSButton* generateCommitMessageButton;
@property(nonatomic, weak) IBOutlet NSButton* stageButton;
@property(nonatomic, weak) IBOutlet NSButton* discardButton;
@end

@implementation GIAdvancedCommitViewController {
  GIDiffFilesViewController* _workdirFilesViewController;
  GIDiffFilesViewController* _indexFilesViewController;
  GIDiffContentsViewController* _diffContentsViewController;
  GCDiff* _indexStatus;
  GCDiff* _workdirStatus;
  NSDictionary* _indexConflicts;
  BOOL _indexActive;
  BOOL _disableFeedback;
  NSProgressIndicator* _generateCommitMessageSpinner;
  NSImage* _generateCommitMessageImage;
}

- (NSString*)_escapeForBashDoubleQuotes:(NSString*)string {
  NSString* escaped = [string stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
  escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
  escaped = [escaped stringByReplacingOccurrencesOfString:@"$" withString:@"\\$"];
  escaped = [escaped stringByReplacingOccurrencesOfString:@"`" withString:@"\\`"];
  return escaped;
}

- (NSString*)_commitPromptText:(NSError**)error {
  NSString* path = [[NSBundle mainBundle] pathForResource:@"commit_promp" ofType:@"txt"];
  if (!path) {
    if (error) {
      *error = GCNewError(kGCErrorCode_Generic, @"Missing commit_promp.txt in application bundle");
    }
    return nil;
  }
  NSString* prompt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:error];
  if (!prompt.length && error && !*error) {
    *error = GCNewError(kGCErrorCode_Generic, @"commit_promp.txt is empty");
  }
  return prompt;
}

- (NSString*)_stagedDiffText:(NSError**)error {
  GCDiff* diff = [self.repository diffRepositoryIndexWithHEAD:nil
                                                      options:(self.repository.diffBaseOptions | kGCDiffOption_FindRenames)
                                            maxInterHunkLines:self.repository.diffMaxInterHunkLines
                                              maxContextLines:self.repository.diffMaxContextLines
                                                        error:error];
  if (!diff) {
    return nil;
  }
  if (!diff.modified) {
    return @"";
  }

  NSMutableString* diffText = [[NSMutableString alloc] init];
  for (GCDiffDelta* delta in diff.deltas) {
    BOOL isBinary = NO;
    GCDiffPatch* patch = [self.repository makePatchForDiffDelta:delta isBinary:&isBinary error:error];
    if (!patch) {
      return nil;
    }
    NSString* patchText = [patch patchString:error];
    if (!patchText) {
      return nil;
    }
    [diffText appendString:patchText];
    if (![patchText hasSuffix:@"\n"]) {
      [diffText appendString:@"\n"];
    }
  }
  return diffText;
}

- (NSString*)_runCodexExecWithInput:(NSString*)input error:(NSError**)error {
  NSString* escapedInput = [self _escapeForBashDoubleQuotes:input];
  NSString* command = [NSString stringWithFormat:@"codex exec \"%@\" 2>/dev/null", escapedInput];

  NSPipe* outputPipe = [NSPipe pipe];
  NSTask* task = [[NSTask alloc] init];
  task.launchPath = @"/bin/bash";
  task.arguments = @[ @"-lc", command ];
  task.currentDirectoryPath = self.repository.workingDirectoryPath;
  task.standardOutput = outputPipe;
  task.standardError = [NSFileHandle fileHandleWithNullDevice];

  @try {
    [task launch];
    NSData* outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
      if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                     code:task.terminationStatus
                                 userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"codex exec exited with status %i", task.terminationStatus]}];
      }
      return nil;
    }
    return [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
  } @catch (NSException* exception) {
    if (error) {
      *error = GCNewError(kGCErrorCode_Generic, exception.reason);
    }
    return nil;
  }
}

- (void)loadView {
  [super loadView];

  _workdirHeaderView.backgroundColor = NSColor.gitUpCommitHeaderBackgroundColor;

  _workdirFilesViewController = [[GIDiffFilesViewController alloc] initWithRepository:self.repository];
  _workdirFilesViewController.delegate = self;
  _workdirFilesViewController.allowsMultipleSelection = YES;
  _workdirFilesViewController.emptyLabel = NSLocalizedString(@"No changes in working directory", nil);
  [_workdirFilesView replaceWithView:_workdirFilesViewController.view];

  _indexHeaderView.backgroundColor = NSColor.gitUpCommitHeaderBackgroundColor;

  _indexFilesViewController = [[GIDiffFilesViewController alloc] initWithRepository:self.repository];
  _indexFilesViewController.delegate = self;
  _indexFilesViewController.allowsMultipleSelection = YES;
  _indexFilesViewController.emptyLabel = NSLocalizedString(@"No changes in index", nil);
  [_indexFilesView replaceWithView:_indexFilesViewController.view];

  _diffContentsViewController = [[GIDiffContentsViewController alloc] initWithRepository:self.repository];
  _diffContentsViewController.delegate = self;
  _diffContentsViewController.emptyLabel = NSLocalizedString(@"No file selected", nil);
  [_diffContentsView replaceWithView:_diffContentsViewController.view];

  self.messageTextView.string = @"";

  if (@available(macOS 11.0, *)) {
    _generateCommitMessageImage = [NSImage imageWithSystemSymbolName:@"sparkles" accessibilityDescription:NSLocalizedString(@"Generate commit message", nil)];
  } else {
    _generateCommitMessageImage = [NSImage imageNamed:NSImageNameActionTemplate];
  }
  _generateCommitMessageButton.image = _generateCommitMessageImage;
  _generateCommitMessageButton.imagePosition = NSImageOnly;
  _generateCommitMessageButton.title = @"";

  _generateCommitMessageSpinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
  _generateCommitMessageSpinner.style = NSProgressIndicatorStyleSpinning;
  _generateCommitMessageSpinner.controlSize = NSControlSizeSmall;
  _generateCommitMessageSpinner.displayedWhenStopped = NO;
  _generateCommitMessageSpinner.translatesAutoresizingMaskIntoConstraints = NO;
  [_generateCommitMessageButton addSubview:_generateCommitMessageSpinner];
  [NSLayoutConstraint activateConstraints:@[
    [_generateCommitMessageSpinner.centerXAnchor constraintEqualToAnchor:_generateCommitMessageButton.centerXAnchor],
    [_generateCommitMessageSpinner.centerYAnchor constraintEqualToAnchor:_generateCommitMessageButton.centerYAnchor]
  ]];
}

- (void)viewWillAppear {
  [super viewWillAppear];

  XLOG_DEBUG_CHECK(self.repository.statusMode == kGCLiveRepositoryStatusMode_Disabled);
  self.repository.statusMode = kGCLiveRepositoryStatusMode_Normal;

  [self _reloadContents];

  _workdirFilesViewController.selectedDelta = _workdirStatus.deltas.firstObject;
  _indexFilesViewController.selectedDelta = _indexStatus.deltas.firstObject;
}

- (void)viewDidAppear {
  [super viewDidAppear];

  // Remove this logic in a year or so
  [GIRemappingExplanationPopover showIfNecessaryRelativeToRect:NSZeroRect ofView:_commitButton preferredEdge:NSRectEdgeMinY];
}

- (void)viewDidDisappear {
  [super viewDidDisappear];

  _workdirStatus = nil;
  _indexStatus = nil;
  _indexConflicts = nil;

  [_workdirFilesViewController setDeltas:nil usingConflicts:nil];
  [_indexFilesViewController setDeltas:nil usingConflicts:nil];
  [_diffContentsViewController setDeltas:nil usingConflicts:nil];

  XLOG_DEBUG_CHECK(self.repository.statusMode == kGCLiveRepositoryStatusMode_Normal);
  self.repository.statusMode = kGCLiveRepositoryStatusMode_Disabled;
}

- (void)repositoryStatusDidUpdate {
  [super repositoryStatusDidUpdate];

  if (self.viewVisible) {
    [self _reloadContents];
  }
}

- (void)_updateCommitButton {
  _commitButton.enabled = _indexStatus.modified || (self.repository.state == kGCRepositoryState_Merge) || self.amendButton.state;  // Creating an empty commit is OK for a merge or when amending
  _generateCommitMessageButton.enabled = _indexStatus.modified;
}

- (void)_reloadContents {
  CGFloat offset;
  GCDiffDelta* topDelta = [_diffContentsViewController topVisibleDelta:&offset];
  NSArray* selectedWorkdirDeltas = _workdirFilesViewController.selectedDeltas;
  NSUInteger selectedWorkdirRow = selectedWorkdirDeltas.count ? [_workdirStatus.deltas indexOfObjectIdenticalTo:selectedWorkdirDeltas.firstObject] : NSNotFound;
  NSArray* selectedIndexDeltas = _indexFilesViewController.selectedDeltas;
  NSUInteger selectedIndexRow = selectedIndexDeltas.count ? [_indexStatus.deltas indexOfObjectIdenticalTo:selectedIndexDeltas.firstObject] : NSNotFound;

  _disableFeedback = YES;

  _workdirStatus = self.repository.workingDirectoryStatus;
  _indexStatus = self.repository.indexStatus;
  _indexConflicts = self.repository.indexConflicts;

  [_workdirFilesViewController setDeltas:_workdirStatus.deltas usingConflicts:_indexConflicts];
  _workdirFilesViewController.selectedDeltas = selectedWorkdirDeltas;
  if (_workdirStatus.deltas.count && selectedWorkdirDeltas.count && !_workdirFilesViewController.selectedDeltas.count && (selectedWorkdirRow != NSNotFound)) {
    _workdirFilesViewController.selectedDelta = _workdirStatus.deltas[MIN(selectedWorkdirRow, _workdirStatus.deltas.count - 1)];  // If we can't preserve the selected deltas, attempt to preserve the first selected row
  }

  [_indexFilesViewController setDeltas:_indexStatus.deltas usingConflicts:_indexConflicts];
  _indexFilesViewController.selectedDeltas = selectedIndexDeltas;
  if (_indexStatus.deltas.count && selectedIndexDeltas.count && !_indexFilesViewController.selectedDeltas.count && (selectedIndexRow != NSNotFound)) {
    _indexFilesViewController.selectedDelta = _indexStatus.deltas[MIN(selectedIndexRow, _indexStatus.deltas.count - 1)];  // If we can't preserve the selected deltas, attempt to preserve the first selected row
  }

  if (_indexActive) {
    [_diffContentsViewController setDeltas:_indexFilesViewController.selectedDeltas usingConflicts:_indexConflicts];
  } else {
    [_diffContentsViewController setDeltas:_workdirFilesViewController.selectedDeltas usingConflicts:_indexConflicts];
  }
  [_diffContentsViewController setTopVisibleDelta:topDelta offset:offset];

  _disableFeedback = NO;

  _unstageButton.enabled = _indexStatus.modified;
  _stageButton.enabled = _workdirStatus.modified;
  _discardButton.enabled = _workdirStatus.modified;
  [self _updateCommitButton];
}

// We can't use the default implementation since we need a dynamic first-responder
- (NSView*)preferredFirstResponder {
  if (_indexStatus.deltas.count && !_workdirStatus.deltas.count) {
    return _indexFilesViewController.preferredFirstResponder;
  }
  return _workdirFilesViewController.preferredFirstResponder;
}

- (void)didCreateCommit:(GCCommit*)commit {
  [super didCreateCommit:commit];

  _indexActive = NO;
  [self.view.window makeFirstResponder:_workdirFilesViewController.preferredFirstResponder];
}

#pragma mark - GIDiffFilesViewControllerDelegate

- (void)diffFilesViewControllerDidBecomeFirstResponder:(GIDiffFilesViewController*)controller {
  [self diffFilesViewControllerDidChangeSelection:controller];
}

- (void)diffFilesViewControllerDidChangeSelection:(GIDiffFilesViewController*)controller {
  if (!_disableFeedback) {
    if (controller == _workdirFilesViewController) {
      [_diffContentsViewController setDeltas:_workdirFilesViewController.selectedDeltas usingConflicts:_indexConflicts];
      _indexActive = NO;
    } else if (controller == _indexFilesViewController) {
      [_diffContentsViewController setDeltas:_indexFilesViewController.selectedDeltas usingConflicts:_indexConflicts];
      _indexActive = YES;
    } else {
      XLOG_DEBUG_UNREACHABLE();
    }
  }
}

- (void)_stageSelectedFiles:(NSArray*)selectedDeltas {
  NSMutableArray* deltas = [[NSMutableArray alloc] init];
  NSMutableArray* nonSubmoduleDeltasPaths = [[NSMutableArray alloc] init];

  for (GCDiffDelta* delta in selectedDeltas) {
    if (![_indexConflicts objectForKey:delta.canonicalPath]) {
      if (delta.submodule) {
        [self stageSubmoduleAtPath:delta.canonicalPath];
      } else {
        [nonSubmoduleDeltasPaths addObject:delta.canonicalPath];
      }
      [deltas addObject:delta];
    }
  }

  [self stageAllChangesForFiles:nonSubmoduleDeltasPaths];

  if (deltas.count) {
    _disableFeedback = YES;
    _indexFilesViewController.selectedDeltas = deltas;
    _disableFeedback = NO;
    if (!_workdirFilesViewController.deltas.count) {
      _indexActive = YES;
      [self.view.window makeFirstResponder:_indexFilesViewController.preferredFirstResponder];
    }
  } else {
    NSBeep();
  }
}

- (void)_unstageSelectedFiles:(NSArray*)selectedDeltas {
  NSMutableArray* deltas = [[NSMutableArray alloc] init];
  NSMutableArray* nonSubmoduleDeltasPaths = [[NSMutableArray alloc] init];
  for (GCDiffDelta* delta in selectedDeltas) {
    if (![_indexConflicts objectForKey:delta.canonicalPath]) {
      if (delta.submodule) {
        [self unstageSubmoduleAtPath:delta.canonicalPath];
      } else {
        [nonSubmoduleDeltasPaths addObject:delta.canonicalPath];
      }
      [deltas addObject:delta];
    }
  }

  [self unstageAllChangesForFiles:nonSubmoduleDeltasPaths];

  if (deltas.count) {
    _disableFeedback = YES;
    _workdirFilesViewController.selectedDeltas = deltas;
    _disableFeedback = NO;
    if (!_indexFilesViewController.deltas.count) {
      _indexActive = NO;
      [self.view.window makeFirstResponder:_workdirFilesViewController.preferredFirstResponder];
    }
  } else {
    NSBeep();
  }
}

- (void)_diffFilesViewControllerDidPressReturn:(GIDiffFilesViewController*)controller {
  if (controller == _workdirFilesViewController) {
    [self _stageSelectedFiles:_workdirFilesViewController.selectedDeltas];
  } else if (controller == _indexFilesViewController) {
    [self _unstageSelectedFiles:_indexFilesViewController.selectedDeltas];
  } else {
    XLOG_DEBUG_UNREACHABLE();
  }
}

- (void)_diffFilesViewControllerDidPressDelete:(GIDiffFilesViewController*)controller {
  if (controller == _workdirFilesViewController) {
    NSArray* deltas = _workdirFilesViewController.selectedDeltas;
    if (deltas.count) {
      [self confirmUserActionWithAlertType:kGIAlertType_Stop
                                     title:NSLocalizedString(@"Are you sure you want to discard all changes from the selected files?", nil)
                                   message:NSLocalizedString(@"This action cannot be undone.", nil)
                                    button:NSLocalizedString(@"Discard", nil)
                 suppressionUserDefaultKey:nil
                                     block:^{
                                       NSMutableArray* selectedFiles = [NSMutableArray array];

                                       for (GCDiffDelta* delta in deltas) {
                                         NSError* error;
                                         BOOL submodule = delta.submodule;
                                         if (submodule) {
                                           // We handle every submodules deltas individually
                                           if (![self discardSubmoduleAtPath:delta.canonicalPath resetIndex:NO error:&error]) {
                                             [self presentError:error];
                                             break;
                                           }
                                         } else {
                                           // Otherwise we collect file delta paths to batch process them afterwards
                                           [selectedFiles addObject:delta.canonicalPath];
                                         }
                                       }

                                       NSError* error;
                                       if (![self discardAllChangesForFiles:selectedFiles resetIndex:NO error:&error]) {
                                         [self presentError:error];
                                       }

                                       [self.repository notifyWorkingDirectoryChanged];
                                       if (!_workdirFilesViewController.deltas.count) {
                                         _indexActive = YES;
                                         [self.view.window makeFirstResponder:_indexFilesViewController.preferredFirstResponder];
                                       }
                                     }];
    } else {
      NSBeep();
    }
  } else {
    XLOG_DEBUG_CHECK(controller == _indexFilesViewController);
    NSBeep();
  }
}

- (BOOL)diffFilesViewController:(GIDiffFilesViewController*)controller handleKeyDownEvent:(NSEvent*)event {
  // Stage/Unstage files by Return/Delete
  if (!(event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask)) {
    if (event.keyCode == kGIKeyCode_Return) {
      [self _diffFilesViewControllerDidPressReturn:controller];
      return YES;
    } else if (event.keyCode == kGIKeyCode_Delete) {
      [self _diffFilesViewControllerDidPressDelete:controller];
      return YES;
    }
  }

  // Navigate beteween stated and unstaged files list by up/down arrows
  NSEventModifierFlags modifiers = event.modifierFlags & kGIKeyModifiersAll;
  if (controller == _workdirFilesViewController && !modifiers && event.keyCode == kGIKeyCode_Down) {
    bool onlyLastFileSelected = (controller.selectedDeltas.count == 1) && (controller.selectedDelta == controller.deltas.lastObject);
    bool hasIndexFiles = _indexFilesViewController.deltas.count > 0;
    if (onlyLastFileSelected && hasIndexFiles) {
      // move focus to next controller
      [[controller.view window] selectNextKeyView:_workdirFilesViewController.view];
      return YES;
    }
  } else if (controller == _indexFilesViewController && !modifiers && event.keyCode == kGIKeyCode_Up) {
    bool onlyFirstFileSelected = (controller.selectedDeltas.count == 1) && (controller.selectedDelta == controller.deltas.firstObject);
    bool hasWorkdirFiles = _workdirFilesViewController.deltas.count > 0;
    if (onlyFirstFileSelected && hasWorkdirFiles) {
      // move focus to previous controller
      [[controller.view window] selectPreviousKeyView:_workdirFilesViewController.view];
      return YES;
    }
  }

  // Perform contextual action on a file
  if (controller == _workdirFilesViewController) {
    return [self handleKeyDownEvent:event forSelectedDeltas:_workdirFilesViewController.selectedDeltas withConflicts:_indexConflicts allowOpen:YES];
  } else if (controller == _indexFilesViewController) {
    return [self handleKeyDownEvent:event forSelectedDeltas:_indexFilesViewController.selectedDeltas withConflicts:_indexConflicts allowOpen:YES];
  }

  return NO;
}

- (void)diffFilesViewController:(GIDiffFilesViewController*)controller didDoubleClickDeltas:(NSArray*)deltas {
  if (controller == _workdirFilesViewController) {
    [self _stageSelectedFiles:deltas];
  } else if (controller == _indexFilesViewController) {
    [self _unstageSelectedFiles:deltas];
  } else {
    XLOG_DEBUG_UNREACHABLE();
  }
}

- (BOOL)diffFilesViewControllerShouldAcceptDeltas:(GIDiffFilesViewController*)controller fromOtherController:(GIDiffFilesViewController*)otherController {
  return ((controller == _workdirFilesViewController) && (otherController == _indexFilesViewController)) || ((controller == _indexFilesViewController) && (otherController == _workdirFilesViewController));
}

- (BOOL)diffFilesViewController:(GIDiffFilesViewController*)controller didReceiveDeltas:(NSArray*)deltas fromOtherController:(GIDiffFilesViewController*)otherController {
  if ((controller == _workdirFilesViewController) && (otherController == _indexFilesViewController)) {
    NSMutableArray* fileDeltas = [NSMutableArray array];
    for (GCDiffDelta* delta in deltas) {
      if (![_indexConflicts objectForKey:delta.canonicalPath]) {
        if (delta.submodule) {
          [self unstageSubmoduleAtPath:delta.canonicalPath];
        } else {
          [fileDeltas addObject:delta.canonicalPath];
        }
      }
    }
    [self unstageAllChangesForFiles:fileDeltas];
    _disableFeedback = YES;
    _workdirFilesViewController.selectedDeltas = deltas;
    _disableFeedback = NO;
    if (!_indexFilesViewController.deltas.count) {
      _indexActive = NO;
      [self.view.window makeFirstResponder:_workdirFilesViewController.preferredFirstResponder];
    }
    return YES;
  } else if ((controller == _indexFilesViewController) && (otherController == _workdirFilesViewController)) {
    NSMutableArray* fileDeltas = [NSMutableArray array];
    for (GCDiffDelta* delta in deltas) {
      if (![_indexConflicts objectForKey:delta.canonicalPath]) {
        if (delta.submodule) {
          [self stageSubmoduleAtPath:delta.canonicalPath];
        } else {
          [fileDeltas addObject:delta.canonicalPath];
        }
      }
    }
    [self stageAllChangesForFiles:fileDeltas];
    _disableFeedback = YES;
    _indexFilesViewController.selectedDeltas = deltas;
    _disableFeedback = NO;
    if (!_workdirFilesViewController.deltas.count) {
      _indexActive = YES;
      [self.view.window makeFirstResponder:_indexFilesViewController.preferredFirstResponder];
    }
    return YES;
  } else {
    XLOG_DEBUG_UNREACHABLE();
  }
  return NO;
}

#pragma mark - GIDiffContentsViewControllerDelegate

- (void)_diffContentsViewControllerDidPressReturn:(GIDiffContentsViewController*)controller {
  NSMutableArray* deltas = [[NSMutableArray alloc] init];
  for (GCDiffDelta* delta in _diffContentsViewController.deltas) {
    NSIndexSet* oldLines;
    NSIndexSet* newLines;
    if ([_diffContentsViewController getSelectedLinesForDelta:delta oldLines:&oldLines newLines:&newLines]) {
      if (_indexActive) {
        [self unstageSelectedChangesForFile:delta.canonicalPath oldLines:oldLines newLines:newLines];
      } else {
        [self stageSelectedChangesForFile:delta.canonicalPath oldLines:oldLines newLines:newLines];
      }
      [deltas addObject:delta];
    }
  }
  _disableFeedback = YES;
  if (_indexActive) {
    _workdirFilesViewController.selectedDeltas = deltas;
  } else {
    _indexFilesViewController.selectedDeltas = deltas;
  }
  _disableFeedback = NO;
  if ((_indexActive && !_indexFilesViewController.deltas.count) || (!_indexActive && !_workdirFilesViewController.deltas.count)) {
    _indexActive = !_indexActive;
  }
  [self.view.window makeFirstResponder:(_indexActive ? _indexFilesViewController.preferredFirstResponder : _workdirFilesViewController.preferredFirstResponder)];
}

- (void)_diffContentsViewControllerDidPressDelete:(GIDiffContentsViewController*)controller {
  if (!_indexActive) {
    BOOL hasSelection = NO;
    for (GCDiffDelta* delta in _diffContentsViewController.deltas) {
      if ([_diffContentsViewController getSelectedLinesForDelta:delta oldLines:NULL newLines:NULL]) {
        hasSelection = YES;
        break;
      }
    }
    if (hasSelection) {
      [self confirmUserActionWithAlertType:kGIAlertType_Stop
                                     title:NSLocalizedString(@"Are you sure you want to discard all selected changed lines?", nil)
                                   message:NSLocalizedString(@"This action cannot be undone.", nil)
                                    button:NSLocalizedString(@"Discard", nil)
                 suppressionUserDefaultKey:nil
                                     block:^{
                                       for (GCDiffDelta* delta in _diffContentsViewController.deltas) {
                                         NSIndexSet* oldLines;
                                         NSIndexSet* newLines;
                                         if ([_diffContentsViewController getSelectedLinesForDelta:delta oldLines:&oldLines newLines:&newLines]) {
                                           NSError* error;
                                           if (![self discardSelectedChangesForFile:delta.canonicalPath oldLines:oldLines newLines:newLines resetIndex:NO error:&error]) {
                                             [self presentError:error];
                                             break;
                                           }
                                         }
                                       }
                                       [self.repository notifyWorkingDirectoryChanged];
                                       if (!_workdirFilesViewController.deltas.count) {
                                         _indexActive = !_indexActive;
                                       }
                                       [self.view.window makeFirstResponder:(_indexActive ? _indexFilesViewController.preferredFirstResponder : _workdirFilesViewController.preferredFirstResponder)];
                                     }];
    } else {
      NSBeep();
    }
  } else {
    NSBeep();
  }
}

- (BOOL)diffContentsViewController:(GIDiffContentsViewController*)controller handleKeyDownEvent:(NSEvent*)event {
  if (!(event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask)) {
    if (event.keyCode == kGIKeyCode_Return) {
      [self _diffContentsViewControllerDidPressReturn:controller];
      return YES;
    } else if (event.keyCode == kGIKeyCode_Delete) {
      [self _diffContentsViewControllerDidPressDelete:controller];
      return YES;
    }
  }
  return NO;
}

- (NSString*)diffContentsViewController:(GIDiffContentsViewController*)controller actionButtonLabelForDelta:(GCDiffDelta*)delta conflict:(GCIndexConflict*)conflict {
  if (!conflict) {
    if (_indexActive) {
      if (delta.submodule) {
        return NSLocalizedString(@"Unstage Submodule", nil);
      } else if ([_diffContentsViewController getSelectedLinesForDelta:delta oldLines:NULL newLines:NULL]) {
        return NSLocalizedString(@"Unstage Lines", nil);
      } else {
        return NSLocalizedString(@"Unstage File", nil);
      }
    } else {
      if (delta.submodule) {
        return NSLocalizedString(@"Stage Submodule", nil);
      } else if ([_diffContentsViewController getSelectedLinesForDelta:delta oldLines:NULL newLines:NULL]) {
        return NSLocalizedString(@"Stage Lines", nil);
      } else {
        return NSLocalizedString(@"Stage File", nil);
      }
    }
  }
  return nil;
}

- (void)diffContentsViewController:(GIDiffContentsViewController*)controller didClickActionButtonForDelta:(GCDiffDelta*)delta conflict:(GCIndexConflict*)conflict {
  NSIndexSet* oldLines;
  NSIndexSet* newLines;
  if (_indexActive) {
    if (delta.submodule) {
      [self unstageSubmoduleAtPath:delta.canonicalPath];
    } else if ([_diffContentsViewController getSelectedLinesForDelta:delta oldLines:&oldLines newLines:&newLines]) {
      [self unstageSelectedChangesForFile:delta.canonicalPath oldLines:oldLines newLines:newLines];
    } else {
      [self unstageAllChangesForFile:delta.canonicalPath];
    }
    _disableFeedback = YES;
    _workdirFilesViewController.selectedDelta = delta;
    _disableFeedback = NO;
  } else {
    if (delta.submodule) {
      [self stageSubmoduleAtPath:delta.canonicalPath];
    } else if ([_diffContentsViewController getSelectedLinesForDelta:delta oldLines:&oldLines newLines:&newLines]) {
      [self stageSelectedChangesForFile:delta.canonicalPath oldLines:oldLines newLines:newLines];
    } else {
      [self stageAllChangesForFile:delta.canonicalPath];
    }
    _disableFeedback = YES;
    _indexFilesViewController.selectedDelta = delta;
    _disableFeedback = NO;
  }
}

- (NSMenu*)diffContentsViewController:(GIDiffContentsViewController*)controller willShowContextualMenuForDelta:(GCDiffDelta*)delta conflict:(GCIndexConflict*)conflict {
  NSMenu* menu = [self contextualMenuForDelta:delta withConflict:conflict allowOpen:YES];

  if (!_indexActive && !conflict) {
    [menu addItem:[NSMenuItem separatorItem]];

    if (GC_FILE_MODE_IS_FILE(delta.oldFile.mode) || GC_FILE_MODE_IS_FILE(delta.newFile.mode)) {
      if (delta.change == kGCFileDiffChange_Untracked) {
        [menu addItemWithTitle:NSLocalizedString(@"Delete File…", nil)
                         block:^{
                           [self deleteUntrackedFile:delta.canonicalPath];
                         }];
      } else {
        if ([controller getSelectedLinesForDelta:delta oldLines:NULL newLines:NULL]) {
          [menu addItemWithTitle:NSLocalizedString(@"Discard Line Changes…", nil)
                           block:^{
                             NSIndexSet* oldLines;
                             NSIndexSet* newLines;
                             [_diffContentsViewController getSelectedLinesForDelta:delta oldLines:&oldLines newLines:&newLines];
                             [self discardSelectedChangesForFile:delta.canonicalPath oldLines:oldLines newLines:newLines resetIndex:NO];
                           }];
        } else {
          [menu addItemWithTitle:NSLocalizedString(@"Discard File Changes…", nil)
                           block:^{
                             [self discardAllChangesForFile:delta.canonicalPath resetIndex:NO];
                           }];
        }
      }
    } else if (delta.submodule) {
      [menu addItemWithTitle:NSLocalizedString(@"Discard Submodule Changes…", nil)
                       block:^{
                         [self discardSubmoduleAtPath:delta.canonicalPath resetIndex:NO];
                       }];
    }
  }

  return menu;
}

#pragma mark - NSTextViewDelegate

// Intercept Option-Return key in NSTextView and forward to next responder
- (BOOL)textView:(NSTextView*)textView doCommandBySelector:(SEL)selector {
  if (selector == @selector(insertNewlineIgnoringFieldEditor:)) {
    return [self.view.window.firstResponder.nextResponder tryToPerform:@selector(keyDown:) with:[NSApp currentEvent]];
  }
  return [super textView:textView doCommandBySelector:selector];
}

#pragma mark - Actions

// Override
- (IBAction)toggleAmend:(id)sender {
  [super toggleAmend:sender];

  [self _updateCommitButton];
}

- (IBAction)discardAll:(id)sender {
  [self discardAllFiles];
}

- (IBAction)stageAll:(id)sender {
  [self stageAllFiles];
  [self.view.window makeFirstResponder:_indexFilesViewController.preferredFirstResponder];
}

- (IBAction)unstageAll:(id)sender {
  [self unstageAllFiles];
  [self.view.window makeFirstResponder:_workdirFilesViewController.preferredFirstResponder];
}

- (IBAction)commit:(id)sender {
  if (_indexConflicts.count) {
    [self presentAlertWithType:kGIAlertType_Stop title:NSLocalizedString(@"You must resolve conflicts before committing!", nil) message:nil];
    return;
  }
  NSString* message = [self.messageTextView.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!message.length) {
    [self presentAlertWithType:kGIAlertType_Stop title:NSLocalizedString(@"You must provide a non-empty commit message", nil) message:nil];
    return;
  }
  [self createCommitFromHEADWithMessage:message];
  [self _updateCommitButton];
}

- (IBAction)generateCommitMessage:(id)sender {
  NSError* error;
  NSString* prompt = [self _commitPromptText:&error];
  if (!prompt) {
    [self presentError:error];
    return;
  }
  NSString* diffText = [self _stagedDiffText:&error];
  if (diffText == nil) {
    [self presentError:error];
    return;
  }
  if (diffText.length == 0) {
    [self presentAlertWithType:kGIAlertType_Note title:NSLocalizedString(@"No staged changes to summarize", nil) message:nil];
    return;
  }

  NSString* input = [NSString stringWithFormat:@"%@\n\n%@", prompt, diffText];
  _generateCommitMessageButton.enabled = NO;
  _generateCommitMessageButton.image = nil;
  [_generateCommitMessageSpinner startAnimation:nil];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError* taskError;
    NSString* output = [self _runCodexExecWithInput:input error:&taskError];
    dispatch_async(dispatch_get_main_queue(), ^{
      _generateCommitMessageButton.enabled = YES;
      [_generateCommitMessageSpinner stopAnimation:nil];
      _generateCommitMessageButton.image = _generateCommitMessageImage;
      if (!output) {
        [self presentError:taskError];
        return;
      }
      NSString* trimmed = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if (!trimmed.length) {
        [self presentAlertWithType:kGIAlertType_Note title:NSLocalizedString(@"No commit message generated", nil) message:nil];
        return;
      }
      NSMutableString* message = [self.messageTextView.string mutableCopy];
      if (message.length && ![message hasSuffix:@"\n"]) {
        [message appendString:@"\n"];
      }
      [message appendString:trimmed];
      self.messageTextView.string = message;
      [self.messageTextView setSelectedRange:NSMakeRange(self.messageTextView.string.length, 0)];
      [self _updateCommitButton];
    });
  });
}

@end
