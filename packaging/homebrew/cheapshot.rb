class Cheapshot < Formula
  desc "On-device screenshot, video, and PDF OCR with redaction, for AI agents"
  homepage "https://github.com/all-caps-dev/cheapshot"
  url "https://github.com/all-caps-dev/cheapshot/releases/download/v0.6.0/cheapshot-v0.6.0-macos.zip"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on "jq"
  depends_on macos: :ventura

  def install
    bin.install "cheapshot"
  end

  test do
    assert_match "0.6.0", shell_output("#{bin}/cheapshot --version")
  end
end
