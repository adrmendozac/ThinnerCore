# The Homebrew formula, built from source. The published copy lives in the
# tap repository (adrmendozac/homebrew-tap, Formula/thinnercore.rb); this is
# its source of truth. For a new release, update `url` to the new tag and
# `sha256` to the tarball's checksum (see packaging/homebrew/README.md).
#
# Building locally needs no Developer ID: a binary Homebrew compiles on the
# user's Mac is never quarantined, so Gatekeeper does not assess it.
class Thinnercore < Formula
  desc "Remove Intel slices from Universal Binary apps on Apple Silicon, safely"
  homepage "https://github.com/adrmendozac/ThinnerCore"
  url "https://github.com/adrmendozac/ThinnerCore/archive/refs/tags/v@VERSION@.tar.gz"
  sha256 "@SHA256@"
  license "MIT"
  head "https://github.com/adrmendozac/ThinnerCore.git", branch: "main"

  # Thinning removes Intel code for Apple Silicon; the tool refuses to run
  # anywhere else, so it is only offered there.
  depends_on arch: :arm64
  depends_on macos: :ventura

  def install
    # Swift Package Manager fetches swift-argument-parser at the version
    # pinned in Package.resolved, and needs its own sandbox off inside
    # Homebrew's.
    system "swift", "build", "--disable-sandbox", "--configuration", "release",
           "--product", "thinnercore"
    bin.install ".build/release/thinnercore"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/thinnercore --version").strip
    # A dry-run scan of an empty folder reads nothing, changes nothing, and
    # must succeed with a JSON report.
    report = shell_output("#{bin}/thinnercore scan #{testpath} --json " \
                          "--rosetta-preferences #{testpath}/none.plist " \
                          "--skip-list #{testpath}/none.txt --allow-list #{testpath}/none.txt")
    assert_match '"dryRun" : true', report
  end
end
