import SwiftUI

struct ToolbarView: View {
    private static let keyboardShortcutMinimumWidth: CGFloat = 300

    @EnvironmentObject var remindersData: RemindersData
    let availableWidth: CGFloat

    init(availableWidth: CGFloat = .infinity) {
        self.availableWidth = availableWidth
    }

    var body: some View {
        HStack(spacing: 4) {
            CreateReminderButton(
                showsKeyboardShortcut: availableWidth == 0 || availableWidth >= Self.keyboardShortcutMinimumWidth
            )
                .disabled(remindersData.availableCalendars.isEmpty)

            Spacer()
            
            SearchRemindersButton()
                .disabled(remindersData.availableCalendars.isEmpty)

            RecentRemindersButton()
                .disabled(remindersData.availableCalendars.isEmpty)

            FilterReminderListButton()
                .disabled(remindersData.availableCalendars.isEmpty)

            UpdateAvailableButton()

            MainPresentationButton()

            OpenSettingButton()
        }
        .padding(.top, 10)
        .padding(.trailing, 10)
        .padding(.leading, 14)
        .padding(.bottom, 6)
    }
}

private struct MainPresentationButton: View {
    @EnvironmentObject var presentationCoordinator: MainPresentationCoordinator

    var body: some View {
        Button {
            if presentationCoordinator.isDetached {
                AppDelegate.shared.reattachMainWindow()
            } else {
                AppDelegate.shared.detachMainWindow()
            }
        } label: {
            ToolbarButtonLabel {
                Image(systemName: presentationCoordinator.isDetached ? "menubar.arrow.up.rectangle" : "macwindow")
            }
        }
        .modifier(ToolbarButtonModifier())
        .help(rmbLocalized(presentationCoordinator.isDetached ? .reattachWindowButton : .detachWindowButton))
        .accessibilityLabel(rmbLocalized(
            presentationCoordinator.isDetached ? .reattachWindowButton : .detachWindowButton
        ))
    }
}

#Preview {
    ToolbarView()
        .environmentObject(RemindersData())
        .environmentObject(MainPresentationCoordinator(popover: NSPopover()))
}
