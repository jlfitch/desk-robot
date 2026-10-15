"""Central knobs for the desk-robot brain."""

import os
from pathlib import Path

# ── Secrets ──────────────────────────────────────────────────────────────────
# API keys live in server/.env (git-ignored; see .env.example), one KEY=VALUE
# per line. Anything already exported in the shell wins over the file.
_ENV_FILE = Path(__file__).resolve().parent.parent / ".env"
if _ENV_FILE.is_file():
    for _line in _ENV_FILE.read_text().splitlines():
        _line = _line.strip()
        if not _line or _line.startswith("#") or "=" not in _line:
            continue
        _k, _v = _line.split("=", 1)
        _v = _v.strip().strip("'\"")
        if _v:  # a blank line in .env means "not set", not "set to nothing"
            os.environ.setdefault(_k.strip(), _v)

# The robot's name — the wake word is "hey <name>".
ROBOT_NAME = "Rocky"

# ── Desktop version (mac/ app + this server, no hardware) ────────────────────
# BRAIN picks who answers:
#   "claude-code"  a long-lived `claude -p` process (brain/claude_brain.py). Uses
#                  your Claude Code login, keeps its own memory of the chat, and
#                  can use tools: no API key needed. The default here.
#   "api"          the upstream path: the chat API at LLM_BASE_URL with LLM_API_KEY.
BRAIN = "claude-code"
PERSONALITY = "rocky"            # "helper" (brief, useful) or "rocky" (the original character)
CLAUDE_MODEL = "haiku"            # alias or full id; haiku answers in ~1-3 s
CLAUDE_SMART_MODEL = "sonnet"     # used automatically for research, writing, planning (see claude_brain.route_model)
CLAUDE_SMART_STICKY_TURNS = 3     # follow-ups after a smart turn stay on the smart model...
CLAUDE_SMART_STICKY_SECONDS = 600 # ...for this many turns or this long
NOTE_LONG_REPLIES = True          # when a reply runs past REPLY_MAX_SENTENCES, the whole
                                  # answer is written to a fleeting note and he says so
CLAUDE_BIN = ""                   # leave empty to find `claude` on PATH / nvm
CLAUDE_WORKSPACE = "~/desk-robot/workspace"   # cwd for the process; its CLAUDE.md tells it the job
# Extra Claude Code flags. Tools listed in --allowedTools run without asking;
# everything else is refused (print mode never prompts). --add-dir widens what it may read.
# Where your notes live (optional). Set VAULT_PATH in server/.env to an
# Obsidian vault or any folder; the robot may then read it and write only to
# the subfolders named in NOTES_* below. Empty = no vault.
VAULT_PATH = os.environ.get("VAULT_PATH", "")
MEMORY_DIR = os.environ.get("MEMORY_DIR", "~/desk-robot/workspace/memory")   # the memory folder (see workspace/memory-template)
NOTES_INBOX = os.environ.get("NOTES_INBOX", "~/desk-robot/workspace/notes")  # where long answers are written as notes
# Subfolders of the vault he may write to (vault-relative; used only when VAULT_PATH is set).
VAULT_WRITE_DIRS = ["7. Fleeting Notes", "5. Journals/01 Daily Notes"]
VAULT_WRITE_FILES = ["1. Areas/Personal/Active Todos.md"]
_WS = os.path.expanduser("~/desk-robot/workspace")


