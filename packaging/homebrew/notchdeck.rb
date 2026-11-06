# Homebrew cask, published in chiranjeebhub/homebrew-tap as Casks/notchdeck.rb.
# After each release, update `version` and `sha256` (release.sh prints the checksum).
cask "notchdeck" do
  version "0.3.1"
  sha256 "9f2636d705fa25d22aa5cb1b3f8064d1bba94b0a00d7038644ee710d9de685b2"

  url "https://github.com/chiranjeebhub/NotchDeck/releases/download/v#{version}/NotchDeck-#{version}.dmg"
  name "NotchDeck"
  desc "Turns the MacBook notch into a hub for media, files, calendar and dev servers"
  homepage "https://github.com/chiranjeebhub/NotchDeck"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "NotchDeck.app"

  zap trash: [
    "~/Library/Application Support/NotchDeck",
    "~/Library/Caches/com.chiranjeebhub.NotchDeck",
    "~/Library/Preferences/com.chiranjeebhub.NotchDeck.plist",
  ]
end
