class Deviceloop < Formula
  desc "CLI and MCP server that drives iPhones, iPads and simulators"
  homepage "https://github.com/ZachNagengast/deviceloop"
  url "https://github.com/ZachNagengast/deviceloop/releases/download/v0.1.0/deviceloop-0.1.0-arm64.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  # xcodebuild creates this directory with mode 0777 when it is missing.
  skip_clean "share/deviceloop/Runner/DeviceLoopRunner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration"

  def install
    bin.install "bin/deviceloop"
    libexec.install "libexec/DeviceLoopCapture.app"
    pkgshare.install "share/deviceloop/Runner", "share/deviceloop/skills"
    (pkgshare/"Runner/DeviceLoopRunner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration").mkpath
  end

  def caveats
    <<~EOS
      Set the signing team and print the MCP registration command for each agent on this Mac:
        deviceloop setup

      Register the MCP server with Claude Code or Codex:
        claude mcp add -s user deviceloop -- #{HOMEBREW_PREFIX}/bin/deviceloop mcp
        codex mcp add deviceloop -- #{HOMEBREW_PREFIX}/bin/deviceloop mcp

      The agent skill is in:
        #{opt_pkgshare}/skills/deviceloop
    EOS
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/deviceloop --version").chomp
  end
end
