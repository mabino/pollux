import SwiftUI

/// Standalone window that surfaces extraction / URL errors (e.g. "Pollux couldn't find a playable
/// stream") separately from the main window. Opened when `model.lastError` becomes non-nil and
/// auto-dismisses once the error is cleared.
struct ErrorWindowView: View {
    @EnvironmentObject private var model: PolluxAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = model.lastError {
                UserFacingErrorCard(error: error)

                HStack {
                    Spacer()
                    Button("Dismiss") {
                        model.lastError = nil
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                ContentUnavailableView(
                    "No Errors",
                    systemImage: "checkmark.circle",
                    description: Text("Pollux hasn't reported any problems.")
                )
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 200)
        .onChange(of: model.lastError) { _, newValue in
            if newValue == nil {
                dismiss()
            }
        }
    }
}
