# Memory

This folder is the robot's memory: plain Markdown it reads at the start of every conversation and appends to as it learns. Keep it anywhere you like. The default is `workspace/memory/`; point `MEMORY_DIR` in `server/.env` at a folder inside your Obsidian vault (or iCloud Drive) and it follows you across devices.

- `Shared-Memory.md` — facts, in four sections. The robot adds a dated line when you say "remember", and a nightly reflection adds up to three lines from the day's conversations.
- `Profile.md` — who you are. Worth filling in by hand once.
- `Handoffs.md` — notes between assistants, if you run more than one.
