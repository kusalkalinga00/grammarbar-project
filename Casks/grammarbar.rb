cask "grammarbar" do
  version "1.0.0"
  sha256 "f94bd8c8fe8ef175c916aedb0ad1eecea68ae66f3ee05741fee35cc062d09184"

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

    The app is ad-hoc signed, not notarized, so macOS asks you to confirm it the
    first time you open it. Approve it once under System Settings > Privacy &
    Security, and it opens normally from then on.
  EOS
end
