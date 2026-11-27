# Homebrew cask şablonu. Release iş akışı __VERSION__/__SHA256__/__GITHUB_REPO__ alanlarını doldurup
# dist/liman.rb olarak yayınlar; bunu kendi tap deponuza (ör. sahip/homebrew-tap → Casks/liman.rb) koyun:
#   brew install --cask sahip/tap/liman
cask "liman" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/__GITHUB_REPO__/releases/download/v#{version}/Liman-#{version}.dmg"
  name "Liman"
  desc "Menu bar app and background service for Colima and Apple container"
  homepage "https://github.com/__GITHUB_REPO__"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"
  depends_on formula: "colima"
  depends_on formula: "docker"

  app "Liman.app"

  uninstall launchctl: "app.liman.agent",
            quit:      "app.liman.Liman",
            delete:    "~/Library/LaunchAgents/app.liman.agent.plist"

  zap trash: [
    "~/Library/Application Support/Liman",
    "~/Library/Caches/app.liman.Liman",
    "~/Library/Logs/Liman",
    "~/Library/Preferences/app.liman.Liman.plist",
  ]
end
