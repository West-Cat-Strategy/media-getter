# MediaGetter Agent Instructions

**Project**: Native macOS app for downloading, converting, trimming, and transcribing media with bundled CLI tooling.

## Quick Start

### Build & Run
```bash
# Generate Xcode project and build/run the app
script/build_and_run.sh run

# Build in debug mode
script/build_and_run.sh

# Debug with lldb
script/build_and_run.sh debug

# Stream live logs
script/build_and_run.sh logs
```

### Important Prerequisites
- `xcodegen` must be installed (`brew install xcodegen`)
- `xcodebuild` must be available (Xcode)
- If `Vendor/Models/ggml-base.en-encoder.mlmodelc` is missing, run: `script/vendor_media_tools.sh`

### Project Structure
```
Sources/MediaGetter/
  App/              # Main app entry, delegates, app commands
  Features/         # UI screens organized by function (Download, Convert, Trim, etc.)
  Models/           # Data structures and view models
  Services/         # Business logic (DownloadService, TranscodeService, etc.)
  Stores/           # State persistence and management
  Support/          # Helpers, formatters, accessibility IDs
```

## Architecture & Patterns

### State Management
- **AppState** (`@MainActor @Observable`): Single source of truth for app state
  - Contains stores: PreferencesStore, HistoryStore, QueueStore, AuthProfileStore
  - Contains service instances (all @ObservationIgnored)
  - Manages UI sections, drafts (DownloadDraft, ConvertDraft, etc.), alerts

### Services (Thread-Safe Sendable)
Services encapsulate business logic and CLI tool execution:
- **DownloadProbeService**: Probe URLs with yt-dlp/ffprobe to extract metadata
- **DownloadService**: Download media using yt-dlp
- **TranscodeService**: Convert media using ffmpeg
- **TrimService**: Trim media with ffmpeg
- **TranscriptionService**: Transcribe audio using whisper-cli
- **ThumbnailService**: Extract thumbnails from video
- **XMediaService**: Handle gallery-dl operations
- **ToolchainManager**: Ensure vendored tools exist and report issues

### ProcessRunner
- Abstracts execution of CLI tools via Foundation's `Process`
- Returns `ProcessResult` with exit code, stdout, stderr, and combined output
- Supports environment variables and working directories
- Collects output asynchronously via OutputCollector actor

### UI Architecture (SwiftUI + MVVM)
- **RootSplitView**: Main split navigation between features
- **Feature Views**: Download, Convert, Trim, Transcribe, History, Queue, XMedia
- Uses SwiftUI's state binding with @State, @Binding
- Accessibility IDs defined in [Support/AccessibilityID.swift](Support/AccessibilityID.swift) for testing

### Tool Execution Pattern
```swift
// Services manage ProcessRunner execution
let result = await processRunner.run(ProcessCommand(
    executableURL: URL(fileURLWithPath: toolPath),
    arguments: [...],
    environment: [...]
))

// Parse output or check exit code
if result.exitCode != 0 {
    throw ProcessRunnerError.nonZeroExit(result.exitCode, result.stderr)
}
```

## Code Conventions

### Swift & SwiftUI
- Swift 6.0 with strict concurrency
- Use `@MainActor` for UI state mutations
- Services are `@unchecked Sendable` where needed for CLI execution
- Prefer `@Observable` over `@ObservedObject` (modern pattern)
- Error handling: custom `Error` enums with `LocalizedError` conformance

### File Organization
- One main type per file
- Related types grouped in same file (e.g., data structures for a service)
- Extensions for protocol conformance at end of file

### Naming
- View files: `<Feature>WorkspaceView.swift` (e.g., DownloadWorkspaceView)
- Service files: `<Function>Service.swift` (e.g., TranscodeService)
- Model files: `<Domain>Models.swift` (e.g., DownloadAuthModels)

## Common Tasks

### Adding a New Feature Workspace
1. Create `Sources/MediaGetter/Features/<Feature>/<Feature>WorkspaceView.swift`
2. Add corresponding Model and Store files if needed
3. Add navigation to RootSplitView
4. Create appropriate Services for business logic

### Adding CLI Tool Support
1. Add tool to `Vendor/Tools/` directory
2. Create a Service class inheriting ToolchainManager patterns
3. Use ProcessRunner for execution
4. Parse tool output and handle errors appropriately

### Debugging Tool Issues
- Check [AppState.swift](Sources/MediaGetter/Stores/AppState.swift) for `toolVersions` and `toolIssues` properties
- These are populated during `bootstrap()` and displayed in the UI
- Use `ToolchainManager` to verify tool availability

## Vendored Assets

### Tools (in Vendor/Tools/)
- `yt-dlp`: Video/audio download
- `ffmpeg` & `ffprobe`: Media conversion and probing
- `gallery-dl`: Gallery/image download
- `whisper-cli`: Transcription
- `deno`: Runtime support

### Models (in Vendor/Models/)
- `ggml-base.en-encoder.mlmodelc`: Whisper speech recognition model (large, may need to be vendored separately)

If assets are missing, run:
```bash
script/vendor_media_tools.sh  # Tools and models
script/vendor_whisper_assets.sh  # Whisper models only
```

## Release & Auto-Update

See [docs/auto-update-release.md](docs/auto-update-release.md) for:
- Creating release bundles
- Sparkle appcast generation
- Notarization process

## Key Files to Know
- [Sources/MediaGetter/Stores/AppState.swift](Sources/MediaGetter/Stores/AppState.swift) — Central state container
- [Sources/MediaGetter/Services/ProcessRunner.swift](Sources/MediaGetter/Services/ProcessRunner.swift) — CLI execution abstraction
- [Sources/MediaGetter/Services/ToolchainManager.swift](Sources/MediaGetter/Services/ToolchainManager.swift) — Tool validation
- [Sources/MediaGetter/App/MediaGetterApp.swift](Sources/MediaGetter/App/MediaGetterApp.swift) — App entry point
- [project.yml](project.yml) — Xcode project specification (XcodeGen)
- [script/build_and_run.sh](script/build_and_run.sh) — Build orchestration

## Testing

Tests are in:
- [Tests/MediaGetterTests/](Tests/MediaGetterTests/) — Unit tests
- [Tests/MediaGetterUITests/](Tests/MediaGetterUITests/) — UI tests

Build and run via Xcode scheme "MediaGetter" or `xcodebuild test`.

## Important Notes

- **Swift 6.0 strict concurrency**: Many types use `@unchecked Sendable` because CLI tools require `Process` which isn't Sendable by default
- **MainActor**: AppState mutations must happen on the main thread; services offload to background actors/tasks
- **Process cleanup**: The build script kills existing MediaGetter processes before building to avoid locking
- **Model files**: `ggml-base.en-encoder.mlmodelc` is not always tracked in Git due to size; the build will report if missing
