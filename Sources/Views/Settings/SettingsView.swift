import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            QualitySettingsTab(settings: settings)
                .tabItem { Label("Quality", systemImage: "slider.horizontal.3") }

            AlbumSettingsTab(settings: settings)
                .tabItem { Label("Albums", systemImage: "rectangle.stack") }
        }
        #if os(macOS)
        .frame(width: 460, height: 380)
        #endif
    }
}

// MARK: - Quality Tab

struct QualitySettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Photos (→ HEIC)") {
                Picker("Quality", selection: $settings.photoQualityMode) {
                    ForEach(QualityMode.allCases) { mode in
                        VStack(alignment: .leading) {
                            Text(mode.displayName)
                        }.tag(mode)
                    }
                }
                #if os(macOS)
                .pickerStyle(.radioGroup)
                #else
                .pickerStyle(.inline)
                #endif

                if settings.photoQualityMode == .custom {
                    HStack {
                        Slider(value: $settings.photoCustomQuality, in: 0.3...1.0, step: 0.05)
                        Text("\(Int(settings.photoCustomQuality * 100))%")
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                }
                Text(settings.photoQualityMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Videos (→ HEVC)") {
                Picker("Quality", selection: $settings.videoQualityMode) {
                    ForEach(QualityMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                #if os(macOS)
                .pickerStyle(.radioGroup)
                #else
                .pickerStyle(.inline)
                #endif

                if settings.videoQualityMode == .custom {
                    HStack {
                        Slider(value: $settings.videoCustomBitrateMbps, in: 1...50, step: 0.5)
                        Text("\(settings.videoCustomBitrateMbps, specifier: "%.1f") Mbps")
                            .monospacedDigit()
                            .frame(width: 60)
                    }
                }
            }

            Section("Resolution") {
                Picker("Cap", selection: $settings.resolutionCap) {
                    ForEach(ResolutionCap.allCases) { cap in
                        Text(cap.displayName).tag(cap)
                    }
                }
                #if os(macOS)
                .pickerStyle(.radioGroup)
                #else
                .pickerStyle(.inline)
                #endif
            }

            Section("Skip Rules") {
                Toggle("Skip photos already in HEIC", isOn: $settings.skipAlreadyHEIC)
                Toggle("Skip videos already in HEVC", isOn: $settings.skipAlreadyHEVC)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Albums Tab

struct AlbumSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Album Names") {
                LabeledContent("Compressed items:") {
                    TextField("Album name", text: $settings.compressedAlbumName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Originals:") {
                    TextField("Album name", text: $settings.originalsAlbumName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Duplicates:") {
                    TextField("Album name", text: $settings.duplicatesAlbumName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Failed:") {
                    TextField("Album name", text: $settings.failedAlbumName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section {
                Text("These albums are created in Photos.app when you first run a job. Changing the name here will cause a new album to be created on the next run — the old one will remain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
