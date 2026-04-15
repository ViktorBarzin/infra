#!/usr/bin/env python3
"""
Generate voice samples for all available voices.
Run this script in an environment with audiblez installed.

Usage:
    python generate_samples.py [output_dir]
"""

import os
import sys
from pathlib import Path

# Sample text for voice preview
SAMPLE_TEXT = "The quick brown fox jumps over the lazy dog. This is a sample of my voice for audiobook narration."

# All voices from Kokoro-82M (audiblez)
VOICES = [
    # American English (20 voices)
    "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore",
    "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
    "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael",
    "am_onyx", "am_puck", "am_santa",
    # British English (8 voices)
    "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
    "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
    # Spanish (3 voices)
    "ef_dora", "em_alex", "em_santa",
    # French (1 voice)
    "ff_siwis",
    # Hindi (4 voices)
    "hf_alpha", "hf_beta", "hm_omega", "hm_psi",
    # Italian (2 voices)
    "if_sara", "im_nicola",
    # Japanese (5 voices)
    "jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo",
    # Brazilian Portuguese (3 voices)
    "pf_dora", "pm_alex", "pm_santa",
    # Mandarin Chinese (8 voices)
    "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi",
    "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang",
]


def generate_sample(voice: str, output_dir: Path):
    """Generate a voice sample using kokoro TTS."""
    try:
        from kokoro import KPipeline

        output_file = output_dir / f"{voice}.mp3"
        if output_file.exists():
            print(f"Skipping {voice} - already exists")
            return True

        print(f"Generating sample for {voice}...")

        # Map voice prefix to language code
        lang_map = {
            'a': 'a',   # American English
            'b': 'b',   # British English
            'e': 'e',   # Spanish
            'f': 'f',   # French
            'h': 'h',   # Hindi
            'i': 'i',   # Italian
            'j': 'j',   # Japanese
            'p': 'p',   # Portuguese
            'z': 'z',   # Chinese
        }

        # Extract language code from voice (first letter)
        lang_code = lang_map.get(voice[0], 'a')

        # Initialize the Kokoro pipeline
        pipeline = KPipeline(lang_code=lang_code)

        # Generate audio
        generator = pipeline(SAMPLE_TEXT, voice=voice, speed=1.0)

        # Collect all audio chunks
        audio_chunks = []
        for _, _, audio in generator:
            audio_chunks.append(audio)

        if audio_chunks:
            import soundfile as sf
            import numpy as np

            # Concatenate audio
            audio = np.concatenate(audio_chunks)

            # Save as WAV first, then convert to MP3
            wav_file = output_dir / f"{voice}.wav"
            sf.write(str(wav_file), audio, 24000)

            # Convert to MP3 using ffmpeg
            import subprocess
            result = subprocess.run([
                "ffmpeg", "-y", "-i", str(wav_file),
                "-codec:a", "libmp3lame", "-qscale:a", "5",
                str(output_file)
            ], capture_output=True)

            # Remove WAV file
            if wav_file.exists():
                wav_file.unlink()

            if result.returncode == 0:
                print(f"Generated {output_file}")
                return True
            else:
                print(f"FFmpeg failed for {voice}: {result.stderr.decode()}")
                return False
        else:
            print(f"Failed to generate audio for {voice}")
            return False

    except Exception as e:
        print(f"Error generating sample for {voice}: {e}")
        return False


def main():
    output_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("samples")
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Generating voice samples to {output_dir}")
    print(f"Total voices: {len(VOICES)}")

    for voice in VOICES:
        generate_sample(voice, output_dir)

    print("Done!")


if __name__ == "__main__":
    main()
