# Security and data

Report a vulnerability privately through GitHub's security advisory feature when available, or contact the maintainer through https://re-vault.io. Do not put credentials or real messages in public issues.

The application stores data locally. It sends the selected email/task context to the AI provider when you invoke AI. The provider's terms and retention policy apply. CLI providers use their existing login; this application does not copy login tokens. API keys, where supported, use macOS Keychain.

Claude Code runs without tools or configured MCP servers. Codex runs read-only in a temporary folder with user config ignored and approvals disabled. Read-only is not a guarantee that an agent cannot read local files. Do not submit secrets to a model. Neither application gives the CLI Gmail credentials.

The first public version is an early release, not an audited security product. Application data is not encrypted by the app; use your Mac's disk encryption and account controls.
