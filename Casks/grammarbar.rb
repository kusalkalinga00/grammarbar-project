cask "grammarbar" do
  version "0.1.0"
  sha256 "98df3f423547d89771750caa364aab5b1242b7433f88ceaaa10280e9d1dd8cf1"

  url "https://github.com/kusalkalinga00/grammarbar-project/releases/download/v#{version}/GrammarBar-#{version}.zip"
  name "GrammarBar"
  desc "Menu bar grammar corrector using Apple's on-device model"
  homepage "https://github.com/kusalkalinga00/grammarbar-project"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "GrammarBar.app"

  zap trash: [
    "~/Library/Application Support/GrammarBar",
    "~/Library/Preferences/com.kusalkalinga.GrammarBar.plist",
    "~/Library/Saved Application State/com.kusalkalinga.GrammarBar.savedState",
  ]

  caveats <<~EOS
    GrammarBar needs Apple Intelligence, which requires an Apple Silicon Mac
    running macOS 26 or later with Apple Intelligence enabled in
    System Settings > Apple Intelligence & Siri.

    Without it the app opens but cannot correct anything - it will point you at
    that setting. There is no offline fallback in v1.

    The app is ad-hoc signed, not notarized. Homebrew downloads it with curl,
    which does not set the quarantine attribute, so it should launch without a
    Gatekeeper prompt.
  EOS
end
