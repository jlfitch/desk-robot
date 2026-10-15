"""desk-robot brain server.

Run with:  python -m brain.main   (from the server/ directory, venv active)

Three jobs:
  1. WebSocket server the robot connects to over WiFi.
  2. An interactive console so you can talk to the brain and puppet the
     robot from your keyboard right now.
  3. Listening: hears "hey Rocky" on the mic, sends what you say to
     the language model, and speaks the reply through the robot (or the Mac).

A reply is a pipeline, not a wait: the model's words stream in, each
finished sentence goes to the voice as soon as it exists, and the voice's
audio streams to the speaker as it's made. If you start talking again
before Rocky has begun speaking, the reply is dropped and he listens to
the rest of what you're saying, then answers once.

Console commands:
  ask <question>   send a question to the brain, print and speak the reply
  say <text>       speak text (robot speaker if connected, else the Mac)
  volume <0-1>     set the robot's speaker volume
  track on|off     face tracking (head follows you)
  listen           toggle listening on the microphone
  mic              3-second level meter to check the microphone
  emo <name>       push a face to the connected robot
  pan <deg>        push a head turn to the connected robot
  tilt <deg>       push a head nod to the connected robot
  status           show whether a robot is connected
  quit
"""

from __future__ import annotations

import asyncio
import json
import os
import queue
import secrets
import sys
import threading
import time

import websockets

from . import config, mouth, personality
from .addressed import addressed as _addressed
from .thinking import Interrupted, RobotBrain
from .ears import Ears, normalize, strip_wake_word
from .eyes import Eyes
from .tracker import Tracker

robot_socket: websockets.ServerConnection | None = None
brain: RobotBrain | None = None  # created in main() once the event loop exists
ears: Ears | None = None
# (text, when speech began, when it ended, when the transcript was ready)
heard: asyncio.Queue[tuple[str, float, float, float]] = asyncio.Queue()
speech_started = asyncio.Event()  # the human began a new turn (set by the ears)
awake_until = 0.0  # while time.time() < this, he's awake: no wake word needed
last_exchange = {"q": "", "a": "", "at": 0.0, "cut": False}  # for the "was that for me?" check
robot_speak_done = asyncio.Event()  # robot finished playing the last reply
robot_aec = False     # the connected body cancels its own echo (the Mac app), so ears stay open while he talks
speaking_now = False  # a reply is playing right now
current_reply = None  # the SpokenReply being spoken (its sentences feed the app's speech bubble)
stop_requested = asyncio.Event()  # "stop talking" from the app, the console or the API
eyes = Eyes()
head_moves: asyncio.Queue[tuple[float | None, float | None, bool]] = asyncio.Queue()
tracker: Tracker | None = None

FRAME_BYTES = 3200  # 100 ms of 16 kHz s16le per audio frame to the robot

# What the live-view console shows and can change (see console_state / console_command).
current_emotion = "neutral"
speaker_volume = 0.7        # mirrors firmware SPEAKER_VOLUME until changed here
thinking = False            # a reply is being composed (before it's spoken)
TUNABLE = {                 # config knobs the console may change live: (min, max)
    "VAD_THRESHOLD": (0.1, 0.95),
    "TURN_THRESHOLD": (0.1, 0.95),
    "TURN_MAX_SILENCE": (0.5, 6.0),
    "AWAKE_SECONDS": (10.0, 600.0),
}
VOICE_TUNABLE = {           # speaker tuning the console may change live (mouth.Leveler reads these per reply)
    "TTS_LEVEL": (0.08, 0.40),
    "TTS_HIGHPASS_HZ": (0.0, 600.0),
    "TTS_PRESENCE_DB": (0.0, 12.0),
}


async def send_to_robot(payload: dict) -> bool:
    global current_emotion
    if payload.get("type") == "emotion":
        current_emotion = payload.get("name", current_emotion)
    if robot_socket is None:
        if payload.get("type") not in ("emotion", "asleep", "pan", "tilt", "glance", "stream", "mic", "volume"):
            print("(no robot connected — command not sent)")
        return False
    await robot_socket.send(json.dumps(payload))
    return True


def pick_mic_source() -> None:
    """auto: the robot's mic while it's connected, the Mac's otherwise."""
    if ears is None:
        return
    if config.MIC_SOURCE == "auto":
        source = "robot" if robot_socket is not None else "mac"
    else:
        source = config.MIC_SOURCE
    if source != ears.source:
        ears.set_source(source)
        if source == "mac" and not ears.has_mac_mic:
            print(f"(no Mac mic: {ears.mac_error} — nothing is listening until the robot connects)")
        else:
            print(f"listening through the {'robot' if source == 'robot' else 'Mac'} mic")


