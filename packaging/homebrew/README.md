# Homebrew packaging

Users install with:

```sh
brew install adrmendozac/tap/thinnercore
```

The tap is the repository `adrmendozac/homebrew-tap`; its
`Formula/thinnercore.rb` is a rendered copy of `thinnercore.rb` here.

## Publishing a release

1. Set the version in `Sources/ThinnerCore/ThinnerCore.swift` (no `-dev`),
   commit, and push `main`.
2. Tag and push: `git tag -a vX.Y.Z -m "thinnercore X.Y.Z" && git push origin vX.Y.Z`.
3. Render the formula for that tag:

   ```sh
   scripts/render-formula.sh X.Y.Z > ../homebrew-tap/Formula/thinnercore.rb
   ```

   It downloads the tag's source tarball and fills in its SHA-256.
4. In the tap: `brew audit --strict thinnercore`, then
   `brew install --build-from-source thinnercore && brew test thinnercore`,
   then commit and push.

`thinnercore-binary.rb` is the template for a prebuilt, notarized binary
(`scripts/release.sh`), for when a Developer ID is available.
