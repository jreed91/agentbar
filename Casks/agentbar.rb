cask "agentbar" do
  version "0.3.1"
  sha256 "9b45365208532c74c41580f1d8899b3136b1de9a642c9bd3567a071a9a5ee490"

  url "https://github.com/jreed91/claude-notification/releases/download/v#{version}/AgentBar-#{version}.zip"
  name "AgentBar"
  desc "Menu bar companion for Claude Code — answer agent prompts from the macOS menu bar"
  homepage "https://github.com/jreed91/claude-notification"

  depends_on macos: :sonoma

  app "AgentBar.app"

  zap trash: [
    "~/Library/Application Support/AgentBar",
    "~/Library/Preferences/com.jreed91.AgentBar.plist",
  ]
end