async def handle_robot(websocket: websockets.ServerConnection) -> None:
    global robot_socket
    peer = websocket.remote_address[0] if websocket.remote_address else "?"
    # Anyone on the WiFi can reach this port, so the first message must be a
    # hello carrying the shared token from server/.env. Anything else is
    # dropped without a reply.
    try:
        first = await asyncio.wait_for(websocket.recv(), timeout=2)
        hello = json.loads(first) if isinstance(first, str) else {}
    except (asyncio.TimeoutError, json.JSONDecodeError, websockets.ConnectionClosed):
        hello = {}
    if not isinstance(hello, dict):
        hello = {}  # "[1]", "42", "null" are valid JSON but not a hello
    expected = os.environ.get("ROBOT_TOKEN", "")
    if not expected:
        print("(refusing robot: set ROBOT_TOKEN in server/.env and firmware/include/secrets.h)")
        await websocket.close(1008)
        return
    offered = str(hello.get("token", "")).encode()  # bytes: compare_digest rejects non-ASCII str
    if hello.get("type") != "hello" or not secrets.compare_digest(offered, expected.encode()):
        print(f"(refused a connection from {peer}: bad or missing token)")
        await websocket.close(1008)
        return
    if robot_socket is not None:
        print(f"(refused a second robot from {peer}: one is already connected)")
        await websocket.close(1013)
        return
    robot_socket = websocket
    global robot_aec
    robot_aec = bool(hello.get("aec"))
    print(f"robot connected! (fw {hello.get('fw', '?')}, {peer}{', echo cancellation' if robot_aec else ''})")
    pick_mic_source()
    if config.MIC_SOURCE in ("auto", "robot"):
        await send_to_robot({"type": "mic", "on": True})
    await send_to_robot({"type": "stream", "on": True, "fps": config.CAMERA_FPS})
    # No idle head glances: they fight deliberate looks. The eyes still move.
    await send_to_robot({"type": "glance", "on": False})
    try:
        async for message in websocket:
            if isinstance(message, bytes):
                kind = message[:1]
                if kind == b"\x01" and ears is not None and len(message) % 2 == 1:
                    ears.push_audio(message[1:])  # 1 type byte + whole 16-bit samples
                elif kind == b"\x02":
                    eyes.push_frame(message[1:])
                continue
            try:
                event = json.loads(message)
            except json.JSONDecodeError:
                continue
            if not isinstance(event, dict):
                continue
            if event.get("type") == "state":
                continue  # heartbeat every 5 s; not worth the console space
            if event.get("type") == "speak_done":
                robot_speak_done.set()
                continue
            if event.get("type") == "temp":
                try:
                    eyes.temperature = float(event.get("c"))
                except (TypeError, ValueError):
                    pass  # not a number; leave the last reading
                continue
            print(f"robot: {event}")
    except websockets.ConnectionClosed:
        pass
    finally:
        # Only clear the slot if it's still ours: when the robot reboots, the
        # new connection can arrive before the old one is noticed as dead.
        if robot_socket is websocket:
            robot_socket = None
            robot_aec = False
            print("robot disconnected")
            pick_mic_source()


async def handle_console_line(line: str) -> bool:
    """Returns False when the server should shut down."""
    line = line.strip()
    if not line:
        return True
    cmd, _, arg = line.partition(" ")
    cmd = cmd.lower()
    arg = arg.strip()

    if cmd == "quit":
        return False
    if cmd == "stop":
        stop_requested.set()
    elif cmd == "status":
        print("robot connected" if robot_socket else "no robot connected")
    elif cmd == "emo":
        if arg in config.EMOTIONS:
            await send_to_robot({"type": "emotion", "name": arg})
        else:
            print(f"emotions: {', '.join(config.EMOTIONS)}")
    elif cmd in ("pan", "tilt"):
        try:
            deg = float(arg)
            await send_to_robot({"type": cmd, "deg": deg})
            if tracker is not None:
                tracker.note_pose(**{cmd: deg})
        except ValueError:
            print(f"usage: {cmd} <degrees>")
    elif cmd == "track":
        await set_tracking(arg != "off")
    elif cmd == "ask":
        if not arg:
            print("usage: ask <question>")
            return True
        await converse(arg, interruptible=False)
    elif cmd == "listen":
        if ears is None:
            await start_listening()
        else:
            stop_listening()
    elif cmd == "mic":
        await mic_meter()
    elif cmd == "say":
        if arg:
            await say(arg)
        else:
            print("usage: say <text>")
    elif cmd == "volume":
        try:
            await set_volume(float(arg))
        except ValueError:
            print("usage: volume <0.0-1.0>")
    else:
        print("commands: ask <q> | say <text> | volume <0-1> | listen | mic | track on|off | emo <name> | pan <deg> | tilt <deg> | status | quit")
    return True


# ── Rocky's abilities (called by the brain, from its worker thread) ──────────

async def look(args: dict) -> tuple[str, bytes | None]:
    """Move the head, wait for it to get there, and grab a fresh frame.
    Only the axis that was asked for moves: "left"/"right" pan, "down"/
    "level" tilt, "center" both."""
    pan = tracker.pan if tracker else 0.0
    tilt = tracker.tilt if tracker else 0.0
    move_pan = move_tilt = False
    d = args.get("direction")
    try:
        amount = float(args["degrees"]) if args.get("degrees") is not None else None
    except (TypeError, ValueError):
        amount = None
    if d in ("left", "right"):
        deg = amount if amount is not None else 40.0
        pan, move_pan = (-deg if d == "left" else deg), True
    elif d == "down":
        tilt, move_tilt = -(amount if amount is not None else 30.0), True  # a normal glance down; ask for degrees to go further
    elif d == "level":
        tilt, move_tilt = config.TRACK_TILT_MAX, True
    elif d == "center":
        pan, tilt, move_pan, move_tilt = 0.0, config.TRACK_TILT_MAX, True, True
    if not (move_pan or move_tilt):
        return ("Say where to look: left, right, down, level, or center.", None)
    pan = max(-config.TRACK_PAN_LIMIT, min(config.TRACK_PAN_LIMIT, pan))
    tilt = max(config.TRACK_TILT_MIN, min(config.TRACK_TILT_MAX, tilt))

    if tracker is not None and tracker.enabled:
        await set_tracking(False, announce=False)  # tracking would drag the head back
    await set_head_held(d != "center")
    if move_pan:
        await send_to_robot({"type": "pan", "deg": pan})
    if move_tilt:
        await send_to_robot({"type": "tilt", "deg": tilt})
    if tracker is not None:
        tracker.note_pose(pan=pan if move_pan else None, tilt=tilt if move_tilt else None)
    await asyncio.sleep(1.2)  # servo easing + a frame or two from the new angle
    seq = eyes.frame_seq
    for _ in range(10):
        if eyes.frame_seq != seq:
            break
        await asyncio.sleep(0.1)
    jpeg = eyes.latest()
    pan_word = "left" if pan < -5 else "right" if pan > 5 else "center"
    if tilt <= config.TRACK_TILT_MIN + 0.5:
        tilt_word = "down, as far as it goes"
    elif tilt >= config.TRACK_TILT_MAX - 0.5:
        tilt_word = "level, as high as it goes"
    else:
        tilt_word = "down" if tilt < -5 else "level"
    where = f"Head is now at pan {pan:.0f} deg ({pan_word}), tilt {tilt:.0f} deg ({tilt_word})."
    return (where + (" Fresh camera image attached." if jpeg else " No camera image available."), jpeg)


