import ShelfKit
import SwiftUI
import WineRuntime

@main
struct EXEShelfApp: App {
    @NSApplicationDelegateAdaptor(EXEShelfAppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            EXEShelfCommands(delegate: delegate)
        }
    }
}

struct EXEShelfCommands: Commands {
    let delegate: EXEShelfAppDelegate

    var body: some Commands {
        let settings = LanguageSettings.shared

        CommandGroup(replacing: .newItem) {
            Button(tr("显示应用书架", "Show App Shelf")) {
                delegate.showShelfWindow()
            }
            .keyboardShortcut("1", modifiers: .command)

            Button(tr("运行 EXE / MSI…", "Run EXE / MSI…")) {
                delegate.showShelfWindow()
                delegate.store.pickAndRunExecutables()
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button(tr("浏览虚拟 C 盘 (drive_c)", "Browse Virtual C: Drive")) {
                delegate.store.openDriveCFolder()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button(tr("打开 Wine 配置 (winecfg)", "Open Wine Configuration (winecfg)")) {
                Task { await delegate.store.openWineCfg() }
            }

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
