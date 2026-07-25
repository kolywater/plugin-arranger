# Justfile — PluginArranger
#
#   just reload            Build Debug, relaunch the app
#   just log               Tail the debug log
#   just signing           Show the signature + designated requirement
#   just export            Build Release, copy to Dropbox
#   just release 1.5       Bump version, build, zip, tag, publish to GitHub
#
# Single macOS target, so this is self-contained — no shared scripts/just
# infrastructure to import.

set shell := ["bash", "-euo", "pipefail", "-c"]

project := "PluginArranger.xcodeproj"
scheme := "PluginArranger"
app_name := "PluginArranger.app"
build_root := justfile_directory() / "build"
debug_log := "/tmp/pluginarranger.log"
dropbox_dir := env('HOME') / "Dropbox/music/aidenel songs"

[private]
default:
    @just --list

# Build for a configuration (Debug or Release)
[group('build')]
build configuration="Debug":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    xcodebuild -project "{{project}}" \
      -scheme "{{scheme}}" \
      -configuration "{{configuration}}" \
      -derivedDataPath "{{build_root}}" \
      -quiet
    echo "Built {{build_root}}/Build/Products/{{configuration}}/{{app_name}}"

# Rebuild and relaunch (kill running instance first)
[group('build')]
reload configuration="Debug": (build configuration)
    #!/usr/bin/env bash
    set -euo pipefail
    app="{{build_root}}/Build/Products/{{configuration}}/{{app_name}}"
    pkill -x "{{scheme}}" 2>/dev/null || true
    # The build tree inherits com.apple.quarantine from its Dropbox-synced
    # inputs. Left in place, Gatekeeper blocks the unnotarized build and App
    # Translocation runs it from a random read-only mount — which also breaks
    # the TCC grant, since the path keeps changing.
    # Delete only the quarantine attribute — `xattr -cr` clears everything and
    # fails on the protected com.apple.macl / com.apple.provenance attributes.
    xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
    open "$app"
    echo "Launched $app"
    echo "Logs: just log"

# Tail the debug log
[group('build')]
log:
    @tail -F "{{debug_log}}"

# Show how the built app is signed. The designated requirement is the thing
# that decides whether the accessibility grant survives a rebuild: it must be
# team-based, NOT a bare `cdhash H"..."` (that means ad-hoc, and TCC will drop
# the grant every time the binary changes).
[group('build')]
signing configuration="Debug":
    #!/usr/bin/env bash
    set -euo pipefail
    app="{{build_root}}/Build/Products/{{configuration}}/{{app_name}}"
    [[ -d "$app" ]] || { echo "Not built: $app — run 'just build {{configuration}}'"; exit 1; }
    codesign -dvv "$app" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Signature" || true
    echo "--- designated requirement ---"
    codesign -d -r- "$app" 2>&1 | grep "designated"
    echo "--- gatekeeper ---"
    spctl -a -vvv -t exec "$app" 2>&1 || true

# Build Release and copy to Dropbox
[group('build')]
export: (build "Release")
    #!/usr/bin/env bash
    set -euo pipefail
    app="{{build_root}}/Build/Products/Release/{{app_name}}"
    dest="{{dropbox_dir}}/{{app_name}}"
    mkdir -p "{{dropbox_dir}}"
    rm -rf "$dest"
    cp -R "$app" "$dest"
    echo "Exported: $dest"

# Remove build artifacts
[group('build')]
clean:
    @rm -rf "{{build_root}}" && echo "Cleaned {{build_root}}"

# Cut a release: bump version, build Release, zip the .app, tag, and publish
# to GitHub so it can be downloaded on other machines.
#   just release 1.5
[group('build')]
release version:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"

    version="{{version}}"
    # Digits-and-dots only (no leading "v"); the tag gets the v prefix.
    if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo "Usage: just release 1.5   (digits and dots only, no leading 'v')"
        exit 1
    fi
    tag="v$version"

    if git rev-parse "$tag" >/dev/null 2>&1; then
        echo "Error: tag $tag already exists."
        exit 1
    fi

    # Require no uncommitted *tracked* changes so the version-bump commit is
    # self-contained. Untracked scratch files are fine.
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        echo "Error: working tree has uncommitted changes — commit or stash first."
        exit 1
    fi

    pbxproj="{{project}}/project.pbxproj"
    echo "Bumping MARKETING_VERSION → $version"
    sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $version;/g" "$pbxproj"
    git add "$pbxproj"
    git commit -m "Release $tag"

    just build Release

    app="{{build_root}}/Build/Products/Release/{{app_name}}"
    [[ -d "$app" ]] || { echo "Error: built app not found at $app"; exit 1; }

    # A release that isn't Developer ID signed would hand out an app whose
    # accessibility permission breaks on the next update, so refuse to ship it.
    if ! codesign -d -r- "$app" 2>&1 | grep -q "certificate leaf\[subject.OU\]"; then
        echo "Error: $app is not Developer ID signed — refusing to release."
        echo "Check: just signing Release"
        exit 1
    fi

    dist="{{build_root}}/dist"
    mkdir -p "$dist"
    zip_path="$dist/PluginArranger-$version.zip"
    rm -f "$zip_path"
    echo "Zipping → $zip_path"
    # --keepParent so the archive contains "PluginArranger.app".
    ditto -c -k --keepParent "$app" "$zip_path"

    git tag "$tag"
    git push origin HEAD
    git push origin "$tag"

    echo "Creating GitHub release $tag"
    gh release create "$tag" "$zip_path" \
        --title "$tag" \
        --generate-notes

    echo ""
    echo "Released $tag"
    echo "  asset: $zip_path"