head_held = False  # he was told to look somewhere and is holding that pose


async def set_head_held(held: bool) -> None:
    """Remember that a deliberate look is in effect (shown on the console).
    Idle glances are always off, so nothing else needs to move."""
    global head_held
    head_held = held


async def set_tracking(on: bool, announce: bool = True) -> tuple[str, bytes | None]:
    if tracker is None:
        return ("no tracker running", None)
    tracker.enabled = on
    if not on and tracker.tracking:
        tracker.tracking = False
        eyes.tracking_info = {"tracking": False, "pan": tracker.pan, "tilt": tracker.tilt}
    if announce:
        print(f"tracking {'on' if on else 'off'}")
    return ("now following the human's face" if on else "stopped following", None)


def _sync(coro_fn):
    """Wrap an async ability so the brain's worker thread can call it."""
    def run(args: dict):
        return asyncio.run_coroutine_threadsafe(coro_fn(args), main_loop).result(timeout=15)
    return run


main_loop: asyncio.AbstractEventLoop | None = None
ABILITIES = {
    "look": _sync(look),
    "track_face": _sync(lambda args: set_tracking(bool(args.get("on", True)))),
}


def wants_camera(question: str) -> bool:
    """Does the question sound like it's about what Rocky can see?"""
    q = " " + normalize(question) + " "
    return any(f" {w} " in q or (" " in w and w in q) for w in config.CAMERA_WORDS)


# ── Speaking ─────────────────────────────────────────────────────────────────

class Timeline:
    """Stage times of one reply, measured from the end of the human's speech."""

    ORDER = ("heard", "face", "first sentence", "first audio", "speaking", "done")

    def __init__(self, t0: float) -> None:
        self.t0 = t0
        self.marks: dict[str, float] = {}

    def mark(self, name: str) -> None:
        self.marks.setdefault(name, time.time())

    def report(self) -> None:
        parts = [f"{n} {self.marks[n] - self.t0:.2f}s" for n in self.ORDER if n in self.marks]
        if parts:
            print("  timing (after your last word): " + " · ".join(parts))


