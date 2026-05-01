import SwiftUI

enum LayoutMetrics {
    static let minimumWindowWidth: CGFloat = 900
    static let minimumWindowHeight: CGFloat = 620
    static let workspaceMaxWidth: CGFloat = 980
    static let compactPadding: CGFloat = 16
    static let regularPadding: CGFloat = 24
}

struct WorkspaceContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .frame(maxWidth: LayoutMetrics.workspaceMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LayoutMetrics.compactPadding)
            .padding(.vertical, LayoutMetrics.regularPadding)
        }
    }
}

struct WrappingHStack: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(for: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(for: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)

        for placement in result.placements {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func layout(for proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, placements: [Placement]) {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var placements: [Placement] = []
        var cursor = CGPoint.zero
        var rowHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let shouldWrap = cursor.x > 0 && cursor.x + size.width > maxWidth

            if shouldWrap {
                cursor.x = 0
                cursor.y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            placements.append(Placement(index: index, origin: cursor, size: size))
            measuredWidth = max(measuredWidth, cursor.x + size.width)
            cursor.x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        let width = proposal.width ?? measuredWidth
        return (CGSize(width: width, height: cursor.y + rowHeight), placements)
    }

    private struct Placement {
        let index: Int
        let origin: CGPoint
        let size: CGSize
    }
}

struct AdaptiveButtonRow<Content: View>: View {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        WrappingHStack(horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkspaceHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }
}

struct WorkspaceDropOverlay: View {
    let section: AppSection

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
            )
            .shadow(radius: 10, y: 4)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityIdentifier(AccessibilityID.workspaceDropOverlay)
    }

    private var title: String {
        switch section {
        case .transcribe:
            "Drop to queue transcription"
        case .trim:
            "Drop to open clip"
        case .download, .convert, .queue, .history:
            "Drop to queue"
        }
    }

    private var systemImage: String {
        switch section {
        case .transcribe:
            "text.bubble"
        case .trim:
            "scissors"
        case .download, .convert, .queue, .history:
            "tray.and.arrow.down"
        }
    }
}

struct StudioCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
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
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

struct MetadataSummaryCard: View {
    let metadata: MediaMetadata

    var body: some View {
        StudioCard {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    thumbnail
                    metadataDetails
                }

                VStack(alignment: .leading, spacing: 14) {
                    thumbnail
                    metadataDetails
                }
            }
        }
    }

    private var thumbnail: some View {
        thumbnailView
            .frame(width: 180, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var metadataDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(metadata.title)
                .font(.title3.weight(.semibold))
                .lineLimit(3)
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                pathDescription
                Spacer()
                chooseButton
            }

            VStack(alignment: .leading, spacing: 10) {
                pathDescription
                chooseButton
            }
        }
    }

    private var pathDescription: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var chooseButton: some View {
        Button("Choose") {
            action()
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

                        AdaptiveButtonRow {
                            Button("Preview") {
                                onPreview(artifact)
                            }

                            Button("Open") {
                                onOpen(artifact)
                            }

                            Button("Reveal") {
                                onReveal(artifact)
                            }
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
                    .fill(Color(nsColor: status.tint).opacity(0.15))
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
