# Third-Party Notices

This app is designed to bundle and orchestrate third-party command-line tools,
including `yt-dlp`, `deno`, `ffmpeg`, `ffprobe`, and `whisper.cpp`.

Before shipping a release build:

- confirm the exact binaries being redistributed
- include the relevant upstream licenses and notices for yt-dlp, deno, ffmpeg, ffprobe, x264, LAME, whisper.cpp, and any bundled Whisper model assets
- verify redistribution terms for the selected `ffmpeg` build
- verify redistribution terms for the selected Whisper model files and generated Core ML encoder assets
- confirm the notarized app signs nested binaries correctly
- document the Apple Silicon-only support policy for distributed builds
