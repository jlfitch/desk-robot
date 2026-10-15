# Desk Robot for the Mac

A small animated robot that lives in the corner of your screen, listens for its name, and talks back in a voice of your choosing. It remembers what you tell it, keeps a calendar, writes notes, watches your Claude Code sessions and announces when they finish, and can start coding work for you. No hardware: it's a fork of [cgro00/desk-robot](https://github.com/cgro00/desk-robot) (the original $100 ESP32 robot, whose firmware is still in `firmware/` and whose README is now [docs/UPSTREAM-README.md](docs/UPSTREAM-README.md)) with the body replaced by a Mac app and the brain replaced by **Claude Code**, so it uses your Claude login and tools, no API key.

```
┌──────────── DeskRobot.app (SwiftUI, always on top) ─────────────┐
│ face · speech bubble · microphone with echo cancellation ·       │
│ speaker · menu · settings · busy-agents cue                      │
└───────────────────────────┬──────────────────────────────────────┘
                            │ localhost (the original robot protocol)
┌───────────────────────────┴──────────────────────────────────────┐
│ brain (Python, server/): wake word → Whisper → Smart Turn →       │
│ Claude Code (claude -p, long-lived) → Fish Audio or the Mac voice │
│ memory · journal · nightly reflection · tools · hooks            │
└──────────────────────────────────────────────────────────────────┘
```

## What it does

- **Talk to it.** "Hey Rocky, what's on tomorrow?" It wakes, answers out loud, and stays awake about a minute so you can keep talking. Cut it off mid-sentence; it stops. While awake, a quick judgment decides whether something said in the room was meant for it (optional, needs a TypeSafe key).
- **Memory.** Plain Markdown in a folder it reads at every start and appends to when you say "remember". Put that folder in your Obsidian vault or iCloud Drive and it follows you. A nightly reflection distills the day's conversations into a few lines. Who you are lives in `Profile.md`; fill it in once.
- **Calendar and reminders** across every account in Calendar.app (iCloud, Google, work), via Apple's own calendar store. Add, delete, "remind me in twenty minutes".
- **Notes.** Long answers and ideas go to a notes folder; with a vault configured, into the folders you allow.
- **Your Claude Code sessions are its sub-agents.** A hook tells it when any session finishes a turn or needs you; it announces the gist. "Start a coding agent in myproject to…" starts a background session, confirms first, and reports back. Small squares on the face show sessions at work.
- **Everything that changes something asks first.** Tools refuse without `--yes`; the robot says what it would do and waits for your yes.
- **Settings window** for listening, voice, model, character, face style and color.

## What you need

- An Apple Silicon Mac (built on macOS 26/27, Xcode 26). Python 3.13 (`brew install python@3.13`), `xcodegen` (`brew install xcodegen`).
- **Claude Code** installed and logged in (it is the brain).
- Optional: a [Fish Audio](https://fish.audio) key for a cloned voice (otherwise the Mac's built-in voice), a [TypeSafe](https://typesafe.ai) key for the room-talk filter.

## Setup

```bash
git clone https://github.com/jlfitch/desk-robot ~/desk-robot
cd ~/desk-robot
./setup.sh
```

The script makes the Python environment, writes `server/.env` (set `HUMAN_NAME` there), compiles the calendar tool, builds and installs `~/Applications/DeskRobot.app`, and prints the hook snippet for `~/.claude/settings.json`. First launch asks for the microphone; Calendar and Reminders are asked on first use. The app registers itself to start at login (toggle in its menu).

Then say "hey Rocky" and ask something. Double-click the face to type instead. The menu is the small button at the top-left of the face.

## Make it yours

| What | Where |
| --- | --- |
| Name, wake phrases, voice, sentence cap, model, listening knobs | `server/brain/config.py` (defaults) and `server/settings.json` (your overrides, also the Settings window) |
| Character | `server/brain/personality.py`: `helper` (brief, useful) or `rocky` (the Eridian engineer from *Project Hail Mary*) |
| Who you are, where your notes live, your own tools | `workspace/CLAUDE.local.md` (yours, not in git) next to `workspace/CLAUDE.md` (generic, in git) |
| Memory folder | `MEMORY_DIR` in `server/.env`; template in `workspace/memory-template/` |
| Notes folder / Obsidian vault | `NOTES_INBOX`, `VAULT_PATH` in `server/.env`; which vault subfolders it may write: `VAULT_WRITE_DIRS` in `config.py` |
| Face style, eye color, size | the robot's menu or Settings |

**Memory with Obsidian:** set `MEMORY_DIR=/path/to/vault/Assistants` and `VAULT_PATH=/path/to/vault`, then tell it in `CLAUDE.local.md` where your daily notes and task list live and how you name things. It reads the vault and writes only to the folders you listed. **Memory with Apple Notes:** Notes has no file representation, so point `MEMORY_DIR` at a folder in iCloud Drive instead; everything is Markdown and syncs the same way.

## Adding a tool

A tool is a script in `workspace/tools/` that prints plain text. Three steps:

1. Write it (any language). If it changes something, make it refuse without `--yes` and print "WOULD DO: …" instead (see `tools/code` for the pattern).
2. Add its name to `EXTRA_TOOLS` in `server/settings.json` so the brain may run it.
3. Tell the robot when and how to use it, in a paragraph in `workspace/CLAUDE.local.md`.

Restart the brain from the menu. That's how the author's CRM, Shopify store and second assistant are wired in; those scripts aren't in this repo because they're specific to his setup.

## Good to know

- The hook in `~/.claude/settings.json` uses an absolute path to `workspace/tools/subagent-hook`; sessions already open pick it up after `/hooks` or a restart.
- `mac/build.sh` re-signs the app with an "Apple Development" certificate if your keychain has one, so macOS remembers the microphone permission across rebuilds. Without one, each rebuild may ask again.
- The brain's log is `server/logs/brain.log` (overheard speech is kept out of it). The journal of real exchanges is `workspace/journal/`.
- Everything the brain may do is an explicit allowlist in `config.py`; it cannot write outside the memory, notes and vault folders you configured.

## Credits and license

Built on cgro00's desk-robot (MIT): the listening pipeline, the voice path and the face animation are theirs, ported and extended. Face detection, Silero VAD and Smart Turn credits are in the upstream README. MIT licensed, see `LICENSE`.
