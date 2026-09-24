# Spike: chapter format in m4a

Date: 2026-09-24. Test files: 30 s AAC, chapters Start 0:00, Mark 1 0:10, "про деньги" 0:20.

- Method (a), Apple frameworks only: AVAssetReader passthrough -> AVAssetWriter .m4a with a `tx3g` text track
  associated as `.chapterList` (`tref/chap`, no Nero `chpl`). Audio packets identical, PCM bit-exact, `iTunSMPB`
  kept. The QuickTime `text` format fails in .m4a (-12715).
- Method (b), ffmpeg: `tref/chap` + QuickTime text track + Nero `chpl`; replaces `iTunSMPB` with `elst`.
- The user's player check of `chapters-apple.m4a`: chapters shown in Preview (Quick Look), QuickTime Player and
  VLC. That is enough for the user. iPhone Files and IINA were not checked.
- Decision: method (a).
