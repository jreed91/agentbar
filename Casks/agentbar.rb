cask "agentbar" do
  version "1.14.1"
  sha256 "f53699619f8d9eeba3728390ef8d272d68df9d06fff50d5d00b7ecbb4990915d"

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
