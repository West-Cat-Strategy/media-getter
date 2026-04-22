import SwiftUI

// MARK: - Button Styles

struct InteractiveButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : (isHovering ? 0.95 : 1.0))
            .scaleEffect(configuration.isPressed ? 0.97 : (isHovering ? 1.02 : 1.0))
            .brightness(isHovering ? 0.05 : 0)
            .animation(.studioSpring, value: isHovering)
            .animation(.studioFast, value: configuration.isPressed)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

struct StudioInputModifier: ViewModifier {
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.studioSurface.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isFocused ? Color.accentColor : (isHovering ? Color.studioBorderHover : Color.studioBorder), lineWidth: 1.5)
            )
            .animation(.studioFast, value: isHovering)
            .animation(.studioFast, value: isFocused)
            .onHover { hovering in
                isHovering = hovering
            }
            .focused($isFocused)
    }
}

extension View {
    func studioInputStyle() -> some View {
        self.modifier(StudioInputModifier())
    }
}

struct StudioToggleStyle: ToggleStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Rectangle()
                .fill(configuration.isOn ? Color.accentColor : Color.secondary.opacity(0.3))
                .frame(width: 44, height: 24)
                .overlay(
                    Circle()
                        .fill(Color.white)
                        .padding(2)
                        .offset(x: configuration.isOn ? 10 : -10)
                )
                .cornerRadius(12)
                .onTapGesture {
                    withAnimation(.studioSpring) {
                        configuration.isOn.toggle()
                    }
                }
                .scaleEffect(isHovering ? 1.05 : 1.0)
                .animation(.studioSpring, value: isHovering)
                .onHover { hovering in
                    isHovering = hovering
                }
        }
    }
}

struct SidebarButtonStyle: ButtonStyle {
    let isSelected: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.12) : (isHovering ? Color.white.opacity(0.06) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.18) : (isHovering ? Color.white.opacity(0.1) : Color.white.opacity(0.05)),
                        lineWidth: 1
                    )
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .animation(.studioSpring, value: isHovering)
            .animation(.studioFast, value: configuration.isPressed)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

struct WorkspaceHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Workspace")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(title)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }
}

struct StudioCard<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.studioSurface.opacity(0.96), Color.studioSurface.opacity(0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isHovering ? Color.white.opacity(0.15) : Color.white.opacity(0.09), lineWidth: 1)
        )
        .shadow(color: .black.opacity(isHovering ? 0.25 : 0.16), radius: isHovering ? 24 : 18, y: isHovering ? 12 : 10)
        .scaleEffect(isHovering ? 1.005 : 1.0)
        .animation(.studioSpring, value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

struct PresetTile: View {
    let preset: OutputPresetID
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: preset.systemImage)
                    .font(.title2)
                Text(preset.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(preset.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.06), lineWidth: 1.5)
            )
        }
        .buttonStyle(InteractiveButtonStyle())
    }
}

struct MetadataSummaryCard: View {
    let metadata: MediaMetadata

    var body: some View {
        StudioCard {
            HStack(alignment: .top, spacing: 18) {
                thumbnailView
                    .frame(width: 180, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    Text(metadata.title)
                        .font(.title3.weight(.semibold))
                    labeledValue("Duration", Formatters.duration(metadata.duration))
                    labeledValue("Container", metadata.container ?? "Unknown")
                    labeledValue("Video", metadata.videoCodec ?? "Unknown")
                    labeledValue("Audio", metadata.audioCodec ?? "Unknown")
                    if let extractor = metadata.extractor {
                        labeledValue("Extractor", extractor)
                    }
                    if let dimensions = metadata.dimensionsDescription {
                        labeledValue("Dimensions", dimensions)
                    }
                    labeledValue("Size", Formatters.bytes(metadata.fileSize))
                }
            }
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnailURL = metadata.thumbnailURL {
            AsyncImage(url: thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholderThumbnail
                }
            }
        } else {
            placeholderThumbnail
        }
    }

    private var placeholderThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            Image(systemName: "film.stack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .font(.subheadline)
    }
}

struct PathPickerRow: View {
    let title: String
    let path: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button("Choose") {
                action()
            }
            .buttonStyle(InteractiveButtonStyle())
        }
    }
}

struct SubtitleArtifactSection: View {
    let artifacts: [JobArtifact]
    let onPreview: (JobArtifact) -> Void
    let onOpen: (JobArtifact) -> Void
    let onReveal: (JobArtifact) -> Void

    var body: some View {
        if !artifacts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Subtitle files")
                    .font(.subheadline.weight(.semibold))

                ForEach(artifacts) { artifact in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(artifact.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Preview") {
                                onPreview(artifact)
                            }
                            .buttonStyle(InteractiveButtonStyle())

                            Button("Open") {
                                onOpen(artifact)
                            }
                            .buttonStyle(InteractiveButtonStyle())

                            Button("Reveal") {
                                onReveal(artifact)
                            }
                            .buttonStyle(InteractiveButtonStyle())
                        }
                    }
                }
            }
        }
    }
}

struct StatusBadge: View {
    let status: JobStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color(nsColor: status.tint).opacity(0.18))
            )
            .foregroundStyle(Color(nsColor: status.tint))
    }
}

struct TranscriptPreviewCard: View {
    let title: String
    let transcript: String
    var path: String?

    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)

                if let path {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(transcript)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}
