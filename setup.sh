#!/bin/zsh
# One-time setup for the desktop robot. Run from the repo root on an Apple Silicon Mac.
set -e
cd "$(dirname "$0")"
command -v claude >/dev/null || { echo "Install Claude Code first (https://claude.com/claude-code) and log in."; exit 1; }
command -v xcodegen >/dev/null || { echo "Install xcodegen: brew install xcodegen"; exit 1; }
PY=$(command -v python3.13 || command -v python3)
echo "Python: $PY"
if [ ! -d server/.venv ]; then
  "$PY" -m venv server/.venv
  server/.venv/bin/pip install -q --upgrade pip
  server/.venv/bin/pip install -q -r server/requirements.txt
fi
if [ ! -f server/.env ]; then
  cp server/.env.example server/.env
  tok=$(server/.venv/bin/python -c "import secrets; print(secrets.token_hex(16))")
  sed -i '' "s/^ROBOT_TOKEN=.*/ROBOT_TOKEN=$tok/" server/.env
  echo "Wrote server/.env (set HUMAN_NAME and any optional keys there)."
fi
[ -f server/settings.json ] || cp server/settings.example.json server/settings.json
mkdir -p workspace/memory workspace/notes workspace/journal
for f in Shared-Memory.md Profile.md Handoffs.md README.md; do [ -f "workspace/memory/$f" ] || cp "workspace/memory-template/$f" "workspace/memory/$f"; done
echo "Compiling the calendar tool..."
(cd workspace/tools && swiftc -O -o agenda agenda.swift 2>&1 | grep -v warning || true)
echo "Building the app..."
mac/build.sh
cat <<MSG

Done. Launch ~/Applications/DeskRobot.app (or: open ~/Applications/DeskRobot.app).
First launch asks for Microphone, then Calendar and Reminders when first used. It also registers itself to start at login (toggle in its menu).

To have the robot announce when your Claude Code sessions finish, add to ~/.claude/settings.json:
  "hooks": {
    "Stop":         [{"hooks": [{"type": "command", "command": "$PWD/workspace/tools/subagent-hook", "timeout": 5}]}],
    "Notification": [{"hooks": [{"type": "command", "command": "$PWD/workspace/tools/subagent-hook", "timeout": 5}]}]
  }
MSG
