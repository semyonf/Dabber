# Backlog

- **Speech-to-text (Whisper)**: built on 2026-09-24 (whisper.cpp v1.9.4, large-v3-turbo + Silero VAD, per-track Я/Собеседники) and removed the same day at the user's request as too heavy for the app; see git history before the revert. Original note: Transcribe finished sessions. Ideas: transcribe
  per-source tracks separately (mic = the user, computer audio = the other side) to label speakers; optional
  preprocessing tuned for recognition (compressor, EQ) before Whisper; show marks inside the transcript.
- **Deferred review items** (2026-09-23): drift resampler quality (windowed-sinc instead of linear), DC high-pass
  on mics, stereo-mic channel choice, silence-rule thresholds (300 ms RMS, -70 dB), >2-channel and multi-stream
  input devices, IOProc/tap cleanup on rare start errors.
