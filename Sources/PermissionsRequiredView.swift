import SwiftUI

struct PermissionsRequiredView: View {
    @EnvironmentObject private var model: PolluxAppModel
    @Environment(\.openSettings) private var openSettings

    let issue: PolluxPermissionIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "hand.raised.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.title)
                        .font(.largeTitle.bold())

                    Text(issue.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GroupBox("What to do") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(issue.instructions.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let permissionActionMessage = model.permissionActionMessage {
                NoticeCard(text: permissionActionMessage)
            }

            HStack(spacing: 12) {
                Button(model.isCheckingPermissions ? "Checking…" : "Request Access") {
                    Task {
                        await model.requestAccess(for: issue)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isCheckingPermissions)

                Button("Open Privacy & Security") {
                    model.openSystemSettings(for: issue)
                }

                Button(model.isCheckingPermissions ? "Checking…" : "I Granted Access") {
                    Task {
                        await model.confirmGrantedAccess()
                    }
                }
                .disabled(model.isCheckingPermissions)

                Button("Open Pollux Settings…") {
                    openSettings()
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 420)
        .task {
            await model.runStartupPermissionCheckIfNeeded()
        }
    }
}
