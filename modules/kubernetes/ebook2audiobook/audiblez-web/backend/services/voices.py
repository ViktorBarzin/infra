from models.schemas import Voice

# Voice catalog from Kokoro-82M (used by audiblez)
# https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md
VOICE_CATALOG = {
    # American English
    "af_heart": Voice(id="af_heart", name="Heart", language="American English", gender="F"),
    "af_alloy": Voice(id="af_alloy", name="Alloy", language="American English", gender="F"),
    "af_aoede": Voice(id="af_aoede", name="Aoede", language="American English", gender="F"),
    "af_bella": Voice(id="af_bella", name="Bella", language="American English", gender="F"),
    "af_jessica": Voice(id="af_jessica", name="Jessica", language="American English", gender="F"),
    "af_kore": Voice(id="af_kore", name="Kore", language="American English", gender="F"),
    "af_nicole": Voice(id="af_nicole", name="Nicole", language="American English", gender="F"),
    "af_nova": Voice(id="af_nova", name="Nova", language="American English", gender="F"),
    "af_river": Voice(id="af_river", name="River", language="American English", gender="F"),
    "af_sarah": Voice(id="af_sarah", name="Sarah", language="American English", gender="F"),
    "af_sky": Voice(id="af_sky", name="Sky", language="American English", gender="F"),
    "am_adam": Voice(id="am_adam", name="Adam", language="American English", gender="M"),
    "am_echo": Voice(id="am_echo", name="Echo", language="American English", gender="M"),
    "am_eric": Voice(id="am_eric", name="Eric", language="American English", gender="M"),
    "am_fenrir": Voice(id="am_fenrir", name="Fenrir", language="American English", gender="M"),
    "am_liam": Voice(id="am_liam", name="Liam", language="American English", gender="M"),
    "am_michael": Voice(id="am_michael", name="Michael", language="American English", gender="M"),
    "am_onyx": Voice(id="am_onyx", name="Onyx", language="American English", gender="M"),
    "am_puck": Voice(id="am_puck", name="Puck", language="American English", gender="M"),
    "am_santa": Voice(id="am_santa", name="Santa", language="American English", gender="M"),

    # British English
    "bf_alice": Voice(id="bf_alice", name="Alice", language="British English", gender="F"),
    "bf_emma": Voice(id="bf_emma", name="Emma", language="British English", gender="F"),
    "bf_isabella": Voice(id="bf_isabella", name="Isabella", language="British English", gender="F"),
    "bf_lily": Voice(id="bf_lily", name="Lily", language="British English", gender="F"),
    "bm_daniel": Voice(id="bm_daniel", name="Daniel", language="British English", gender="M"),
    "bm_fable": Voice(id="bm_fable", name="Fable", language="British English", gender="M"),
    "bm_george": Voice(id="bm_george", name="George", language="British English", gender="M"),
    "bm_lewis": Voice(id="bm_lewis", name="Lewis", language="British English", gender="M"),

    # Japanese
    "jf_alpha": Voice(id="jf_alpha", name="Alpha", language="Japanese", gender="F"),
    "jf_gongitsune": Voice(id="jf_gongitsune", name="Gongitsune", language="Japanese", gender="F"),
    "jf_nezumi": Voice(id="jf_nezumi", name="Nezumi", language="Japanese", gender="F"),
    "jf_tebukuro": Voice(id="jf_tebukuro", name="Tebukuro", language="Japanese", gender="F"),
    "jm_kumo": Voice(id="jm_kumo", name="Kumo", language="Japanese", gender="M"),

    # Mandarin Chinese
    "zf_xiaobei": Voice(id="zf_xiaobei", name="Xiaobei", language="Mandarin Chinese", gender="F"),
    "zf_xiaoni": Voice(id="zf_xiaoni", name="Xiaoni", language="Mandarin Chinese", gender="F"),
    "zf_xiaoxiao": Voice(id="zf_xiaoxiao", name="Xiaoxiao", language="Mandarin Chinese", gender="F"),
    "zf_xiaoyi": Voice(id="zf_xiaoyi", name="Xiaoyi", language="Mandarin Chinese", gender="F"),
    "zm_yunjian": Voice(id="zm_yunjian", name="Yunjian", language="Mandarin Chinese", gender="M"),
    "zm_yunxi": Voice(id="zm_yunxi", name="Yunxi", language="Mandarin Chinese", gender="M"),
    "zm_yunxia": Voice(id="zm_yunxia", name="Yunxia", language="Mandarin Chinese", gender="M"),
    "zm_yunyang": Voice(id="zm_yunyang", name="Yunyang", language="Mandarin Chinese", gender="M"),

    # Spanish
    "ef_dora": Voice(id="ef_dora", name="Dora", language="Spanish", gender="F"),
    "em_alex": Voice(id="em_alex", name="Alex", language="Spanish", gender="M"),
    "em_santa": Voice(id="em_santa", name="Santa", language="Spanish", gender="M"),

    # French
    "ff_siwis": Voice(id="ff_siwis", name="Siwis", language="French", gender="F"),

    # Hindi
    "hf_alpha": Voice(id="hf_alpha", name="Alpha", language="Hindi", gender="F"),
    "hf_beta": Voice(id="hf_beta", name="Beta", language="Hindi", gender="F"),
    "hm_omega": Voice(id="hm_omega", name="Omega", language="Hindi", gender="M"),
    "hm_psi": Voice(id="hm_psi", name="Psi", language="Hindi", gender="M"),

    # Italian
    "if_sara": Voice(id="if_sara", name="Sara", language="Italian", gender="F"),
    "im_nicola": Voice(id="im_nicola", name="Nicola", language="Italian", gender="M"),

    # Brazilian Portuguese
    "pf_dora": Voice(id="pf_dora", name="Dora", language="Brazilian Portuguese", gender="F"),
    "pm_alex": Voice(id="pm_alex", name="Alex", language="Brazilian Portuguese", gender="M"),
    "pm_santa": Voice(id="pm_santa", name="Santa", language="Brazilian Portuguese", gender="M"),
}


def get_all_voices() -> list[Voice]:
    """Get all available voices."""
    return list(VOICE_CATALOG.values())


def get_voice(voice_id: str) -> Voice | None:
    """Get a specific voice by ID."""
    return VOICE_CATALOG.get(voice_id)


def get_voices_by_language() -> dict[str, list[Voice]]:
    """Get voices grouped by language."""
    grouped = {}
    for voice in VOICE_CATALOG.values():
        if voice.language not in grouped:
            grouped[voice.language] = []
        grouped[voice.language].append(voice)
    return grouped
