# Homebrew formula for VOFocus. On a release, copy it to the tap repository as
# Formula/vofocus.rb and set url and sha256 for the new tag (see docs/RELEASING.md).
class Vofocus < Formula
  desc "Drive real VoiceOver on iOS Simulators and devices from agents and CI"
  homepage "https://github.com/marybm-dev/vofocus"
  url "https://github.com/marybm-dev/vofocus/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "da01f674259d390388c73016aae93f2de7b59ee54c1b5da37eb1b2b167f7d21f"
  license "Apache-2.0"
  head "https://github.com/marybm-dev/vofocus.git", branch: "main"

  depends_on "xcodegen" => :build
  depends_on :macos
  # The runner is built on first use, with XCUIVoiceOverService from Xcode 27.
  depends_on xcode: "27.0"

  def install
    # SwiftPM's own sandbox can't nest inside Homebrew's.
    ENV["SWIFT_BUILD_FLAGS"] = "--disable-sandbox"
    system "scripts/install.sh", prefix
  end

  def caveats
    <<~EOS
      The first time it starts, VOFocus builds its runner with Xcode (a few minutes),
      into ~/Library/Caches/vofocus.

      To use it from an agent:
        claude mcp add vofocus -- #{opt_bin}/vofocus-mcp

      For physical devices, save your Apple developer team once:
        vofocus setup --team <your team ID>
      The Simulator needs no setup.
    EOS
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/vofocus --version").strip
    assert_match "No device signing", shell_output("#{bin}/vofocus setup")
    assert_path_exists pkgshare/"VOFocus.xcodeproj"
  end
end