def _claude_args() -> list[str]:
    """Each permission rule is its own argument (paths can contain spaces)."""
    args = [
        "--allowedTools",
        "Read", "Glob", "Grep", "WebSearch", "WebFetch",
        "Bash(date:*)", "Bash(ls:*)", "Bash(cal:*)", "Bash(cat:*)", "Bash(head:*)", "Bash(tail:*)",
    ]
    for tool in ["agenda", "agents", "code", "reflect"] + list(EXTRA_TOOLS):
        args += [f"Bash(tools/{tool}:*)", f"Bash({_WS}/tools/{tool}:*)"]
    # The only places he may write: memory, his notes inbox, and the vault folders above.
    for d in [MEMORY_DIR, NOTES_INBOX]:
        full = os.path.expanduser(d)
        args += [f"Write(/{full}/**)", f"Edit(/{full}/**)"]
    args += ["Write(memory/**)", "Edit(memory/**)", "Write(notes/**)", "Edit(notes/**)"]
    if VAULT_PATH:
        v = os.path.expanduser(VAULT_PATH)
        for d in VAULT_WRITE_DIRS:
            args += [f"Write(/{v}/{d}/**)", f"Edit(/{v}/{d}/**)"]
        for f in VAULT_WRITE_FILES:
            args += [f"Edit(/{v}/{f})"]
        args += ["--add-dir", v]
    # The allowlist is a prompt-free list, not a sandbox: `date; cat file` passes
    # Bash(date:*). Print mode refuses any tool call not on the list, so Write
    # and Edit outside those folders are refused; the two below stay off.
    args += ["--disallowedTools", "MultiEdit", "NotebookEdit"]
    return args


# Extra tools of your own in workspace/tools (names), allowed the same way.
# Set in server/settings.json as "EXTRA_TOOLS": ["jk", "swk"].
EXTRA_TOOLS: list[str] = []
# Names the speech-to-text should know (people, companies, places); also in settings.json.
VOCABULARY: list[str] = []
CLAUDE_TURN_TIMEOUT = 120.0       # seconds before a stuck turn is cut off
JOURNAL_DIR = "~/desk-robot/workspace/journal"   # one file a day of real exchanges (for the nightly reflection)
# Ears (desktop): the Mac app streams the microphone with echo cancellation, so
# he can keep listening while he talks and you can cut him off.
BARGE_IN = True
BARGE_IN_MIN_SPEECH = 0.6         # seconds of your speech that stops him mid-sentence (residual echo is shorter)
# While awake, an utterance without his name is checked: "was that said to the
# robot, or to someone else in the room?" (TypeSafe Jev; TYPESAFE_API_KEY in .env).
ADDRESSED_CHECK = True
ADDRESSED_THRESHOLD = 0.5         # probability below which he stays quiet
CLAUDE_RECYCLE_TURNS = 80         # start a fresh conversation after this many turns...
CLAUDE_RECYCLE_SECONDS = 8 * 3600 # ...or this long, so context never bloats

# Your name — Rocky calls you this. Set HUMAN_NAME in server/.env so it
# stays out of the repo; "friend" until you do.
HUMAN_NAME = os.environ.get("HUMAN_NAME", "friend")

# Language model. The brain speaks the OpenAI-style chat API, which
# OpenRouter, Anthropic and OpenAI all serve, so pick a provider here and
# put its key in server/.env as LLM_API_KEY. OpenRouter is the default
# because one key reaches every model, and the model is just a string:
#
#   provider    LLM_BASE_URL                       MODEL (examples)
#   OpenRouter  https://openrouter.ai/api/v1       anthropic/claude-haiku-4.5   (best at staying in character, ~$1-4/month)
#                                                  google/gemini-2.5-flash-lite (cheapest that still sounds like Rocky)
#                                                  openai/gpt-4.1-mini          (middle ground)
#   Anthropic   https://api.anthropic.com/v1/      claude-haiku-4-5
#   OpenAI      https://api.openai.com/v1          gpt-4.1-mini
#
# The model must accept images (Rocky sends camera frames) and tool calls
# (he moves his head with them).
LLM_BASE_URL = "https://openrouter.ai/api/v1"
MODEL = "anthropic/claude-haiku-4.5"

# WebSocket port the robot connects to.
PORT = 8765

