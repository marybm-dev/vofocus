# Releasing

VOFocus ships through a Homebrew tap: `brew install marybm-dev/tap/vofocus`. The
formula's source is [packaging/homebrew/vofocus.rb](../packaging/homebrew/vofocus.rb).
It runs `scripts/install.sh`, so check a release locally with that script first.

## Each release

1. Set the version in `Host/Sources/VOFocusKit/Installation.swift`
   (`Installation.version`). `vofocus --version`, the MCP server's `serverInfo` and the
   formula's test all use it, and the tag must match it.
2. Check an install from a clean folder, outside the checkout:

   ```sh
   scripts/install.sh /tmp/vofocus-check
   cd /tmp && /tmp/vofocus-check/bin/vofocus --version && /tmp/vofocus-check/bin/vofocus setup
   ```

   For an end-to-end check, run the smoke test against the install:
   `VOFOCUS_MCP=/tmp/vofocus-check/bin/vofocus-mcp scripts/mcp_smoke.py`.
3. Commit, tag and push the tag: `git tag v0.1.0 && git push origin v0.1.0`. Then create
   the GitHub release from the tag.
4. Get the source archive's checksum:

   ```sh
   curl -sL https://github.com/marybm-dev/vofocus/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256
   ```

5. In the tap repository (`marybm-dev/homebrew-tap`), update `Formula/vofocus.rb` from
   `packaging/homebrew/vofocus.rb` with the new `url` and `sha256`. Then check it:

   ```sh
   brew install --build-from-source marybm-dev/tap/vofocus
   brew test vofocus && brew audit --strict vofocus
   ```

## Later

- Build bottles (prebuilt binaries) in a GitHub Actions workflow on each tag, so
  installs skip the Swift build. homebrew-core only accepts projects with a following,
  so stay in the tap until then.