class SpokenReply:
    """One reply in flight, as a three-stage pipeline:
    brain thread (model → sentences) → voice thread (Fish → PCM) → the speaker.

    Each stage hands off through a queue, so the first sentence is being
    voiced while the model writes the second, and audio plays while the
    voice is still generating."""

    BREAK = b""  # marks a sentence boundary in the audio queue

    def __init__(self, loop: asyncio.AbstractEventLoop, timeline: Timeline) -> None:
        self.loop = loop
        self.tl = timeline
        self.leveler = mouth.Leveler()  # one per reply: steady loudness across its sentences
        self.sentences: queue.Queue[str | None] = queue.Queue()
        self.audio: queue.Queue[bytes | None] = queue.Queue()
        self.cancel = threading.Event()
        self.spoken: list[str] = []
        self.pcm: list[bytes] = []
        self.interrupted = False

    @property
    def text(self) -> str:
        return " ".join(self.spoken)

    def think_and_speak(self, question: str, jpeg: bytes | None, camera_wanted: bool = False) -> None:
        threading.Thread(target=self._think, args=(question, jpeg, camera_wanted), daemon=True).start()
        threading.Thread(target=self._voice, daemon=True).start()

    def speak_fixed(self, text: str) -> None:
        """A canned line: no brain involved."""
        self.spoken.append(text)
        self.sentences.put(text)
        self.sentences.put(None)
        threading.Thread(target=self._voice, daemon=True).start()

    def _on_emotion(self, name: str) -> None:
        # Called from the brain thread as soon as the reply's emotion is known.
        if self.cancel.is_set():
            return
        self.tl.mark("face")
        asyncio.run_coroutine_threadsafe(send_to_robot({"type": "emotion", "name": name}), self.loop)

    def _think(self, question: str, jpeg: bytes | None, camera_wanted: bool) -> None:
        gen = brain.reply(question, jpeg, on_emotion=self._on_emotion, cancelled=self.cancel,
                          camera_wanted=camera_wanted)
        try:
            for sentence in gen:
                if self.cancel.is_set():
                    break
                if not self.spoken:
                    self.tl.mark("first sentence")
                self.spoken.append(sentence)
                print(f"{config.ROBOT_NAME} [{brain.emotion}]: {sentence}")
                self.sentences.put(sentence)
        except Interrupted:
            pass
        except Exception as e:  # never let a brain hiccup kill the server
            print(f"(brain error: {e})")
        finally:
            gen.close()  # drops the question from his memory if we bailed early
            self.sentences.put(None)

    def _voice(self) -> None:
        try:
            while (sentence := self.sentences.get()) is not None:
                if self.cancel.is_set():
                    continue
                for chunk in mouth.stream(sentence, self.leveler):
                    if self.cancel.is_set():
                        break
                    if not self.pcm:
                        self.tl.mark("first audio")
                    self.pcm.append(chunk)
                    self.audio.put(chunk)
                self.audio.put(self.BREAK)
        except Exception as e:
            print(f"(voice error: {e})")
        finally:
            self.audio.put(None)

    async def _next(self) -> bytes | None:
        return await self.loop.run_in_executor(None, self.audio.get)

    async def play(self, interruptible: bool = True) -> bool:
        """Send the audio to the speaker as it arrives. Until the first audio
        is ready the human can cancel the whole reply by talking again;
        returns False in that case. Once Rocky is speaking the mic is muted
        (his voice would trigger it) and he finishes what he's saying."""
        get = asyncio.ensure_future(self._next())
        while not get.done():
            if interruptible and (speech_started.is_set() or (ears is not None and ears.talking)):
                self._abort()
                await get
                return False
            await asyncio.wait({get}, timeout=0.05)
        first = get.result()
        if first is None:
            return True  # nothing to say
        global speaking_now
        stop_requested.clear()
        barge = interruptible and config.BARGE_IN and robot_socket is not None and robot_aec and ears is not None
        stoppable = robot_socket is not None  # a Stop click works whatever the ears do
        if ears is not None and not barge:
            ears.muted.set()
        if barge:
            # Residual echo is short; only a real sentence from the human counts.
            self._old_cancel = config.CANCEL_MIN_SPEECH
            config.CANCEL_MIN_SPEECH = config.BARGE_IN_MIN_SPEECH
            ears.apply_config()
        speaking_now = True
        try:
            if robot_socket is not None:
                await self._play_robot(first, barge=barge, stoppable=stoppable)
            else:
                await self._play_mac(first)
        finally:
            speaking_now = False
            if ears is not None:
                ears.muted.clear()
            if barge:
                config.CANCEL_MIN_SPEECH = self._old_cancel
                ears.apply_config()
        self.tl.mark("done")
        return not self.interrupted

    def _abort(self) -> None:
        self.cancel.set()
        brain.abandon()
        self.sentences.put(None)  # wake the voice thread so it can exit
        self.audio.put(None)

    def _human_cut_in(self) -> bool:
        return stop_requested.is_set() or (ears is not None and ears.talking)

    async def _play_robot(self, first: bytes, barge: bool = False, stoppable: bool = False) -> None:
        """Stream PCM to the robot (docs/protocol.md) and wait until it has
        played. With `barge` (a body that cancels its own echo) the human can
        cut in: the moment the ears hear a real sentence, playback stops and
        the rest of the reply is dropped."""
        robot_speak_done.clear()
        speech_started.clear()
        # bytes 0 = length unknown: the robot starts after 200 ms of buffer.
        await send_to_robot({"type": "speak_begin", "bytes": 0})
        self.tl.mark("speaking")
        buf = bytearray()
        total = 0
        chunk: bytes | None = first
        while chunk is not None:
            if (barge and self._human_cut_in()) or (stoppable and stop_requested.is_set()):
                await self._cut_off()
                return
            buf += chunk
            while len(buf) >= FRAME_BYTES:
                if robot_socket is None:
                    return
                await robot_socket.send(b"\x01" + bytes(buf[:FRAME_BYTES]))
                del buf[:FRAME_BYTES]
                total += FRAME_BYTES
            chunk = await self._next()
        if buf and robot_socket is not None:
            await robot_socket.send(b"\x01" + bytes(buf))
            total += len(buf)
        await send_to_robot({"type": "speak_end"})
        deadline = time.time() + total / 32000 + 5
        while not robot_speak_done.is_set():
            if (barge and self._human_cut_in()) or (stoppable and stop_requested.is_set()):
                await self._cut_off()
                return
            if time.time() > deadline:
                print("(robot never said it finished speaking)")
                return
            await asyncio.sleep(0.05)

    async def _cut_off(self) -> None:
        """The human started talking over him: stop the body, drop the rest."""
        self.interrupted = True
        print("  (stopped)" if stop_requested.is_set() else "  (you cut in — stopping)")
        self.cancel.set()
        self.sentences.put(None)
        self.audio.put(None)
        robot_speak_done.clear()
        await send_to_robot({"type": "speak_stop"})
        try:
            await asyncio.wait_for(robot_speak_done.wait(), timeout=2)
        except asyncio.TimeoutError:
            pass

    async def _play_mac(self, first: bytes) -> None:
        """No robot: play each sentence on the Mac as soon as it's complete."""
        self.tl.mark("speaking")
        buf = bytearray()
        chunk: bytes | None = first
        while chunk is not None:
            if chunk == self.BREAK:
                if buf:
                    await self.loop.run_in_executor(None, mouth.play, bytes(buf))
                    buf = bytearray()
            else:
                buf += chunk
            chunk = await self._next()
        if buf:
            await self.loop.run_in_executor(None, mouth.play, bytes(buf))


async def converse(question: str, ended_at: float | None = None, heard_at: float | None = None,
                   interruptible: bool = True) -> bool:
    """Ask the brain, show the face, and speak the answer as it forms.
    Returns False if the human started talking again before Rocky spoke
    (the reply was dropped and the question is still open)."""
    global awake_until
    loop = asyncio.get_running_loop()
    tl = Timeline(ended_at or time.time())
    if heard_at is not None:
        tl.marks["heard"] = heard_at
    speech_started.clear()
    await send_to_robot({"type": "emotion", "name": "thinking"})
    camera_wanted = config.SEND_CAMERA_TO_BRAIN and wants_camera(question)
    jpeg = eyes.latest() if camera_wanted else None
    if camera_wanted and jpeg is None:
        print("  (camera has no fresh frame — telling him he can't see right now)")
    reply = SpokenReply(loop, tl)
    global current_reply
    current_reply = reply
    reply.think_and_speak(question, jpeg, camera_wanted)
    global thinking
    thinking = True
    try:
        # A typed question is never cancelled by room noise: only a spoken
        # one can be "continued" by the human talking on.
        finished = await reply.play(interruptible=interruptible)
    except Exception as e:  # a speaker hiccup shouldn't kill the server
        print(f"(could not speak: {e})")
        finished = True
    finally:
        thinking = False
    if reply.interrupted:
        # He was talking and you spoke over him: what you said next is a new
        # question (the ears already have it); nothing to re-answer here.
        awake_until = time.time() + config.AWAKE_SECONDS
        if reply.text:
            journal(question, reply.text + " [cut off]")
        last_exchange.update(q=question, a=reply.text, at=time.time(), cut=True)
        return True
    if not finished:
        print("  (you kept talking — Rocky will hear the rest and answer once)")
        await send_to_robot({"type": "emotion", "name": "neutral"})
        return False
    if reply.text:
        eyes.last_said = reply.text
        journal(question, reply.text)
        if config.DEBUG_TTS_CHECK and reply.pcm:
            loop.run_in_executor(None, check_tts, reply.text, b"".join(reply.pcm))
    last_exchange.update(q=question, a=reply.text, at=time.time(), cut=False)
    awake_until = time.time() + config.AWAKE_SECONDS
    tl.report()
    return True