# Rocky's voice and how much he says. The character itself (system prompt,
# canned lines) is in personality.py.
#   TTS_VOICE_ID  Fish Audio (fish.audio) voice: open the voice's page on the
#                 site and copy the 32-char ID from the URL. Needs
#                 FISH_AUDIO_API_KEY in server/.env.
#   TTS_TEMPERATURE / TTS_TOP_P
#                 Fish generation settings. Lower = steadier, fewer
#                 hallucinated sounds/laughs/extra words (a known quirk of
#                 generated speech); higher = more expressive. Fish's
#                 defaults are 0.7 / 0.7.
#   REPLY_MAX_SENTENCES
#                 the prompt asks for at most this many, and the server cuts
#                 anything past it before it's spoken (keeps voice cost down).
#   TTS_LEVEL     loudness the voice is held to (RMS, 0..1; see TTS_MAX_GAIN).
#   TTS_HIGHPASS_HZ
#                 bass cut before the speaker, 0 = off. The small speaker
#                 can't reproduce bass; it just rattles the shell. A deep
#                 voice wants 250-350.
#   TTS_PRESENCE_DB
#                 boost above ~1.5 kHz, where speech clarity lives, 0 = off.
#                 Lifts a muffled voice; too much sounds thin and hissy.
# The console page has sliders for level / bass cut / presence that apply
# live; set the winners here to keep them.
TTS_VOICE_ID = "6dd07916890445e59c5f019ad0fc7879"
TTS_TEMPERATURE = 0.4
TTS_TOP_P = 0.6
REPLY_MAX_SENTENCES = 4
TTS_LEVEL = 0.12
TTS_HIGHPASS_HZ = 0.0
TTS_PRESENCE_DB = 0.0

# Text-to-speech. The voice comes from Fish Audio (TTS_VOICE_ID above).
TTS_FALLBACK_VOICE = "Samantha"  # built-in voice used until Fish Audio is set up: a macOS `say`
                             # voice name (`say -v ?` lists them); Windows and Linux use their default
# Loudness. Fish's level wanders from line to line, so the audio goes through
# an automatic gain control (mouth.Leveler) that holds it near TTS_LEVEL
# (RMS, 0..1) using at most TTS_MAX_GAIN of boost, with a soft limiter on
# the peaks. 0.12 / 6.0 are the values of the original build (2026-09-06),
# which sounded right on the robot's speaker; 0.26 drove every peak into
# the limiter and the amp near clipping (crackly, muffled). Raise the
# robot's `volume` for everyday loudness, not this.
TTS_MAX_GAIN = 6.0
# Diagnostics, both off by default so nothing is written to disk. DEBUG_SAVE_TTS
# saves each spoken clip and its text to server/debug/tts/ (git-ignored, keeps
# the last 30); DEBUG_TTS_CHECK also transcribes each clip afterwards to flag
# audio that doesn't match the text, i.e. the voice model made something up.
# The check runs a second speech model right after every reply, which slows
# the next transcription if you answer quickly.
DEBUG_SAVE_TTS = False
DEBUG_TTS_CHECK = False

# Listening. The robot's mic when it is connected, the computer's otherwise.
LISTEN_ON_START = True
WAKE_PHRASES = [  # what speech-to-text tends to hear for "hey Rocky"
    "hey rocky",
    "hey rocket",
    "hey rocking",
    "hi rocky",
    "a rocky",
    "hey ricky",
]
STT_MODEL = "base.en"    # faster-whisper model: base.en ~0.3 s per utterance on an Apple
                         # Silicon Mac, small.en hears a little better but takes ~1 s
# The Hugging Face commit of that model to download (Systran/faster-whisper-<STT_MODEL>).
# Pinned so a changed upload can't be loaded unnoticed; set to None to take the latest.
STT_REVISION = "3d3d5dee26484f91867d81cb899cfcf72b96be6c"
STT_THREADS = 8          # CPU threads for transcription (0 = library default of 4)
STT_PROMPT = f"Hey {ROBOT_NAME}. {ROBOT_NAME} is a robot."  # name hint for the model
MIC_SOURCE = "auto"      # "robot" = the robot's mic, "mac" = MIC_DEVICE below,
                         # "auto" = robot when it's connected, else this computer
