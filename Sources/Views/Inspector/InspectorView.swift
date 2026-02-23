import SwiftUI
import Photos

struct InspectorView: View {
    @ObservedObject var selection: SelectionModel
    let onStartCompression: () -> Void
    let onScanDuplicates: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Actions
                actionsSection

                Divider()

                // Smart Filters
                filtersSection
            }
            .padding(16)
        }
        .navigationTitle("Inspector")
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Actions")
                .font(.headline)

            Button {
                onStartCompression()
            } label: {
                Label("Start Compression", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!selection.hasSelection)

            Button {
                onScanDuplicates()
            } label: {
                Label("Scan for Duplicates", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!selection.hasSelection)

            if !selection.hasSelection {
                Text("Select albums or photos to enable actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Filters

    private var filtersSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filters")
                .font(.headline)

            // Media Type
            VStack(alignment: .leading, spacing: 4) {
                Text("Media Type")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Media Type", selection: $selection.filterMediaType) {
                    ForEach(FilterMediaType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // Format
            VStack(alignment: .leading, spacing: 4) {
                Text("Format")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Format", selection: $selection.filterFormat) {
                    ForEach(FilterFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // Min File Size
            VStack(alignment: .leading, spacing: 4) {
                Text("Minimum File Size")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    let binding = Binding<String>(
                        get: { selection.filterMinSizeMB.map { String(format: "%.0f", $0) } ?? "" },
                        set: { selection.filterMinSizeMB = Double($0) }
                    )
                    TextField("Any", text: binding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("MB")
                        .foregroundStyle(.secondary)
                }
            }

            // Camera Model
            VStack(alignment: .leading, spacing: 4) {
                Text("Camera Make / Model")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("e.g. iPhone, Canon, Sony", text: $selection.filterCameraModel)
                    .textFieldStyle(.roundedBorder)
                Text("Applies to photos only (reads EXIF).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Date Range
            VStack(alignment: .leading, spacing: 4) {
                Text("Date Range")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                DateRangePickerView(range: $selection.filterDateRange)
            }

            // Reset Filters
            Button("Reset Filters") {
                selection.filterMediaType = .all
                selection.filterFormat = .all
                selection.filterMinSizeMB = nil
                selection.filterMinPixelWidth = nil
                selection.filterDateRange = nil
                selection.filterCameraModel = ""
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Date Range Picker

struct DateRangePickerView: View {
    @Binding var range: ClosedRange<Date>?

    @State private var startDate: Date = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var endDate: Date = Date()
    @State private var isEnabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Limit by date", isOn: $isEnabled)
                .font(.caption)
                .onChange(of: isEnabled) { enabled in
                    range = enabled ? startDate...endDate : nil
                }
            if isEnabled {
                DatePicker("From", selection: $startDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .font(.caption)
                    .onChange(of: startDate) { _ in range = startDate...endDate }
                DatePicker("To", selection: $endDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .font(.caption)
                    .onChange(of: endDate) { _ in range = startDate...endDate }
            }
        }
    }
}