def journal(question: str, answer: str) -> None:
    """One file a day of what was actually asked and said (never overheard
    speech), the raw material for the nightly reflection into shared memory."""
    try:
        d = os.path.expanduser(config.JOURNAL_DIR)
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, time.strftime("%Y-%m-%d") + ".md")
        new = not os.path.exists(path)
        with open(path, "a", encoding="utf-8") as f:
            if new:
                f.write(f"# {time.strftime('%Y-%m-%d')} — {config.ROBOT_NAME}'s day\n\n")
            f.write(f"**{time.strftime('%H:%M')} {config.HUMAN_NAME}:** {question.strip()}\n\n")
            f.write(f"**{config.ROBOT_NAME}:** {answer.strip()}\n\n")
    except OSError as e:
        print(f"(journal: {e})")


async def say(text: str) -> bytes:
    """Speak a fixed line: through the robot's speaker when it's connected,
    else the Mac. Ears are muted meanwhile so Rocky doesn't hear himself."""
    reply = SpokenReply(asyncio.get_running_loop(), Timeline(time.time()))
    global current_reply
    current_reply = reply
    reply.speak_fixed(text)
    try:
        await reply.play(interruptible=False)
    except Exception as e:
        print(f"(could not speak: {e})")
    return b"".join(reply.pcm)


_tts_checker = None


