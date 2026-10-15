"""Was that said to the robot, or to someone else in the room?

While he is awake, anything the microphone hears is treated as a question.
In a room with other people (or a video playing) that makes him answer
conversations that were never his. A tiny typed judgment from TypeSafe's
Jev model decides, in a few hundred milliseconds, whether the utterance was
addressed to him. Fails open: no key, no network, or a slow answer means
"yes, it was for me", exactly the old behaviour.
"""

from __future__ import annotations

import json
import os
import time
import urllib.request

from . import config

_URL = "https://api.typesafe.ai/v1/systemone"
last: dict = {"p": None, "text": "", "ms": 0}


def addressed(utterance: str, last_question: str, last_reply: str, seconds_since: float,
              just_cut_in: bool) -> tuple[bool, float | None]:
    """(addressed?, probability). Probability is None when the check did not run."""
    key = os.environ.get("TYPESAFE_API_KEY", "")
    if not config.ADDRESSED_CHECK or not key:
        return True, None
    reply_asked = last_reply.rstrip().endswith("?")
    state = {
        "robot_name": config.ROBOT_NAME,
        "setting": (f"{config.ROBOT_NAME} is a voice assistant on {config.HUMAN_NAME}'s desk. He is awake because "
                    f"{config.HUMAN_NAME} spoke to him within the last minute, so he hears everything said in the room, "
                    "including other people, phone calls, and video playing."),
        "last_exchange": {"human_said": last_question[:400], "robot_replied": last_reply[:400],
                          "robot_ended_with_a_question": reply_asked},
        "seconds_since_that_exchange": round(seconds_since, 1),
        "robot_was_just_interrupted_mid_sentence": just_cut_in,
        "utterance": utterance[:500],
    }
    body = {
        "model": "jev-latest",
        "state": state,
        "questions": {
            "to_robot": {
                "type": "noul",
                "instructions": (
                    "Is `utterance` spoken to the robot (a question, instruction, answer, or follow-up meant for it), "
                    "rather than to another person, a phone, or just talking to oneself? A short reply like "
                    "\"yes\", \"go ahead\", \"no\" right after `last_exchange.robot_replied` ended with a question counts "
                    "as spoken to the robot. Something addressed to a named other person, or a fragment of a "
                    "conversation about an unrelated topic that does not refer to the robot or its last reply, is not."
                ),
            }
        },
    }
    req = urllib.request.Request(_URL, data=json.dumps(body).encode(), method="POST")
    req.add_header("Authorization", "Bearer " + key)
    req.add_header("Content-Type", "application/json")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=1.5) as r:
            ans = json.load(r)["answers"]["to_robot"]
        p = float(ans.get("noul"))
    except Exception as e:  # slow or down: behave as before (answer it)
        print(f"  (addressed check skipped: {e})")
        return True, None
    last.update(p=p, text=utterance, ms=int((time.time() - t0) * 1000))
    print(f"  (for me? p={p:.2f} in {last['ms']} ms)")
    return p >= config.ADDRESSED_THRESHOLD, p
