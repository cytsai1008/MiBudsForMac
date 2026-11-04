import Combine
import ServiceManagement
import SwiftUI

@main
struct MiBudsApp: App {
    @NSApplicationDelegateAdaptor(StatusItem.self) private var statusItem

    var body: some Scene {
        Settings { EmptyView() } // the UI lives in the status item
    }
}

/// Menu bar icon: left-click opens the panel, right-click (or Control-click) opens the app menu.
/// AppKit instead of MenuBarExtra, because MenuBarExtra cannot tell the two clicks apart.
@MainActor
final class StatusItem: NSObject, NSApplicationDelegate {
    private var buds: Buds!
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var iconWatch: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buds = Buds()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let host = NSHostingController(rootView: Menu(buds))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        iconWatch = buds.$ready.sink { [weak self] ready in
            self?.item.button?.image = NSImage(systemSymbolName: ready ? "earbuds" : "earbuds.case", accessibilityDescription: "MiBuds")
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MiBuds", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Attach only for this click, so a left-click still opens the panel.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

struct Menu: View {
    @ObservedObject var buds: Buds
    init(_ buds: Buds) { self.buds = buds }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(buds.deviceName ?? "Earbuds").font(.headline)
                Text(buds.status).font(.caption).foregroundStyle(.secondary)
            }

            if buds.ready {
                HStack(spacing: 16) {
                    BatteryView(label: "L", battery: buds.left)
                    BatteryView(label: "Case", battery: buds.box)
                    BatteryView(label: "R", battery: buds.right)
                }

                if !Models.hasNoNoiseControl(vendorID: buds.vendorID, productID: buds.productID) {
                    Picker("Noise control", selection: Binding(
                        get: { buds.anc ?? .off },
                        set: { buds.setANC($0) }
                    )) {
                        ForEach(ANCMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                }

                // UNTESTED: levels and ANC turbo, see ANCLevel and ZiMi in Protocol.swift.
                let levels = buds.anc.map { ANCLevel.options(for: $0, vendorID: buds.vendorID, productID: buds.productID) } ?? []
                if levels.count > 1 {
                    Picker("Level", selection: Binding(
                        get: { buds.ancLevel ?? 255 },
                        set: { buds.setANCLevel($0) }
                    )) {
                        if buds.ancLevel == nil { Text("–").tag(UInt8(255)) }
                        ForEach(levels, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                if buds.isZiMiEarbuds {
                    Toggle("ANC turbo", isOn: Binding(get: { buds.ancTurbo }, set: { buds.setANCTurbo($0) }))
                }
            }

            Divider()
            HStack {
                if buds.ready {
                    Button("Refresh") { buds.requestStatus() }
                    Button("Disconnect") { buds.disconnect() }
                } else {
                    Button("Connect") { buds.connect() }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 280)
    }
}

struct BatteryView: View {
    let label: String
    let battery: Battery?

    var body: some View {
        VStack(spacing: 2) {
            Text(battery.map { "\($0.percent)%" } ?? "–").font(.title3.monospacedDigit())
            HStack(spacing: 2) {
                if battery?.charging == true { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                Text(label)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