def check_tts(text: str, pcm: bytes) -> None:
    """Transcribe what the voice model produced and compare it with the text
    it was given. Extra words = the model hallucinated (a laugh, "hello", a
    sound). Runs in a worker thread; prints only when something's off."""
    global _tts_checker
    import re
    from .ears import Transcriber
    if _tts_checker is None:
        _tts_checker = Transcriber("base.en")
    import numpy as np
    audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
    heard_text = _tts_checker.transcribe(audio)
    words = lambda t: set(re.findall(r"[a-z']+", t.lower()))
    said, got = words(mouth.clean_for_tts(text)), words(heard_text)
    extra = got - said
    missing = said - got
    # Transcription is imperfect: only shout when several words are foreign.
    if len(extra) >= 3 or (len(extra) >= 2 and len(extra) >= len(got) / 3):
        print(f"  !! TTS CHECK: audio contains words not in the text: {sorted(extra)}")
        print(f"     text : {text}\n     heard: {heard_text}")
    elif len(missing) >= max(3, len(said) // 2):
        print(f"  !! TTS CHECK: audio is missing much of the text. heard: {heard_text}")


async def set_volume(level: float) -> None:
    global speaker_volume
    speaker_volume = max(0.0, min(1.0, level))
    await send_to_robot({"type": "volume", "level": speaker_volume})


# ── The live-view console (http://localhost:8766) ────────────────────────────

def console_state() -> dict:
    """Extra fields for /status: everything the page shows beyond the camera."""
    now = time.time()
    return {
        "robot": robot_socket is not None,
        "listening": ears is not None,
        "mic": ears.source if ears is not None else None,
        "level": ears.level if ears is not None else 0.0,
        "speech_prob": ears.speech_prob if ears is not None else 0.0,
        "hearing": ears.hearing if ears is not None else False,
        "speaking": speaking_now,
        "saying": current_reply.text if (current_reply is not None and (speaking_now or thinking)) else "",
        "body_aec": robot_aec,
        "mic_frames": ears.frames if ears is not None else 0,
        "addressed_last": __import__("brain.addressed", fromlist=["last"]).last,
        "thinking": thinking,
        "awake": now < awake_until,
        "awake_for": max(0.0, awake_until - now),
        "emotion": current_emotion,
        "voice": {k: getattr(config, k) for k in VOICE_TUNABLE},
        "head_held": head_held,
        "tracking_enabled": tracker.enabled if tracker is not None else False,
        "volume": speaker_volume,
        "tuning": {k: getattr(config, k) for k in TUNABLE},
        "settings": {k: getattr(config, k) for k in config.SETTINGS_KEYS if not isinstance(getattr(config, k), list)},
        "setting_ranges": {k: list(v) for k, v in {**TUNABLE, **VOICE_TUNABLE}.items()},
    }


def console_command(action: str, payload: dict) -> dict:
    """A control from the page. Runs on the HTTP thread; hops onto the event
    loop. Raises ValueError for anything the page shouldn't have asked."""
    fut = asyncio.run_coroutine_threadsafe(_console_command(action, payload), main_loop)
    return fut.result(timeout=10)


def _number(payload: dict, key: str, lo: float, hi: float) -> float:
    try:
        v = float(payload[key])
    except (KeyError, TypeError, ValueError):
        raise ValueError(f"{key} must be a number")
    if not (lo <= v <= hi):
        raise ValueError(f"{key} must be between {lo:g} and {hi:g}")
    return v


async def _console_command(action: str, payload: dict) -> dict:
    global awake_until
    if action == "emotion":
        name = payload.get("name")
        if name not in config.EMOTIONS:
            raise ValueError(f"emotions: {', '.join(config.EMOTIONS)}")
        await send_to_robot({"type": "emotion", "name": name})
    elif action == "head":
        pan = _number(payload, "pan", -config.TRACK_PAN_LIMIT, config.TRACK_PAN_LIMIT)
        tilt = _number(payload, "tilt", config.TRACK_TILT_MIN, config.TRACK_TILT_MAX)
        if tracker is not None and tracker.enabled:
            await set_tracking(False)
        await set_head_held(True)
        await send_to_robot({"type": "pan", "deg": pan})
        await send_to_robot({"type": "tilt", "deg": tilt})
        if tracker is not None:
            tracker.note_pose(pan=pan, tilt=tilt)
    elif action == "center":
        await set_head_held(False)
        await send_to_robot({"type": "pan", "deg": 0})
        await send_to_robot({"type": "tilt", "deg": 0})
        if tracker is not None:
            tracker.note_pose(pan=0, tilt=0)
    elif action == "volume":
        await set_volume(_number(payload, "level", 0.0, 1.0))
    elif action == "track":
        await set_tracking(bool(payload.get("on", True)))
    elif action == "sleep":
        if payload.get("on", True):
            awake_until = 0.0
            await send_to_robot({"type": "emotion", "name": "sleepy"})
            await send_to_robot({"type": "asleep", "on": True})
            await set_head_held(False)
        else:
            awake_until = time.time() + config.AWAKE_SECONDS
            await send_to_robot({"type": "asleep", "on": False})
            await send_to_robot({"type": "emotion", "name": "neutral"})
    elif action == "stop":
        stop_requested.set()
    elif action == "notify":
        # A sub-agent (a Claude Code session in a terminal) reporting in via
        # tools/subagent-hook: log it, show a face, say it out loud.
        text = " ".join(str(payload.get("text", "")).split())[:300]
        if not text:
            raise ValueError("text required")
        kind = str(payload.get("kind") or "info")
        project = str(payload.get("project") or "")
        try:
            d = os.path.expanduser(config.JOURNAL_DIR)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "agents.log"), "a", encoding="utf-8") as f:
                f.write(f"{time.strftime('%Y-%m-%d %H:%M')} [{kind}] {project}: {text}\n")
        except OSError:
            pass
        secs = float(payload.get("turn_seconds") or 0)
        # A "done" with an unknown duration is treated as a short chat turn: silence beats spam.
        quiet = (not config.ANNOUNCE_AGENTS) or (kind == "done" and secs < config.AGENT_MIN_TURN_SECONDS)
        print(f"sub-agent [{kind}] {project} ({secs:.0f}s){' (quiet)' if quiet else ''}: {text}")
        if quiet:
            return {}
        # Wake for a moment so a follow-up ("what did it say?") needs no wake word,
        # and so the face and the status agree about being awake.
        awake_until = max(awake_until, time.time() + 20)
        emotion = "happy" if kind == "done" else "surprised"
        await send_to_robot({"type": "asleep", "on": False})
        await send_to_robot({"type": "emotion", "name": emotion})
        asyncio.create_task(say(text))
    elif action in ("say", "ask"):
        text = str(payload.get("text", "")).strip()
        if not text or len(text) > 300:
            raise ValueError("text must be 1 to 300 characters")
        print(f"console: {action} {text}")
        asyncio.create_task(say(text) if action == "say" else converse(text, interruptible=False))
    elif action == "tune":
        key = payload.get("key")
        if key not in TUNABLE:
            raise ValueError(f"tunable: {', '.join(TUNABLE)}")
        value = _number(payload, "value", *TUNABLE[key])
        setattr(config, key, value)
        if ears is not None:
            ears.apply_config()
        config.save_setting(key, value)
        print(f"console: {key} = {value:g}")
    elif action == "voice":
        # Speaker tuning; takes effect on the next reply.
        key = payload.get("key")
        if key not in VOICE_TUNABLE:
            raise ValueError(f"voice settings: {', '.join(VOICE_TUNABLE)}")
        value = _number(payload, "value", *VOICE_TUNABLE[key])
        setattr(config, key, value)
        config.save_setting(key, value)
        print(f"console: {key} = {value:g}")
    elif action == "setting":
        # Anything else in config.SETTINGS_KEYS: saved now, applied on the
        # next brain restart (model, personality, name, voice, sentence cap...).
        key = payload.get("key")
        if key not in config.SETTINGS_KEYS:
            raise ValueError(f"settings: {', '.join(config.SETTINGS_KEYS)}")
        value = payload.get("value")
        kind = type(getattr(config, key))
        try:
            value = kind(value) if kind in (int, float, str) else bool(value)
        except (TypeError, ValueError):
            raise ValueError(f"{key} must be a {kind.__name__}")
        config.save_setting(key, value)  # also sets config.<key> now; most are read fresh each turn
        print(f"console: {key} = {value!r}")
    else:
        raise ValueError(f"no such control: {action}")
    return {}


# ── Listening ────────────────────────────────────────────────────────────────

