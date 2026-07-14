cask "agentbar" do
  version "1.10.5"
  sha256 "f4e64d1a5c0ef1c22d049f152a93bed2b34daac154e38601ce1ff35dfb521aa4"

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
