# Re:Vault Mail

**A free, open source Gmail app for macOS. Bring your own Claude or ChatGPT account.**

Read your mail, ask a question about a thread, draft a reply, or translate a message. The assistant lives next to your email. Connect Claude Code or Codex with your own login; no Re:Vault subscription or hosted backend is required.

Built by [Dmitry Ostrovtsev](https://www.linkedin.com/in/dostrovcev/), founder of [Re:Vault](https://re-vault.io/?utm_source=revault-mail&utm_medium=github&utm_campaign=open-source).

## What works

- Multiple Gmail accounts, search, labels, attachments, archive and trash.
- Conversation and original-message reading views.
- An assistant conversation per email thread, with drafts you can insert into your reply.
- Message and draft translation through your selected AI provider.
- Local mail cache and assistant history; Google tokens in macOS Keychain.

This is an early macOS release. Team conversations and the private Re:Vault backend are not part of this standalone edition. The app is free; your AI account's limits and any provider charges still apply.

## Build and install

Requires macOS 14+ and Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/dostrovcev/revault-mail.git
cd revault-mail
./scripts/build_app.sh
```

Copy `build/Re:Vault Mail.app` into Applications. Local builds are ad hoc signed, not notarized. If macOS blocks opening it, use the system's Privacy & Security settings after reviewing the source. No hosted binary is required to build the app.

## Connect Gmail

You currently need your own Google OAuth Desktop client:

1. Create a project in [Google Cloud Console](https://console.cloud.google.com/), enable the Gmail API and Calendar API, and configure the OAuth consent screen.
2. Add your own Google account as a test user while the app is in testing.
3. Create a **Desktop app** OAuth client and download its JSON.
4. Import that JSON in Mail settings, then choose **Add Gmail** and finish Google's sign-in.

Keep the JSON out of Git. Testing-mode OAuth sessions may require periodic sign-in. Calendar access is used by the app's event actions. The app stores its data in `~/Library/Application Support/ReVaultMailOSS`, separately from the private edition.

## Connect AI

Sign in once with `claude` or `codex login` in Terminal. Open **Settings → Agent**, choose Claude Code or Codex, and leave the model blank to use the provider default. Details and troubleshooting: [AI setup](docs/AI-SETUP.md).

The app passes email content to your chosen provider only when you use the assistant or translation. Gmail sync goes to Google. Email HTML may load remote content, and sender icons use DuckDuckGo. Read [security and data](SECURITY.md).

## Develop

```bash
swift build
bash scripts/test_search.sh
bash scripts/test_agent.sh
RVM_DEMO=1 swift run ReVaultMail
```

Demo messages are fictional. No production server, credentials, customer data or private git history are included.

## Author and related project

I build AI tools for the work I do every day. These apps are free to use and modify. If you want help applying AI to your sales workflow, [see my work at Re:Vault](https://re-vault.io/?utm_source=revault-mail&utm_medium=github&utm_campaign=open-source).

Also see [Today](https://github.com/dostrovcev/revault-today), a local task app with an assistant in each task.

MIT license. Geist fonts use the SIL Open Font License. [Contribute](CONTRIBUTING.md) · [Roadmap](docs/ROADMAP.md).
