# Implement profiles

Initial implementation on `codex/implement-profile-library`.

## Local test build naming

Use `FS25_Courseplay_ImplementProfilesTest.zip` for future local tests, with the in-game title
`CoursePlay - Implement Profiles Test`. The current output location is
`dist/implement-profile-library/FS25_Courseplay_ImplementProfilesTest.zip`.

Keep this filename stable: it determines the test mod's identity and separate settings/profile
directory. The user keeps the live and test ZIPs together and enables only one per save. Do not
replace the live `FS25_Courseplay.zip` when preparing a local test build.

The test package's `modDesc.xml` titles carry the ` - Implement Profiles Test` suffix in each
language. The source manifest retains its release title; the build script's `--output` option alone
does not add the test title suffix.

## Using the library

Open CP's **Implement profiles** page. **Attached equipment** shows exact and partial matches;
**All profiles** allows browsing without entering a tractor. Expand an implement type, then a model
or combination, to see its saved profiles. Combinations
also appear under their component implement types; these are links to one saved profile.

With the tractor and CP stopped, adjust vehicle and course generation settings, then select
**Save as new**. Select a matching profile and choose **Apply profile** to reuse it. **Update profile**
replaces the selected entry with the current settings and increments its revision. **Save as new**
keeps alternatives as separate named entries. Deleting or updating a library entry does not change
working copies already applied to vehicles.

After attachment changes settle, an entered, stationary vehicle offers to open matching profiles.
Profiles are never applied automatically. Partial matches can be inspected but cannot be applied to
an entire combination. Courses are not generated or replaced by applying a profile. A differing
course working width prompts the user to generate or load a suitable course.

## Persistence and matching

- The personal library lives in `modSettings/<CP mod name>/implementProfiles.xml`, outside savegames
  and map folders. Its schema version is separate from each profile's revision.
- Saving validates a temporary XML file, backs up the existing library to `.bak`, then installs the
  new file. This is a recoverable replacement, not an atomic filesystem rename. Damaged libraries
  use a valid backup in read-only mode. Unknown schema versions remain read-only.
- Vehicle savegames retain the selected ID, revision, complete working settings snapshot and the
  previous settings needed when equipment changes. Existing CP settings and course persistence remain
  intact. A savegame can resume without the personal library.
- Matching uses the mod namespace, portable equipment XML path, functional configurations, mounting
  side and attachment tree. It preserves duplicate implements and excludes an ordinary tractor's model.
  Cosmetic colour options are ignored. Variable width sections and sprayer fill type names distinguish
  operating configurations. Self-propelled working machines retain their own model identity.
- Matching is deliberately conservative: attaching accessories or changing a functional configuration
  may require a new combination profile. Dynamic-mounted equipment on a transport trailer is not
  treated as an attached working implement.

## Settings ownership

`ImplementProfile.SETTINGS` is the explicit portable allow-list. It covers fieldwork behaviour,
implement controls, selected speeds and course generation preferences. Disabled settings, such as
plough offsets controlled by the driving strategy, are excluded when saving.

Tractor turning radius, HUD preferences, debugging, course waypoints, field positions, manual row
angle, field margins and job progress are excluded. Turning radius and geometry are recalculated
when changing equipment. Changing a field-specific setting does not update the library.

The attachment debounce runs after existing CP attachment and load callbacks. It restores the saved
working copy after load or clears the old profile when its combination no longer matches. A manual
job adjustment is preserved during transient callbacks and included in the savegame snapshot.

## Multiplayer

Libraries are personal to each installation, including a host's installation. Applying a client
profile sends its values to the server. The server checks farm access, stationary/inactive state,
equipment identity and every setting before applying and broadcasting the working copy. It never
trusts a client to broadcast authoritative state. Joining clients receive the working snapshot and
profile metadata without needing the library file. Library editing does not write another player's
personal library.

