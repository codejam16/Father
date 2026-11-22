# Personal signing setup

The scanner and Apple foreground masks branches share the same local signing
file. Configure it once per checkout; it stays on your Mac when you switch
between those branches. The shared project and its generator contain variables
instead of anyone's Apple team ID or personal bundle identifier.

## Import an existing working setup

If you previously committed your working Xcode signing settings, import that
commit (run from the repository root):

```bash
python3 scripts/configure-signing.py --from-commit YOUR_SAVED_COMMIT_SHA
```

The helper reads the app's Debug and Release values from that local commit and
writes `ios/Config/Signing.local.xcconfig`. It does not change project.pbxproj,
reset Git history, or overwrite an existing local file. Conflicting Debug/Release
identities require an explicit choice. Keep the old commit/backup until your
device build works with the new setup.

## Set up a new teammate

Supply the team ID and a unique personal bundle identifier:

```bash
python3 scripts/configure-signing.py --team YOURTEAMID --bundle-id dev.yourname.codejam16.tasklens
```

Alternatively, copy `ios/Config/Signing.example.xcconfig` to
`ios/Config/Signing.local.xcconfig` and edit its two values. Use the team ID
associated with your Apple development account/certificate. An existing working
Xcode project also records it as `DEVELOPMENT_TEAM` in project.pbxproj; importing
that saved project is usually easier than looking it up again.

Reopen `ios/TaskLens.xcodeproj`, select the TaskLens scheme and your connected
iPhone, then Run. Xcode must still be signed into your Apple account. Automatic
signing remains enabled for the app and tests. Both Debug and Release inherit
your local team; the test bundle uses your app bundle ID plus `.tests`.

## Future changes and pulls

- Edit `Signing.local.xcconfig` when changing your personal team or bundle ID.
  Xcode's Team/Bundle Identifier controls can still write overrides into the
  shared project, so use the local file to keep those changes personal.
- Git ignores the local file. Commit the project, shared config, template, and
  source changes normally; keep the project itself tracked.
- `Signing.xcconfig` optionally includes the local file. A fresh checkout can
  open and build unsigned for the simulator without it. Device installation
  needs the one-time personal setup.
- Running `generate-xcode-project.py` retains variable-based signing and leaves
  the local file intact. Existing unrelated custom project changes still need
  review when regenerating.
- If pulling this migration is blocked by local project edits, stash/back up
  those edits first. Import your saved signing values after the pull; applying
  the entire old project file again would restore the personal overrides.
- Branches that have not received this setup still use their own project
  settings. This change was applied to `starter/visual-assistant` and
  `experiment/apple-foreground-masks`.

Check the shared configuration before committing Xcode project edits:

```bash
python3 scripts/configure-signing.py --check-shared
python3 scripts/test-signing.py
```

The Python tests cover old-commit migration, ignored local files, preserving
existing settings, rejecting malformed inputs, and stable project generation.
They do not replace building and installing with Xcode on a Mac.

## If Xcode shows a variable or a personal override was entered

`$(TASKLENS_BUNDLE_IDENTIFIER)` in the project editor is intentional. It reads
`TASKLENS_BUNDLE_IDENTIFIER` from your ignored local file. It should not become
the literal installed bundle identifier. Show the configured local values with:

```bash
python3 scripts/configure-signing.py --show
```

The setup helper also prints the actual configured local team and bundle ID
after saving them. If you changed signing through Xcode or imported the wrong
local values, explicitly repair the project references and re-import a known
working commit:

```bash
python3 scripts/configure-signing.py --from-commit YOUR_SAVED_COMMIT_SHA --repair-project --replace-local
```

Close Xcode first. This only repairs the app/test team and bundle settings in
Debug/Release. It leaves unrelated project settings alone. Any replaced local
file and the project before repair are backed up under the Git-ignored
`.build/signing-backups/` directory. The personal IDs stay in the ignored local
file. Reopen Xcode after setup so it reloads the configuration.
