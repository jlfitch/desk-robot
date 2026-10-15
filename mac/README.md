# The Mac app

The robot's body: an always-on-top panel in a corner of the screen with the animated face, a speech bubble, the microphone (with macOS voice processing for echo cancellation), the speaker, a menu and a Settings window. It connects to the Python brain in `../server` over the original robot's WebSocket protocol, as the ESP32 would, and runs the brain as its child process so one launch brings up everything.

## Build and run

```bash
cd mac
./build.sh --run        # xcodegen + xcodebuild, installs ~/Applications/DeskRobot.app, launches it
```

`../setup.sh` at the repo root does this as part of first-time setup. The build is ad-hoc signed and then re-signed with an "Apple Development" certificate if one is in your keychain, so the microphone permission survives rebuilds.

## Using it

- Say **"hey Rocky"** (or the name you set) and then your question. It stays awake about a minute after each exchange, then dozes off (eyes shut, Z's). A click on the face while it talks stops it; so does talking over it.
- **Double-click the face** for the typed box, inside the speech bubble. Enter sends.
- **The small round button** at the top-left of the face opens the menu (also in the menu bar): ask, sleep/wake, listening on/off, face style and eye color, size, settings, restart brain, log, start at login, quit. Right-click does the same.
- **Drag** the face anywhere; it remembers. It stays above other windows and on every Space, and never steals keyboard focus unless the typed box is open.
- Bottom-left dot: green = hearing you, blue = talking, faint = listening, red = microphone off. Bottom-right squares: coding sessions at work (pulsing) or waiting on you (amber).

## Files

| File | What |
| --- | --- |
| `FaceEngine.swift` | the face animation, a port of `../firmware/src/face.cpp`, plus the "Cozmo Dots" style |
| `FaceView.swift` | drawing, indicators, the speech bubble and typed box |
| `FacePanel.swift` | the floating panel: placement, dragging, hit-testing, growing for the bubble |
| `AudioIO.swift`, `RobotLink.swift` | microphone and speaker through one audio engine; the WebSocket client that acts as the robot body |
| `BrainProcess.swift`, `BrainClient.swift` | runs the brain as a child; polls `/status` and posts controls |
| `AgentsWatcher.swift` | counts busy Claude Code sessions for the face cue |
| `RobotMenu.swift`, `SettingsView.swift`, `DeskRobotApp.swift` | menus, settings window, app entry |

Gotchas met along the way, in case you change the audio: voice processing wants the mixer→output format mono at the input's sample rate (error -10875 otherwise), and its input arrives as many channels; take channel 0 yourself before resampling, the converter's downmix silently yields zeros.
