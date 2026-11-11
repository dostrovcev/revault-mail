# Connect your AI

The application is free and open source. AI access comes from your own account. Account eligibility, limits and charges are controlled by the provider; the app does not promise unlimited or free inference.

## Claude account

1. Install [Claude Code](https://code.claude.com/docs/en/setup).
2. Run `claude` in Terminal and complete its sign-in.
3. Choose **Claude Code** in the application's Agent settings. Leave the model blank to use the CLI default.

## ChatGPT account

1. Install [Codex CLI](https://developers.openai.com/codex/cli/).
2. Run `codex login` in Terminal and sign in with ChatGPT.
3. Choose **Codex** in Agent settings. Leave the model blank to use its default.

This is a CLI integration using your own login, not an embedded ChatGPT web page. Use a current CLI supporting `exec --ignore-user-config`, `--ephemeral`, and `--output-last-message`. See OpenAI's [authentication](https://learn.chatgpt.com/docs/auth?surface=cli) and [non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode) documentation.

The app finds common Homebrew, npm and local installations. If it cannot find your CLI, run `command -v claude` or `command -v codex` in Terminal and paste the resulting path into Settings.

## Data sent to AI

Mail passes the selected thread and recent assistant conversation when you ask a question; translation passes the selected text. Today passes the selected task and its recent comments. The request goes to the provider via its CLI, not through a Re:Vault server. Review the answer before using it.

## Troubleshooting

- **Login / nonzero exit:** open the CLI in Terminal and check sign-in and usage limits.
- **Unknown option:** update the CLI.
- **No executable:** set its absolute path in Settings.
- **Timeout:** retry with a shorter thread or check the provider's status.
