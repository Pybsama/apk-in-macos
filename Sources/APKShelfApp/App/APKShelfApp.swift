import APKRuntime
import SwiftUI

@main
struct APKShelfApp: App {
    @NSApplicationDelegateAdaptor(ShelfAppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            ShelfCommands(delegate: delegate)
        }
    }
}

/// Menu bar commands, localized and switchable alongside the in-window language picker.
struct ShelfCommands: Commands {
    let delegate: ShelfAppDelegate

    var body: some Commands {
        let settings = LanguageSettings.shared

        CommandGroup(replacing: .newItem) {
            Button(tr("显示应用书架", "Show App Shelf")) {
                delegate.showShelfWindow()
            }
            .keyboardShortcut("1", modifiers: .command)

            Button(tr("安装 APK…", "Install APK…")) {
                delegate.showShelfWindow()
                delegate.store.pickAndInstallAPKs()
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button(tr("打开 Android 主屏幕", "Open Android Home Screen")) {
                Task { await delegate.store.openMainScreen() }
            }
            .keyboardShortcut("0", modifiers: [.command, .shift])

            Button(tr("打开独立快捷方式目录", "Open Shortcuts Folder")) {
                delegate.store.openShortcutsFolder()
            }
        }

        CommandMenu(tr("语言", "Language")) {
            Picker(tr("界面语言", "Interface Language"), selection: Binding(
                get: { settings.selection },
                set: { settings.selection = $0 }
            )) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.pickerTitle).tag(lang)
                }
            }
            .pickerStyle(.inline)
        }
    }
}