MIC_DEVICE = os.environ.get("MIC_DEVICE") or None  # local input by name (set MIC_DEVICE in
                         # server/.env); None = system default. List devices: python -m sounddevice
# Speech detection (server/brain/turn.py). A Silero VAD model decides whether
# each 32 ms chunk is speech (VAD_THRESHOLD, 0..1: lower = more sensitive).
# Once speech starts, a cutoff 0.15 lower keeps softer syllables from being
# mistaken for a pause. Microphone level and background noise still matter.
# When you pause for TURN_PAUSE_SECONDS the Smart Turn model listens to the
# whole sentence and
# decides whether you sound finished (probability above TURN_THRESHOLD ->
# Rocky answers now). If it thinks you're mid-thought it keeps listening,
# re-checking every TURN_RECHECK_SECONDS, and gives up waiting after
# TURN_MAX_SILENCE seconds of quiet. If Rocky keeps cutting you off, raise
# TURN_THRESHOLD; if he waits too long after you finish, lower it.
VAD_THRESHOLD = 0.4
TURN_PAUSE_SECONDS = 0.2
TURN_RECHECK_SECONDS = 0.6
TURN_MAX_SILENCE = 2.5
TURN_THRESHOLD = 0.5
# If you start talking again while Rocky is still thinking (before he speaks),
# speech that lasts this long cancels his reply and he listens to the rest.
CANCEL_MIN_SPEECH = 0.3
DEBUG_SAVE_UTTERANCE = ""  # set to "debug/last_utterance.wav" to keep the last thing heard, for mic tuning
AWAKE_SECONDS = 60.0     # after "hey Rocky" he stays awake; each thing you say
                         # resets this clock, and when it runs out he dozes off
_NAME = ROBOT_NAME.lower()
SLEEP_PHRASES = [        # any of these puts him to sleep until the next "hey <name>"
    f"{_NAME} sleep",
    f"{_NAME} go to sleep",
    "go to sleep",
    "goodnight",
    "good night",
    "stop listening",
]
# What he says as he goes to sleep: personality.py, LINES.

# Emotions the firmware knows how to display (see firmware/src/face.cpp).
EMOTIONS = [
    "neutral",
    "happy",
    "sad",
    "angry",
    "surprised",
    "sleepy",
    "thinking",
]

# Camera. The robot streams small JPEGs while connected; the live view
# is at http://localhost:<LIVE_VIEW_PORT>/ on this computer.
CAMERA_FPS = 10
LIVE_VIEW_PORT = 8766
LIVE_VIEW_BIND = "127.0.0.1"  # this computer only. "0.0.0.0" would show the camera to the whole LAN.
SEND_CAMERA_TO_BRAIN = False  # let Rocky see the camera when a question is about seeing
# A frame is attached only when the question is about seeing (any of these
# words or phrases). Everyday words like "this", "that", "here", "there" and
# "right" are deliberately NOT in the list: they made him describe the room
# in answers that had nothing to do with it. He can always use his `look`
# ability to get a fresh picture on his own.
CAMERA_WORDS = [
    "see", "seeing", "look", "looking", "watch", "watching", "camera", "picture",
    "photo", "image", "view", "describe", "notice", "recognize", "recognise",
    "holding", "wearing", "what color", "what colour", "what am i", "who is",
    "who's", "how many", "in front of you", "behind you", "on my desk", "on the desk",
    "in the room", "whiteboard", "on the screen", "on my screen", "read this", "read that",
    "read the", "read what",
]

