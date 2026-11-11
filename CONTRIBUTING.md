# Contributing

Use macOS 14 or later and the Xcode command line tools. Build with `swift build`, run checks with `bash scripts/test_agent.sh`, and open a pull request with the behavior changed and how you tested it.

Keep provider setup explicit. Never add telemetry, private endpoints, credentials, real messages, or personal task data to examples or screenshots. Demo data must be fictional. Do not make paid model calls in CI.

The code is MIT licensed. Bundled Geist fonts retain their SIL Open Font License in `Resources/Fonts/geist-OFL.txt`.
