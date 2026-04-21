import SwiftUI

enum DownloadAuthProfileSheetContext {
    case download
    case settings

    var title: String {
        switch self {
        case .download:
            "Download Authentication"
        case .settings:
            "Manage Download Authentication"
        }
    }
}

private enum DownloadAuthWizardStep: String, CaseIterable, Identifiable {
    case strategy
    case details
    case finish

    var id: Self { self }

    var title: String {
        switch self {
        case .strategy:
            "Strategy"
        case .details:
            "Details"
        case .finish:
            "Finish"
        }
    }
}

struct DownloadAuthProfileSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var appState: AppState
    let context: DownloadAuthProfileSheetContext

    @State private var step: DownloadAuthWizardStep = .strategy
    @State private var editingProfileID: UUID?
    @State private var draft: DownloadAuthProfileDraft

    init(appState: AppState, context: DownloadAuthProfileSheetContext, initialProfileID: UUID?) {
        self.appState = appState
        self.context = context
        _editingProfileID = State(initialValue: initialProfileID)
        _draft = State(initialValue: appState.authProfileDraft(for: initialProfileID))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Profile", selection: $editingProfileID) {
                        Text("New Profile")
                            .tag(UUID?.none)

                        ForEach(appState.authProfileStore.profiles) { profile in
                            Text(profile.name)
                                .tag(Optional(profile.id))
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.authSheetProfilePicker)
                    .onChange(of: editingProfileID) { _, newValue in
                        draft = appState.authProfileDraft(for: newValue)
                        step = .strategy
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Step")
                            .font(.subheadline.weight(.semibold))

                        HStack(spacing: 8) {
                            ForEach(DownloadAuthWizardStep.allCases) { wizardStep in
                                stepButton(for: wizardStep)
                            }
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.authSheetStepPicker)
                }

                Section(step.title) {
                    switch step {
                    case .strategy:
                        strategyStep
                    case .details:
                        detailsStep
                    case .finish:
                        finishStep
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(context.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                if editingProfileID != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete", role: .destructive) {
                            guard let editingProfileID else { return }
                            appState.deleteAuthProfile(editingProfileID)
                            dismiss()
                        }
                        .accessibilityIdentifier(AccessibilityID.authSheetDeleteButton)
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let profile = appState.saveAuthProfile(draft, selectForDownload: context == .download) else {
                            return
                        }

                        editingProfileID = profile.id
                        dismiss()
                    }
                    .accessibilityIdentifier(AccessibilityID.authSheetSaveButton)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 520)
    }

    private var strategyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Strategy", selection: $draft.strategyKind) {
                ForEach(DownloadAuthStrategyKind.allCases) { strategyKind in
                    Text(strategyKind.title).tag(strategyKind)
                }
            }
            .accessibilityIdentifier(AccessibilityID.authSheetStrategyPicker)

            Text(draft.strategyKind.detail)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var detailsStep: some View {
        switch draft.strategyKind {
        case .browser:
            VStack(alignment: .leading, spacing: 16) {
                Picker("Browser", selection: $draft.browser) {
                    ForEach(DownloadCookieBrowser.allCases) { browser in
                        Text(browser.title).tag(browser)
                    }
                }

                TextField("Browser profile (optional)", text: $draft.browserProfile)

                if draft.browser == .firefox {
                    TextField("Firefox container (optional)", text: $draft.browserContainer)
                }

                Text("Browser cookies stay in the browser. Media Getter only passes the selection to yt-dlp when you inspect or download.")
                    .foregroundStyle(.secondary)
            }

        case .cookieFile:
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cookie file")
                    Text(draft.selectedCookieFilePath.isEmpty ? "No file selected" : draft.selectedCookieFilePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button("Choose Cookie File…") {
                    let startURL: URL?
                    if let selectedCookieFileURL = draft.selectedCookieFileURL {
                        startURL = selectedCookieFileURL.deletingLastPathComponent()
                    } else if let managedCookieFilePath = draft.managedCookieFilePath {
                        startURL = URL(fileURLWithPath: managedCookieFilePath).deletingLastPathComponent()
                    } else {
                        startURL = nil
                    }

                    guard let url = FileHelpers.chooseCookieFile(startingAt: startURL) else { return }
                    draft.selectedCookieFilePath = url.path
                }

                Text("Choose a Netscape cookie export. The app copies it into its Application Support folder with restricted file permissions.")
                    .foregroundStyle(.secondary)
            }

        case .advancedHeaders:
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cookie header")
                    TextEditor(text: $draft.cookieHeader)
                        .frame(minHeight: 110)
                        .font(.system(.body, design: .monospaced))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                }

                TextField("User-Agent (optional)", text: $draft.userAgent)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Custom headers")
                        Spacer()
                        Button("Add Header") {
                            draft.customHeaders.append(DownloadHeaderField())
                        }
                    }

                    if draft.customHeaders.isEmpty {
                        Text("No custom headers yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($draft.customHeaders) { $header in
                            HStack {
                                TextField("Header name", text: $header.name)
                                TextField("Header value", text: $header.value)

                                Button("Remove") {
                                    draft.customHeaders.removeAll { $0.id == header.id }
                                }
                            }
                        }
                    }
                }

                Text("These values are stored securely in Keychain, not in plain app defaults.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Profile name", text: $draft.name)

            Toggle("Make this the default auth profile", isOn: $draft.markAsDefault)

            VStack(alignment: .leading, spacing: 6) {
                Text("Summary")
                    .font(.headline)
                Text(summaryText)
                    .foregroundStyle(.secondary)
            }

            Button("Test With Current URL") {
                Task {
                    await appState.testDownloadAuthProfile(draft)
                }
            }
            .disabled(appState.downloadDraft.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if appState.downloadDraft.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Paste a media URL in the Download workspace to test this profile before saving.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summaryText: String {
        switch draft.strategyKind {
        case .browser:
            return BrowserDownloadAuthConfiguration(
                browser: draft.browser,
                profile: draft.trimmedBrowserProfile,
                container: draft.browser == .firefox ? draft.trimmedBrowserContainer : nil
            ).summary
        case .cookieFile:
            return draft.selectedCookieFilePath.isEmpty ? "No cookie file selected yet." : draft.selectedCookieFilePath
        case .advancedHeaders:
            let customHeaderCount = draft.normalizedCustomHeaders.count
            var parts = ["Cookie header"]

            if draft.trimmedUserAgent != nil {
                parts.append("User-Agent")
            }

            if customHeaderCount > 0 {
                parts.append("\(customHeaderCount) custom header\(customHeaderCount == 1 ? "" : "s")")
            }

            return parts.joined(separator: " • ")
        }
    }

    @ViewBuilder
    private func stepButton(for wizardStep: DownloadAuthWizardStep) -> some View {
        if wizardStep == step {
            Button(wizardStep.title) {
                step = wizardStep
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(wizardStep.title) {
                step = wizardStep
            }
            .buttonStyle(.bordered)
        }
    }
}
