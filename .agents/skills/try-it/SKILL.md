---
name: try-it
description: Build the current changes and hand them to the user to try. Use whenever the user says "try it", "try it out", "let me try", or asks to try out changes you've made — stop the running app, build Release, install to /Applications (overwriting any existing version), relaunch, and tell the user it's ready.
---

# Try It: build, install, and relaunch Pace

Ship the working tree into /Applications and start the app.

1. Regenerate the project if `project.yml` changed or `Pace.xcodeproj` is missing:
   ```sh
   xcodegen generate
   ```

2. Stop any running copy (fine if none is running):
   ```sh
   pkill -x Pace || true
   ```

3. Build Release into local derived data, signed with Developer ID — a stable
   signature keeps macOS permission grants (Accessibility etc.) across reinstalls:
   ```sh
   xcodebuild -project Pace.xcodeproj -scheme Pace -configuration Release \
     -derivedDataPath build build \
     CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=93W5N4LQL7 \
     "CODE_SIGN_IDENTITY=Developer ID Application" \
     "OTHER_CODE_SIGN_FLAGS=--timestamp"
   ```
   Always keep these manual signing overrides. The wvlen team has no Apple
   Development certificate, so automatic/project-settings signing silently
   falls back to a personal-team development cert — and TCC will show the
   Accessibility consent dialog for such a build yet never add it to the
   Accessibility list, breaking paste onboarding. After building, confirm
   `codesign -dvvv` reports `Authority=Developer ID Application: wvlen LLC`.

   If the build fails: report the failure and stop — leave the installed copy alone.

4. Replace the installed app. Remove first — `ditto` merges into an existing
   bundle, which can leave stale files behind. macOS binds permission grants
   (TCC) to the code signature, and a leftover record from a differently
   signed copy silently blocks new permission prompts — compare designated
   requirements and reset only when they differ, so same-signature reinstalls
   keep their grants:
   ```sh
   old_req="$(codesign -d -r- /Applications/Pace.app 2>/dev/null || true)"
   new_req="$(codesign -d -r- build/Build/Products/Release/Pace.app 2>/dev/null || true)"
   rm -rf /Applications/Pace.app
   ditto build/Build/Products/Release/Pace.app /Applications/Pace.app
   if [ -n "$old_req" ] && [ "$old_req" != "$new_req" ]; then
     echo "Code signature changed; clearing stale permission records..."
     tccutil reset Accessibility llc.wvlen.Pace || true
     tccutil reset PostEvent llc.wvlen.Pace || true
   fi
   ```
   Writing to /Applications is outside the workspace, so the sandboxed shell may
   deny it — rerun that step with the sandbox disabled if so. If the reset ran,
   tell the user to re-grant Accessibility from the Pace menu bar icon.

5. Verify the signature survived the copy, then launch:
   ```sh
   codesign --verify --strict /Applications/Pace.app
   open /Applications/Pace.app
   ```

6. Tell the user the new build is installed and running. Pace is a menu-bar app
   (`LSUIElement`), so there is no Dock icon — point them at the clipboard icon
   in the menu bar.
