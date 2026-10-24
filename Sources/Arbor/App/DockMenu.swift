import AppKit

/// The Dock icon's right-click menu, rebuilt each time it opens so it reflects the current favorites.
final class DockMenu: NSObject {
    @MainActor
    func build() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(L("新建窗口"), #selector(newWindow)))

        let favorites = SidebarStore.shared.favorites.filter(\.exists)
        if !favorites.isEmpty {
            menu.addItem(.separator())
            for favorite in favorites.prefix(8) {
                let entry = item(favorite.name, #selector(openFolder(_:)))
                entry.representedObject = favorite.url
                menu.addItem(entry)
            }
        }

        let saved = WorkspaceLibrary.shared.saved
        if !saved.isEmpty {
            menu.addItem(.separator())
            let submenu = NSMenu()
            for workspace in saved {
                let entry = item(workspace.name, #selector(openWorkspace(_:)))
                entry.representedObject = workspace.id
                submenu.addItem(entry)
            }
            let parent = NSMenuItem(title: L("工作区"), action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
        return menu
    }

    @MainActor
    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func newWindow() {
        MainActor.assumeIsolated { AppActions.newWindow() }
    }

    @objc private func openFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        MainActor.assumeIsolated { AppActions.show(url) }
    }

    @objc private func openWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        MainActor.assumeIsolated {
            guard let saved = WorkspaceLibrary.shared.saved.first(where: { $0.id == id }) else { return }
            AppActions.show()
            WorkspaceRegistry.shared.current?.open(saved)
        }
    }
}