The permission lookup uses the game's user-to-farm mapping and CP's existing `canFarmAccess` API.
See the [GIANTS event example](https://gdn.giants-software.com/documentation_scripting_fs25.php?category=1&class=93&version=script)
for the user-to-farm mapping.

## Validation

### Implement timing and vehicle overrides

The vehicle settings page has one **Tool timing** section. Each raise/lower override switch is
followed by a single timing row. With override off, the row displays the implement default read-only.
With override on, it displays the editable vehicle value. Switching off restores the default display
without erasing the manual choice. Implement defaults are edited in the profile library. Overrides
use the existing vehicle savegame and multiplayer settings system and are excluded from profiles.
Applying another profile changes the defaults without changing the vehicle's override choices.

Library saves verify the parsed contents of the temporary file, backup and installed library.
They do not depend on a boolean return from the engine's `copyFile` function. A valid older file does
not count as a successful replacement. A profile already written by the previous build despite its
error dialogue will load normally on the next game start.

Run `lua ImplementProfileTest.lua` from `scripts/test` using Lua 5.1. The suite covers portable
identity, combinations, configurations, XML persistence/recovery, working-copy ownership, attachment
timing, multiplayer messages and the expandable directory model. The automated tests use engine
boundary mocks; they cannot verify game rendering, controller focus or live network timing.

Before merging, verify in Farming Simulator 25:

1. Existing savegames load without a profile library; existing courses and settings remain usable.
2. Save a single implement setup, apply it on another tractor, then on another map/save.
3. Save a front/rear combination; change attachment order and then remove one component. Check exact
   and partial suggestions, restoration of previous settings and the expandable type groups.
4. Edit working settings, save/reload, update the library and delete its entry. The running job's
   saved snapshot must remain independent.
5. Change sprayer material and variable sections. Verify that incompatible profiles are not applied.
6. Verify mouse/controller navigation, scrolling, long names, empty results and width warnings.
7. Test a host plus two clients: application, joining after application, attachment changes, an
   unauthorised farm and saving/reloading a dedicated server.
8. Set opposite implement and vehicle raising/lowering timings. Toggle each override, switch profiles,
   save/update a profile and reload the savegame. Confirm overrides stay vehicle-specific and fieldwork
   uses the selected source.

Further work can add dedicated import/export controls, user-configurable matching rules and profile
coverage for vine generation, bunker silos and unloading jobs. Profiles can currently be moved between
installations by copying the library file while the game is closed; merging libraries is not provided.

## Fieldwork setup flow

Open Course generation > Fieldwork Settings. The first row is an implement profile selector,
filtered to exact matches for the attached equipment or complete combination. Select a profile and
choose Load profile (or press the selector centre), adjust the fieldwork settings, then generate.
Selecting Keep current settings leaves the working setup unchanged. With no matches the selector
shows an explanation and is disabled; use the Implement Profiles directory to save a setup.
The current library revision is selected when it matches the applied working profile. Loading uses
existing equipment, access and stationary checks, preserves vehicle timing overrides and warns if
an existing course has a different width. The directory remains available for library management.

## Naming and editing saved profiles

The save dialogue explains that equipment is identified automatically: use setup names such as
7 headlands, 12 headlands or Work in lands. Select a profile and choose Rename profile to change
its name without capturing tractor settings. Rename preserves its ID and increments its revision.

The details pane displays setting names and values in separate columns. Choose Edit profile,
adjust the inline selectors in the value column. Save changes commits
a new library revision; Cancel changes or leaving the page discards the draft. Editing does not
require a tractor and does not alter an already applied vehicle setup. Update profile remains the
separate action for capturing the current tractor setup. Renames and edits reject stale revisions
and preserve the previous library on save failure.

Only the named test ZIP is left in the test output directory; intermediate release-named archives
are not retained there.

## Attachment pop-ups

In Global settings > User settings, deactivate **Suggest implement profiles on attachment** to
silence attachment prompts. The preference is enabled by default and saved per user across vehicles
and savegames. It does not disable matching, the Fieldwork Settings selector or manual application.
Re-enabling it offers suggestions on subsequent equipment changes, without replaying dismissed
pending prompts.

## Advanced equipment configurations (placeholder)

The Advanced button opens an explanatory placeholder only. No configuration loader, writer or
runtime override is added. The intended scope includes tractor corrections, attached implements,
self-propelled working machines and removable headers, based on their actual working capabilities
and attachment structure rather than crop names. Equipment corrections should remain separate from
named fieldwork setups.

Current identity matching includes recognised working root machines (for example `spec_combine`)
as a `self` equipment item. An integrated machine can therefore have a single-machine profile;
a removable header becomes another item in its combination. Ordinary tractors are excluded.
Changing/removing a header prevents an exact match. These rules have mock boundary coverage;
specific game/mod machines need their specialisations checked before claiming universal support.

## Single-profile quick loading

Global Settings > User Settings contains two independent preferences. Attachment suggestions remain
on by default; Auto-load a single matching profile is off by default.

- Suggestions on (either auto-load setting), exactly one match: choose Load profile, View profiles or Don't load a profile. Cancelling loads nothing.
- Suggestions off, auto-load on: one exact match loads silently; multiple matches stay manual.
- Both off: no attachment prompt or automatic loading.

Loading runs only for the entered, stationary, inactive vehicle after attachment debounce, using
normal access and server validation. Existing applied profiles are preserved. Silent loading is
skipped when an existing course has a different work width; load manually to review that warning.

When attachment prompts are enabled and several profiles match, the native option dialogue lists
Don't load a profile first, followed by matching profile names and View profiles. Confirming a named
profile loads that selection through the same validation and course-width warning as single-profile
loading. Cancel or Don't load a profile leaves the current values unchanged. No profile is selected
automatically when several match.

Edit profile and Rename profile are bottom-bar actions for a selected profile. Editing keeps the
same details column and uses inline left/right value selectors; no per-setting selection dialogue
is needed. Save and Cancel remain at the bottom. More actions contains Save as new, Update from the
current tractor (when available), and Delete.

The attachment chooser now uses a dedicated dialogue titled Matching implement profiles. Its
selector contains profile names only, for both one and multiple matches. Separate Load profile,
View profiles and Don't load a profile buttons perform the actions. Closing or cancelling loads
nothing. Existing silent auto-load preferences and validation are unchanged.

## Direct bottom-bar actions

The directory no longer has More actions. Save as new stays available whenever the current tractor
setup can be saved, including while a library profile is selected. A matching selected profile has
Load profile; editable library entries also have Edit, Rename and Delete, plus Update profile when
the current tractor matches. Editing shows only Save changes, Cancel changes and Back. Page
navigation remains on the tabs so the seven footer slots hold useful profile actions. Rename and
Delete have dedicated rebindable actions (Shift+R and Delete by default); deletion still requires
confirmation.

Attachment offers and silent automatic loading are queued only by a new ATTACH event after vehicle
initialisation. Startup processing of equipment already connected in the savegame and ordinary
geometry refreshes do not queue an offer. Saved working profiles still restore normally.
The chooser uses the native dialogue background slices without a full-screen dimming layer.
Its shell is a private clone of the loaded FS25 Yes/No dialogue, with the stock text and buttons
replaced by the profile selector and three actions. The shared dialogue is unchanged. The native
MultiTextOption's names and initial selection are set after opening.

The Fieldwork Settings selector uses Custom settings for the current manual setup. Changing a
fieldwork control switches it to Custom settings without changing the saved library entry.
On reopening, an applied profile is selected only if its saved revision and stored values still
match. Vehicle-specific timing overrides do not mark the implement defaults as modified.

Generate automatically applies the selected implement profile before creating the course.
Custom settings generates directly from the current working values, without loading or saving a
profile. Clients wait for accepted server state; failed or timed-out loads do not generate a course.
The Implement Profiles sidebar and heading use the approved option A plough-and-gear icon.

The directory uses one Show filter: Attached equipment or All equipment. Opening it from a
vehicle defaults to attached equipment, expands the matching tree and selects the active saved
profile. Advanced remains a separate placeholder action.

Global User Settings includes When no profile is loaded: Use defaults (initial choice) or Keep
current settings. New attachments start with that policy before an optional profile is loaded.
Defaults reset the profile allow-list and detect equipment width; Keep retains the previous
working values as custom settings. Vehicle timing overrides are excluded. Startup attachments
do not trigger this policy. Reset requests are validated and applied on the server.