async def mic_meter() -> None:
    """Three seconds of live mic level and speech probability, so you can see
    whether it hears you."""
    if ears is None:
        print("(not listening — type `listen` first)")
        return
    which = "robot mic" if ears.source == "robot" else f"Mac mic \"{ears.device_name}\""
    print(f"{which}: talk for 3 seconds...")
    peak_level = 0.0
    peak_prob = 0.0
    for _ in range(12):
        await asyncio.sleep(0.25)
        level, prob = ears.level, ears.speech_prob
        peak_level = max(peak_level, level)
        peak_prob = max(peak_prob, prob)
        print(f"  level {level:.3f} {'#' * min(40, int(level * 500)):40s} speech {prob:.2f}")
    print(f"peak level {peak_level:.3f}, peak speech probability {peak_prob:.2f} (needs > {config.VAD_THRESHOLD}) ->",
          "speech detected" if peak_prob > config.VAD_THRESHOLD else
          ("NOT DETECTED: raise MIC_GAIN in firmware config.h, or get closer" if ears.source == "robot" else
           "NOT DETECTED: wrong mic, gain down, or no mic permission"))
    if ears.source == "mac":
        import sounddevice as sd
        print("other inputs:", ", ".join(f"[{i}] {d['name']}" for i, d in enumerate(sd.query_devices()) if d["max_input_channels"] > 0))


async def start_listening() -> None:
    global ears
    loop = asyncio.get_running_loop()
    print(f"loading speech model {config.STT_MODEL} and the turn-taking models (first run downloads them)...")
    try:
        ears = await loop.run_in_executor(
            None,
            lambda: Ears(
                on_utterance=lambda text, t0, t1: loop.call_soon_threadsafe(
                    heard.put_nowait, (text, t0, t1, time.time())
                ),
                on_speech_start=lambda: loop.call_soon_threadsafe(speech_started.set),
            ),
        )
        mic = await loop.run_in_executor(None, ears.start)
    except Exception as e:
        ears = None
        print(f"(could not start listening: {e})")
        print("  check: mic plugged in? Is your terminal allowed to use the microphone (macOS:")
        print("  System Settings > Privacy & Security > Microphone)? MIC_DEVICE in server/.env?")
        return
    if ears.mac_error:
        print(f"(Mac mic unavailable: {ears.mac_error})")
        print("  the robot's mic still works; for a Mac fallback check MIC_DEVICE in server/.env,")
        print("  plug the interface in, or allow the Terminal to use the microphone")
    else:
        print(f"listening on \"{mic}\" — say \"hey {config.ROBOT_NAME}\"")
    pick_mic_source()


def stop_listening() -> None:
    global ears
    if ears is not None:
        ears.stop()
        ears = None
    print("stopped listening")


async def head_loop() -> None:
    """Sends the tracker's head moves to the robot; pauses idle glances while
    a face is being followed and resumes them when it's lost."""
    was_tracking = False
    while True:
        pan, tilt, tracking = await head_moves.get()
        if tracking != was_tracking:
            print("tracking: face found — head follows" if tracking else "tracking: face lost — idle glances resume")
            was_tracking = tracking
        if pan is not None:
            await send_to_robot({"type": "pan", "deg": pan})
        if tilt is not None:
            await send_to_robot({"type": "tilt", "deg": tilt})
        eyes.tracking_info = {"tracking": tracking, "pan": pan, "tilt": tilt}


async def doze_loop() -> None:
    """When the awake clock runs out, he nods off on his own (sleepy face,
    no announcement). Saying "hey Rocky" wakes him again."""
    was_awake = False
    while True:
        await asyncio.sleep(1)
        awake = time.time() < awake_until
        if was_awake and not awake:
            print(f"({config.ROBOT_NAME} dozed off — say \"hey {config.ROBOT_NAME}\" to wake him)")
            await send_to_robot({"type": "asleep", "on": True})
            await set_head_held(False)  # idle life resumes; the head may wander again
        was_awake = awake


async def _next_heard() -> tuple[str, float, float, float] | None:
    """Wait for the rest of an interrupted question. Keeps waiting while the
    ears still hear speech; gives up after a few quiet seconds."""
    waited = 0.0
    while True:
        try:
            return await asyncio.wait_for(heard.get(), timeout=0.5)
        except asyncio.TimeoutError:
            waited += 0.5
            hearing = ears is not None and ears.hearing
            if (not hearing and waited >= 4.0) or waited >= 30.0:
                return None


async def voice_loop() -> None:
    """Turns what the ears hear into conversations. A bug in one turn must
    not kill the loop (then nothing you say would get through), so each turn
    is guarded."""
    while True:
        item = await heard.get()
        try:
            await _handle_heard(item)
        except Exception as e:
            import traceback
            traceback.print_exc()
            print(f"(voice loop error, ignoring that turn: {e})")


