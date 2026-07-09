cask "agentbar" do
  version "0.3.0"
  sha256 "a4c56dec7b48b7731954fdba6e0a98af8bfcd16ff9b8900d823df2de4211c31e"

  url "https://github.com/jreed91/claude-notification/releases/download/v#{version}/AgentBar-#{version}.zip"
  name "AgentBar"
  desc "Menu bar companion for Claude Code — answer agent prompts from the macOS menu bar"
  homepage "https://github.com/jreed91/claude-notification"

  depends_on macos: ">= :sonoma"

  app "AgentBar.app"

  zap trash: [
    "~/Library/Application Support/AgentBar",
    "~/Library/Preferences/com.jreed91.AgentBar.plist",
  ]
end