# Face tracking: the head follows the biggest face in the picture.
# Off until you ask ("Rocky, track me"); phrases below switch it without a
# brain call, and Rocky can also switch it himself when asked in other words.
TRACKING = False
TRACK_ON_PHRASES = []   # no head on the desktop version: let "look at me" reach the brain
TRACK_OFF_PHRASES = []
# What he says when tracking starts/stops: personality.py, LINES.
TRACK_HFOV = 62.0          # camera field of view, degrees (OV2640 stock lens)
TRACK_VFOV = 48.0
TRACK_GAIN = 0.5           # fraction of the error corrected per frame (lower = calmer)
TRACK_DEADBAND = 0.10      # ignore errors smaller than this fraction of half-frame
TRACK_PAN_SIGN = 1         # flip to -1 if the head turns AWAY from you
TRACK_TILT_SIGN = 1        # flip to -1 if it nods the wrong way
TRACK_PAN_LIMIT = 60.0     # must match PAN_MIN/MAX_DEG in firmware config.h
TRACK_TILT_MIN = -60.0     # must match TILT_MIN/MAX_DEG in firmware config.h
TRACK_TILT_MAX = 0.0
TRACK_LOST_SECONDS = 4.0   # no face this long → idle glances resume

# How many conversation turns to remember before forgetting the oldest.
MAX_HISTORY_TURNS = 20

# ── Settings overlay ─────────────────────────────────────────────────────────
# server/settings.json holds the knobs the Mac app's Settings window changes
# (listening, voice, awake time, model, personality...). It is read last so it
# wins over the values above, and saved by main.py whenever a control changes.
SETTINGS_FILE = Path(__file__).resolve().parent.parent / "settings.json"
SETTINGS_KEYS = [
    "ROBOT_NAME", "PERSONALITY", "CLAUDE_MODEL", "CLAUDE_SMART_MODEL", "REPLY_MAX_SENTENCES",
    "NOTE_LONG_REPLIES", "TTS_FALLBACK_VOICE", "TTS_LEVEL", "TTS_HIGHPASS_HZ", "TTS_PRESENCE_DB",
    "VAD_THRESHOLD", "TURN_THRESHOLD", "TURN_MAX_SILENCE", "TURN_PAUSE_SECONDS", "AWAKE_SECONDS",
    "LISTEN_ON_START", "STT_MODEL", "BARGE_IN", "BARGE_IN_MIN_SPEECH", "ADDRESSED_CHECK", "ADDRESSED_THRESHOLD",
    "EXTRA_TOOLS", "VOCABULARY",
]


def load_settings() -> dict:
    import json
    try:
        data = json.loads(SETTINGS_FILE.read_text())
    except (OSError, ValueError):
        return {}
    applied = {}
    for k, v in data.items():
        if k in SETTINGS_KEYS and k in globals():
            kind = type(globals()[k])
            try:
                if kind is list:
                    globals()[k] = [str(x) for x in v] if isinstance(v, list) else globals()[k]
                else:
                    globals()[k] = kind(v) if kind in (int, float, str) else (bool(v) if kind is bool else v)
                applied[k] = globals()[k]
            except (TypeError, ValueError):
                pass
    return applied


def save_setting(key: str, value) -> None:
    """Persist one knob so it survives a restart."""
    import json
    if key not in SETTINGS_KEYS:
        raise ValueError(f"not a saved setting: {key}")
    try:
        data = json.loads(SETTINGS_FILE.read_text())
    except (OSError, ValueError):
        data = {}
    data[key] = value
    SETTINGS_FILE.write_text(json.dumps(data, indent=2) + "\n")
    globals()[key] = value


_applied = load_settings()
CLAUDE_ARGS = _claude_args()
if _applied:
    _SLEEP_NAME = ROBOT_NAME.lower()
    SLEEP_PHRASES = [f"{_SLEEP_NAME} sleep", f"{_SLEEP_NAME} go to sleep", "go to sleep", "goodnight", "good night", "stop listening"]
    STT_PROMPT = f"Hey {ROBOT_NAME}. {ROBOT_NAME} is a robot."
