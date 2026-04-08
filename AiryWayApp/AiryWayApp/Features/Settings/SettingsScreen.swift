import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        localModelCard
                        appearanceCard
                        generationCard

                        if let error = settingsStore.lastErrorMessage, !error.isEmpty {
                            errorCard(error)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var backgroundGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.10, blue: 0.14),
                    Color(red: 0.10, green: 0.13, blue: 0.19),
                    Color(red: 0.06, green: 0.07, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.97, blue: 1.0),
                Color(red: 0.92, green: 0.95, blue: 0.99),
                Color.white
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var localModelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local model")
                .font(.headline)

            infoRow("Engine", settingsStore.selectedEngineName)
            infoRow("State", settingsStore.modelState.label)
            infoRow("Selected", settingsStore.selectedModelName)
            infoRow("Active backend", settingsStore.activeComputeBackendLabel)

            VStack(alignment: .leading, spacing: 6) {
                Text("Compute")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Compute", selection: $settingsStore.computePreference) {
                    ForEach(LocalComputePreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
            }

            if settingsStore.isGPUOffloadSupported {
                Text("Auto usa il backend piu' stabile per il dispositivo. Puoi forzare CPU o GPU (Metal).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("GPU offload non disponibile su questo target: viene usata CPU.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsModelCapabilitiesRow(capabilities: settingsStore.selectedModelCapabilities)

            HStack(spacing: 10) {
                Button("Load") {
                    Task { await settingsStore.loadSelectedModel() }
                }
                .buttonStyle(.borderedProminent)

                Button("Unload") {
                    Task { await settingsStore.unloadModel() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceCard)
    }

    private var generationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generation")
                .font(.headline)

            Stepper(
                "Max context chars: \(settingsStore.maxContextCharacters)",
                value: $settingsStore.maxContextCharacters,
                in: 1_000...20_000,
                step: 500
            )
            Text("Output length is managed by the loaded model/runtime.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceCard)
    }

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance")
                .font(.headline)

            Picker("Appearance", selection: $settingsStore.appAppearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            .pickerStyle(.segmented)

            Text("System follows the iPhone appearance setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceCard)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last error")
                .font(.headline)
            Text(message)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.red.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.28))
                )
        )
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private var surfaceCard: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.34))
            )
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }
}

private struct SettingsModelCapabilitiesRow: View {
    let capabilities: ModelCapabilities

    var body: some View {
        HStack(spacing: 10) {
            capabilityTag(
                title: "File",
                icon: "doc.text",
                supported: capabilities.supportsFileInput
            )
            capabilityTag(
                title: "Image",
                icon: "photo",
                supported: capabilities.supportsImageInput
            )
            capabilityTag(
                title: "Audio",
                icon: "waveform",
                supported: capabilities.supportsAudioInput
            )
        }
    }

    @ViewBuilder
    private func capabilityTag(title: String, icon: String, supported: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(supported ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
        )
        .foregroundStyle(supported ? Color.green : Color.secondary)
    }
}