async def _handle_heard(item: tuple[str, float, float, float]) -> None:
    global awake_until
    text, started_at, ended_at, heard_at = item
    woke, question = strip_wake_word(text)
    # Judge the follow-up window by when you STARTED talking, not by when
    # the transcript arrived — long sentences shouldn't time out.
    if not woke and started_at >= awake_until:
        print(f"(heard, ignoring: {text})")
        return
    if not woke:
        # Awake, no name said: was that for him, or for someone else in the room?
        ok, p = await asyncio.get_running_loop().run_in_executor(
            None, _addressed, question, last_exchange["q"], last_exchange["a"],
            time.time() - last_exchange["at"], last_exchange["cut"])
        if not ok:
            print(f"(heard, not for me (p={p:.2f}): {text})")
            return
    print(f"{config.HUMAN_NAME}: {text}")
    eyes.last_heard = text
    awake_until = time.time() + config.AWAKE_SECONDS  # anything you say keeps him up
    norm = normalize(text)
    lines = personality.LINES
    if any(p in norm for p in config.TRACK_ON_PHRASES) and not any(p in norm for p in config.TRACK_OFF_PHRASES):
        await set_tracking(True)
        print(f"{config.ROBOT_NAME} [happy]: {lines['track_on']}")
        await send_to_robot({"type": "emotion", "name": "happy"})
        await say(lines["track_on"])
        return
    if any(p in norm for p in config.TRACK_OFF_PHRASES):
        await set_tracking(False)
        print(f"{config.ROBOT_NAME} [neutral]: {lines['track_off']}")
        await send_to_robot({"type": "emotion", "name": "neutral"})
        await say(lines["track_off"])
        return
    if any(p in norm for p in config.SLEEP_PHRASES):
        # "Rocky, sleep": goodnight line, sleepy face, and only "hey Rocky"
        # wakes him. No brain call.
        awake_until = 0.0
        print(f"{config.ROBOT_NAME} [sleepy]: {lines['sleep']}")
        await send_to_robot({"type": "emotion", "name": "sleepy"})
        await say(lines["sleep"])
        await send_to_robot({"type": "asleep", "on": True})
        awake_until = 0.0  # say() doesn't touch it, but be explicit
        return
    if woke:
        # Heard his name: eyes open, perk up to eye level (tilt can't go
        # above 0 on this build — the platform would hit the pan servo).
        await send_to_robot({"type": "asleep", "on": False})
        await send_to_robot({"type": "emotion", "name": "surprised"})
        if tracker is None or not tracker.tracking:
            await send_to_robot({"type": "tilt", "deg": 0})
            if tracker is not None:
                tracker.note_pose(tilt=0)
    if woke and not question:
        # Just "hey Rocky" — wait for the actual question.
        await say(lines["wake"])
        awake_until = time.time() + config.AWAKE_SECONDS
        return
    finished = await converse(question, ended_at, heard_at)
    while not finished:
        # He was cut off while thinking: wait for the rest of the sentence
        # and answer the whole thing once.
        item = await _next_heard()
        if item is None:
            print("  (didn't catch the rest — answering what I heard)")
            finished = await converse(question)
            continue
        text, started_at, ended_at, heard_at = item
        _, more = strip_wake_word(text)
        print(f"{config.HUMAN_NAME}: {text}")
        question = f"{question} {more}".strip()
        eyes.last_heard = question
        awake_until = time.time() + config.AWAKE_SECONDS
        finished = await converse(question, ended_at, heard_at)


async def console_loop() -> None:
    loop = asyncio.get_running_loop()
    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:  # EOF
            break
        if not await handle_console_line(line):
            break


def seed_memory() -> None:
    """First run: give him a memory folder to read, from workspace/memory-template."""
    import shutil
    mem = os.path.expanduser(config.MEMORY_DIR)
    tpl = os.path.join(os.path.expanduser(config.CLAUDE_WORKSPACE), "memory-template")
    try:
        os.makedirs(mem, exist_ok=True)
        for name in ("Shared-Memory.md", "Profile.md", "Handoffs.md", "README.md"):
            dst, src = os.path.join(mem, name), os.path.join(tpl, name)
            if not os.path.exists(dst) and os.path.exists(src):
                shutil.copy(src, dst)
        link = os.path.join(os.path.expanduser(config.CLAUDE_WORKSPACE), "memory")
        if not os.path.lexists(link) and os.path.realpath(mem) != os.path.realpath(link):
            os.symlink(mem, link)   # CLAUDE.md imports @memory/...
        os.makedirs(os.path.expanduser(config.NOTES_INBOX), exist_ok=True)
    except OSError as e:
        print(f"(memory folder: {e})")


async def main() -> None:
    seed_memory()
    print(f"{config.ROBOT_NAME} brain server — brain {config.BRAIN} ({config.CLAUDE_MODEL if config.BRAIN == 'claude-code' else config.MODEL})")
    print(f"listening for the robot on ws://0.0.0.0:{config.PORT}")
    eyes.state_provider = console_state
    eyes.command_handler = console_command
    eyes.serve(config.LIVE_VIEW_PORT, config.LIVE_VIEW_BIND)
    print(f"live view + controls: http://localhost:{config.LIVE_VIEW_PORT}/  (this computer only)")
    if not os.environ.get("ROBOT_TOKEN"):
        print("WARNING: ROBOT_TOKEN is not set in server/.env — the robot will be refused")
    global tracker, brain, main_loop
    loop = asyncio.get_running_loop()
    main_loop = loop
    if config.BRAIN == "claude-code":
        from .claude_brain import ClaudeCodeBrain
        brain = ClaudeCodeBrain()
    else:
        brain = RobotBrain(ABILITIES)
    tracker = Tracker(eyes, lambda p, t, on: loop.call_soon_threadsafe(head_moves.put_nowait, (p, t, on)))
    eyes.has_annotator = True
    tracker.start()
    print("face tracking:", "on" if config.TRACKING else f"off — say \"{config.ROBOT_NAME}, track me\" or type `track on`")
    print("type `ask <question>` to talk to the brain right now\n")
    async with websockets.serve(handle_robot, "0.0.0.0", config.PORT, max_size=256 * 1024):
        voice_task = asyncio.create_task(voice_loop())
        doze_task = asyncio.create_task(doze_loop())
        head_task = asyncio.create_task(head_loop())
        try:
            from .vocabulary import stt_prompt
            config.STT_PROMPT = stt_prompt()
            print(f"speech hint: {config.STT_PROMPT[:120]}...")
        except Exception as e:
            print(f"(speech hint not built: {e})")
        if config.LISTEN_ON_START:
            await start_listening()
        try:
            await console_loop()
        finally:
            voice_task.cancel()
            doze_task.cancel()
            head_task.cancel()
            if ears is not None:
                stop_listening()


def _watch_parent() -> None:
    """When the Mac app that launched us dies (even by SIGKILL), follow it:
    an orphaned brain would keep the ports and the microphone."""
    parent = os.environ.get("DESK_ROBOT_PARENT_PID")
    if not parent:
        return
    def run() -> None:
        while os.getppid() == int(parent):
            time.sleep(1)
        print("(parent app is gone; shutting down)")
        os._exit(0)
    threading.Thread(target=run, daemon=True).start()


if __name__ == "__main__":
    _watch_parent()
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
