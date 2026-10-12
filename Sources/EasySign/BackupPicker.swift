import SwiftUI
import EasySignCore

struct BackupPicker: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var currentSignatureOnly = true

    private var visibleBackups: [BackupRecord] {
        guard currentSignatureOnly, let selected = model.selected else { return model.backups }
        return model.backups.filter { $0.originalPath == selected.url.path }
    }
    private var selectedBackup: BackupRecord? { visibleBackups.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Version history").font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                    Text("Choose a backup to restore.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.borderless).accessibilityLabel("Close version history")
            }.padding(24)
            HStack {
                Text("\(visibleBackups.count) saved \(visibleBackups.count == 1 ? "version" : "versions")").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if model.selected != nil {
                    Picker("Show backups", selection: $currentSignatureOnly) { Text("This signature").tag(true); Text("All signatures").tag(false) }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 230)
                }
            }.padding(.horizontal, 24).padding(.bottom, 13)
            List(visibleBackups, selection: $selectedID) { backup in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 17)).foregroundStyle(.secondary).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(backup.date.formatted(date: .abbreviated, time: .standard)).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(backup.reason).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text(backup.originalPath).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .help(backup.originalPath)
                        Label(backup.metadata.isLocked ? "Originally locked" : "Originally unlocked", systemImage: backup.metadata.isLocked ? "lock" : "lock.open")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }.padding(.vertical, 7).tag(backup.id)
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .overlay {
                if visibleBackups.isEmpty {
                    ContentUnavailableView("No versions yet", systemImage: "clock.arrow.circlepath", description: Text("Apply your first change to create a verified backup automatically."))
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 15) {
                Label(model.mailRunning ? "Close Apple Mail before restoring." : "Your current file is backed up before restoring. Nothing is deleted.", systemImage: model.mailRunning ? "envelope.badge" : "checkmark.shield")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button("Show Backup Folder") { NSWorkspace.shared.open(model.backupStore.directory) }.buttonStyle(.borderless)
                    Spacer()
                    if model.mailRunning { Button("Quit Mail", action: model.quitMail) }
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Restore Version…") { if let selectedBackup { Task { await model.restore(selectedBackup) } } }
                        .buttonStyle(.borderedProminent).tint(UtilityStyle.accent).keyboardShortcut(.defaultAction).disabled(selectedBackup == nil || model.mailRunning || model.busy)
                }.controlSize(.regular)
            }.padding(24)
        }.onChange(of: currentSignatureOnly) { _, _ in selectedID = nil }
        .frame(width: 690, height: 510).tint(UtilityStyle.accent)
    }
}
