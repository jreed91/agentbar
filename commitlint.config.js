// Conventional Commits ruleset for AgentBar. Commit messages are enforced on
// pull requests by the "Lint commit messages" CI job and drive automated
// versioning via semantic-release (feat → minor, fix → patch, a
// "BREAKING CHANGE:" footer or "!" → major).
module.exports = {
  extends: ["@commitlint/config-conventional"],
};
