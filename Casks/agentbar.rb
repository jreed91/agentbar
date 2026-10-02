cask "agentbar" do
  version "1.15.3"
  sha256 "68fcc212ba47da12c66a75920a358c9fa98fd6a7e4f5f985c2fc9d8aff6d5173"

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
