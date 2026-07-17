# Pace

A macOS app.

## Requirements
- macOS 13 or later
- Xcode 16 or later (command-line tools) to build from source
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build
The Xcode project is generated from `project.yml`; `*.xcodeproj` is not committed.

```sh
brew install xcodegen
cp Configuration/Local.xcconfig.example Configuration/Local.xcconfig   # set your Team ID + bundle id
xcodegen generate
open Pace.xcodeproj    # or build from the command line:

xcodebuild -project Pace.xcodeproj -scheme Pace \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## Release
Signed and notarized builds are produced entirely from the command line:

```sh
scripts/publish-release.sh --dry-run    # preview
scripts/publish-release.sh --publish    # build, notarize, and publish a GitHub release
```

See [CLAUDE.md](CLAUDE.md) for the full build/test/release reference.
