# Template for the Homebrew tap formula. scripts/release.sh fills in the
# @…@ placeholders after the build is signed and notarized; publish the
# rendered copy, never this file.
class Thinnercore < Formula
  desc "Remove Intel slices from Universal Binary apps on Apple Silicon, safely"
  homepage "https://github.com/@REPO@"
  url "https://github.com/@REPO@/releases/download/v@VERSION@/thinnercore-@VERSION@-arm64.zip"
  version "@VERSION@"
  sha256 "@SHA256@"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :ventura

  def install
    bin.install "thinnercore"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/thinnercore --version").strip
    # A dry-run scan of an empty folder changes nothing and must succeed.
    system bin/"thinnercore", "scan", testpath, "--json"
  end
end
