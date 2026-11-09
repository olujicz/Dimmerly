//
//  MenuBarUpdateRow.swift
//  Dimmerly
//
//  The gentle update reminder in the menu bar panel (direct-download build only). When a
//  background check finds an update while Dimmerly isn't in focus, Sparkle doesn't open a
//  window over the user's work; this row appears instead, until the user responds to the
//  update or Sparkle's update session ends.
//

#if !APPSTORE
    import SwiftUI

    struct MenuBarUpdateRow: View {
        let updater: UpdaterController
        @Environment(\.closeMenuBarPanel) private var closeMenuBarPanel
        @State private var isHovered = false

        /// Whether the panel shows the row, and the divider under it.
        static func isVisible(for updater: UpdaterController?) -> Bool {
            updater?.isUpdateReminderPending == true
        }

        var body: some View {
            HStack(spacing: 0) {
                Button {
                    closeMenuBarPanel()
                    updater.checkForUpdates()
                } label: {
                    FooterLabel("Update Available…", icon: "arrow.down.circle", isHovered: isHovered)
                }
                .buttonStyle(.borderless)
                .help("Install the new version of Dimmerly")
                .onHover { isHovered = $0 }

                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.tint)
        }
    }
#endif
