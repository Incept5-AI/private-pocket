import SwiftUI

/// Settings → USB drive: the only way to delete recordings from a Pocket.
struct USBView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var devices: DeviceStore
    @EnvironmentObject var drive: USBDrive
    @EnvironmentObject var library: Library
    @State private var picking = false
    @State private var confirm: [DriveFile] = []

    var body: some View {
        List {
            if let d = devices.selected {
                if drive.root == nil {
                    webSyncSection
                    instructions
                } else {
                    driveSection(d)
                }
            } else {
                ContentUnavailableView("No devices", systemImage: "externaldrive", description: Text("Add a device in Settings first."))
            }
        }
        .navigationTitle("USB drive")
        .toolbar {
            if drive.root != nil {
                Button("Close") { drive.close() }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { drive.open(url) }
        }
        .alert("USB", isPresented: Binding(get: { drive.error != nil }, set: { if !$0 { drive.error = nil } })) {
            Button("OK") {}
        } message: { Text(drive.error ?? "") }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = [] } }),
                            titleVisibility: .visible) {
            Button("Delete from Pocket", role: .destructive) { drive.delete(confirm); confirm = [] }
        } message: { Text(confirmMessage) }
    }

    private var webSyncSection: some View {
        Section {
            Toggle("Web Sync", isOn: Binding(get: { link.status.webSync ?? false },
                                             set: { on in Task { await model.setWebSync(on) } }))
                .disabled(link.connectedDeviceID == nil)
        } footer: {
            Text(link.connectedDeviceID == nil
                 ? "Connect to the Pocket (Recorder tab) to change this."
                 : "Lets the Pocket appear as a USB drive. Takes effect the next time the cable is plugged in. Turn it off again when you are done.")
        }
    }

    private var instructions: some View {
        Section {
            Label("Turn on Web Sync above.", systemImage: "1.circle")
            Label("Plug the Pocket into this iPhone with a USB-C data cable (unplug and re-plug if it was already in).", systemImage: "2.circle")
            Label("Tap Open drive and choose the Pocket drive in Files.", systemImage: "3.circle")
            Button { picking = true } label: { Label("Open drive", systemImage: "externaldrive.badge.plus") }
        } footer: {
            Text("Bluetooth cannot delete files; only the USB drive can. Files the phone already holds a copy of are marked as backed up. The Pocket cannot record while it is mounted.")
        }
    }

    @ViewBuilder
    private func driveSection(_ d: DeviceConfig) -> some View {
        let backed = drive.files.filter { model.isBackedUp($0, device: d) }
        let missing = drive.files.filter { !model.isBackedUp($0, device: d) }
        Section {
            LabeledContent("Recordings on drive", value: "\(drive.files.count)")
            LabeledContent("Backed up on this phone", value: "\(backed.count)")
            if !missing.isEmpty {
                Button { model.importFromDrive(missing, device: d) } label: {
                    Label("Copy \(missing.count) missing to this phone", systemImage: "square.and.arrow.down")
                }
            }
            Button(role: .destructive) { confirm = backed } label: {
                Label("Delete \(backed.count) backed-up from Pocket", systemImage: "trash")
            }
            .disabled(backed.isEmpty)
        } header: { Text("Matching against \(d.name)") }

        Section("Files") {
            ForEach(drive.files) { f in
                HStack {
                    VStack(alignment: .leading) {
                        Text(PocketTime.parse(f.name)?.formatted(date: .abbreviated, time: .shortened) ?? f.name)
                        Text("\(f.day)/\(f.name).mp3 · \(f.size.formatted(.byteCount(style: .file)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: model.isBackedUp(f, device: d) ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(model.isBackedUp(f, device: d) ? .green : .orange)
                        .accessibilityLabel(model.isBackedUp(f, device: d) ? "Backed up" : "Not backed up")
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { confirm = [f] }
                }
            }
        }
        Section {
            Button("Rescan drive") { drive.refresh() }
        } footer: {
            Text("When you are done: tap Close, unplug the cable, then turn Web Sync off here.")
        }
    }

    private var confirmTitle: String { confirm.count == 1 ? "Delete this recording from the Pocket?" : "Delete \(confirm.count) recordings from the Pocket?" }

    private var confirmMessage: String {
        guard let d = devices.selected else { return "" }
        let unsafe = confirm.filter { !model.isBackedUp($0, device: d) }.count
        return unsafe == 0 ? "The phone holds a copy of each. This cannot be undone on the Pocket."
            : "\(unsafe) of these are NOT on this phone and will be lost."
    }
}
