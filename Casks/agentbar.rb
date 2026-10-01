cask "agentbar" do
  version "1.15.1"
  sha256 "868f82611b30f798fedeb6c1510b0b930451cf32304439fc86ff98f1d1ccf7ca"

  url "https://github.com/jreed91/agentbar/releases/download/v#{version}/AgentBar-#{version}.zip"
  name "AgentBar"
  desc "Menu bar companion for Claude Code and GitHub Copilot CLI"
  homepage "https://github.com/jreed91/agentbar"

  # The app's LSMinimumSystemVersion is 14.0 — Sonoma or newer, not Sonoma only.
  depends_on macos: ">= :sonoma"

  app "AgentBar.app"

  zap trash: [
    "~/Library/Application Support/AgentBar",
    "~/Library/Preferences/com.jreed91.AgentBar.plist",
    "~/.copilot/hooks/agentbar.json",
  ]
end
