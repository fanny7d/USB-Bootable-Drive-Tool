// USB Bootable Drive Tool
// SPDX-License-Identifier: MIT

import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

struct USBDevice: Equatable {
    let identifier: String
    let name: String
    let size: UInt64
    let protocolName: String

    var path: String { "/dev/\(identifier)" }
    var rawPath: String { "/dev/r\(identifier)" }

    var displayName: String {
        "\(name) — \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .decimal)) (\(identifier), \(protocolName))"
    }
}

final class GlassPanelView: NSVisualEffectView {
    init(material: NSVisualEffectView.Material, radius: CGFloat = 14) {
        super.init(frame: .zero)
        self.material = material
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let imageField = NSTextField(labelWithString: "尚未选择镜像")
    private let diskPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let chooseButton = NSButton(title: "选择镜像…", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新 U 盘", target: nil, action: nil)
    private let writeButton = NSButton(title: "制作启动盘", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "请选择镜像并插入 U 盘")
    private let spinner = NSProgressIndicator()
    private let imageStepIcon = NSImageView()
    private let diskStepIcon = NSImageView()
    private let writeStepIcon = NSImageView()
    private let imageStepSubtitle = NSTextField(labelWithString: "选择系统镜像")
    private let diskStepSubtitle = NSTextField(labelWithString: "选择目标 U 盘")
    private let writeStepSubtitle = NSTextField(labelWithString: "写入启动盘")

    private var imageURL: URL?
    private var devices: [USBDevice] = []
    private var statusFile: URL?
    private var monitorTimer: Timer?
    private var diskScanGeneration = 0
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var pendingDiskRefresh: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationIcon()
        installMainMenu()
        buildUI()
        observeExternalDiskChanges()
        refreshDisks()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard monitorTimer != nil else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "启动盘仍在制作"
        alert.informativeText = "退出只会关闭进度监控，Terminal 中的写入任务仍会继续。建议等待制作完成。"
        alert.addButton(withTitle: "继续等待")
        alert.addButton(withTitle: "仍要退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingDiskRefresh?.cancel()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.forEach(notificationCenter.removeObserver)
        workspaceObserverTokens.removeAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
        }
        scheduleDiskRefresh(after: 0.1)
        return true
    }

    private func installApplicationIcon() {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: url)
        else { return }
        NSApp.applicationIconImage = icon
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenuItem.submenu = applicationMenu
        applicationMenu.addItem(menuItem("关于 USB 启动盘工具", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(menuItem("隐藏 USB 启动盘工具", #selector(NSApplication.hide(_:)), key: "h"))
        let hideOthers = menuItem("隐藏其他应用", #selector(NSApplication.hideOtherApplications(_:)), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(hideOthers)
        applicationMenu.addItem(menuItem("全部显示", #selector(NSApplication.unhideAllApplications(_:))))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(menuItem("退出 USB 启动盘工具", #selector(NSApplication.terminate(_:)), key: "q"))
        mainMenu.addItem(applicationMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu
        let chooseImageItem = menuItem("选择系统镜像…", #selector(chooseImage), key: "o", target: self)
        fileMenu.addItem(chooseImageItem)
        fileMenu.addItem(menuItem("刷新 U 盘", #selector(refreshDisks), key: "r", target: self))
        fileMenu.addItem(.separator())
        fileMenu.addItem(menuItem("关闭窗口", #selector(NSWindow.performClose(_:)), key: "w"))
        mainMenu.addItem(fileMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(menuItem("最小化", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(menuItem("缩放", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(menuItem("前置全部窗口", #selector(NSApplication.arrangeInFront(_:))))
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private func buildUI() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "USB 启动盘工具"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 820, height: 540)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("USBMakerMainWindow")
        window.center()

        imageField.lineBreakMode = .byTruncatingMiddle
        imageField.toolTip = "镜像文件路径"
        imageField.font = .systemFont(ofSize: 14)

        chooseButton.target = self
        chooseButton.action = #selector(chooseImage)
        chooseButton.bezelStyle = .push
        chooseButton.controlSize = .large
        refreshButton.target = self
        refreshButton.action = #selector(refreshDisks)
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
        refreshButton.imagePosition = .imageLeading
        refreshButton.bezelStyle = .push
        refreshButton.controlSize = .large
        writeButton.target = self
        writeButton.action = #selector(startWriting)
        writeButton.bezelStyle = .rounded
        writeButton.controlSize = .large
        writeButton.bezelColor = .controlAccentColor
        writeButton.contentTintColor = .white
        writeButton.keyEquivalent = "\r"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.lineBreakMode = .byTruncatingTail

        guard let contentView = window.contentView else { return }
        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(background)

        let sidebar = makeSidebar()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let workspace = makeWorkspace()
        workspace.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(sidebar)
        background.addSubview(workspace)
        background.addSubview(divider)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            background.topAnchor.constraint(equalTo: contentView.topAnchor),
            background.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            sidebar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: background.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            sidebar.widthAnchor.constraint(equalTo: background.widthAnchor, multiplier: 0.29),

            workspace.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            workspace.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            workspace.topAnchor.constraint(equalTo: background.topAnchor),
            workspace.bottomAnchor.constraint(equalTo: background.bottomAnchor),

            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: background.topAnchor),
            divider.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
        ])
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        updateWriteButton()
    }

    private func observeExternalDiskChanges() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
            NSWorkspace.didWakeNotification,
        ]

        workspaceObserverTokens = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleDiskRefresh()
            }
        }
    }

    private func scheduleDiskRefresh(after delay: TimeInterval = 0.6) {
        guard monitorTimer == nil else { return }
        pendingDiskRefresh?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.monitorTimer == nil else { return }
            self.refreshDisks()
        }
        pendingDiskRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func makeSidebar() -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .active

        let heroIcon = NSImageView()
        if let iconURL = Bundle.main.url(forResource: "usb-drive", withExtension: "png") {
            heroIcon.image = NSImage(contentsOf: iconURL)
        } else {
            heroIcon.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "USB 启动盘")
            heroIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 66, weight: .light)
            heroIcon.contentTintColor = .secondaryLabelColor
        }
        heroIcon.imageScaling = .scaleProportionallyUpOrDown
        heroIcon.setAccessibilityLabel("USB 启动盘")

        let appTitle = NSTextField(labelWithString: "USB 启动盘工具")
        appTitle.font = .systemFont(ofSize: 24, weight: .bold)
        appTitle.alignment = .center

        let appSubtitle = NSTextField(wrappingLabelWithString: "将系统镜像写入外置 U 盘，\n制作可启动的安装盘。")
        appSubtitle.font = .systemFont(ofSize: 14)
        appSubtitle.textColor = .secondaryLabelColor
        appSubtitle.alignment = .center

        let steps = NSStackView(views: [
            makeStep(icon: imageStepIcon, title: "镜像", subtitle: imageStepSubtitle),
            makeStep(icon: diskStepIcon, title: "U 盘", subtitle: diskStepSubtitle),
            makeStep(icon: writeStepIcon, title: "写入", subtitle: writeStepSubtitle),
        ])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 22

        let content = NSStackView(views: [heroIcon, appTitle, appSubtitle, steps])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 14
        content.setCustomSpacing(34, after: appSubtitle)
        content.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -28),
            content.centerYAnchor.constraint(equalTo: sidebar.centerYAnchor, constant: -8),
            heroIcon.widthAnchor.constraint(equalToConstant: 140),
            heroIcon.heightAnchor.constraint(equalToConstant: 140),
            steps.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -16),
        ])
        updateProgressState()
        return sidebar
    }

    private func makeStep(icon: NSImageView, title: String, subtitle: NSTextField) -> NSView {
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let text = NSStackView(views: [titleLabel, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        return row
    }

    private func makeWorkspace() -> NSView {
        let workspace = NSView()

        let title = NSTextField(labelWithString: "制作启动盘")
        title.font = .systemFont(ofSize: 27, weight: .bold)

        let subtitle = NSTextField(wrappingLabelWithString: "写入会清空所选 U 盘上的全部数据。程序只显示外置、可移动且可写的整块磁盘。")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor

        let imageWell = GlassPanelView(material: .contentBackground, radius: 11)
        let imageIcon = NSImageView(
            image: NSImage(systemSymbolName: "doc.badge.gearshape", accessibilityDescription: "系统镜像")!)
        imageIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        imageIcon.contentTintColor = .secondaryLabelColor
        imageWell.addSubview(imageIcon)
        imageWell.addSubview(imageField)
        imageWell.addSubview(chooseButton)
        [imageIcon, imageField, chooseButton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            imageWell.heightAnchor.constraint(equalToConstant: 54),
            imageIcon.leadingAnchor.constraint(equalTo: imageWell.leadingAnchor, constant: 16),
            imageIcon.centerYAnchor.constraint(equalTo: imageWell.centerYAnchor),
            imageIcon.widthAnchor.constraint(equalToConstant: 23),
            imageField.leadingAnchor.constraint(equalTo: imageIcon.trailingAnchor, constant: 11),
            imageField.centerYAnchor.constraint(equalTo: imageWell.centerYAnchor),
            chooseButton.leadingAnchor.constraint(equalTo: imageField.trailingAnchor, constant: 12),
            chooseButton.trailingAnchor.constraint(equalTo: imageWell.trailingAnchor, constant: -10),
            chooseButton.centerYAnchor.constraint(equalTo: imageWell.centerYAnchor),
            chooseButton.widthAnchor.constraint(equalToConstant: 112),
        ])

        diskPopup.controlSize = .large
        let diskWell = GlassPanelView(material: .contentBackground, radius: 11)
        let diskIcon = NSImageView(
            image: NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "目标 U 盘")!)
        diskIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        diskIcon.contentTintColor = .secondaryLabelColor
        diskWell.addSubview(diskIcon)
        diskWell.addSubview(diskPopup)
        [diskIcon, diskPopup].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            diskWell.heightAnchor.constraint(equalToConstant: 54),
            diskIcon.leadingAnchor.constraint(equalTo: diskWell.leadingAnchor, constant: 16),
            diskIcon.centerYAnchor.constraint(equalTo: diskWell.centerYAnchor),
            diskIcon.widthAnchor.constraint(equalToConstant: 23),
            diskPopup.leadingAnchor.constraint(equalTo: diskIcon.trailingAnchor, constant: 7),
            diskPopup.trailingAnchor.constraint(equalTo: diskWell.trailingAnchor, constant: -7),
            diskPopup.centerYAnchor.constraint(equalTo: diskWell.centerYAnchor),
        ])

        let diskRow = NSStackView(views: [diskWell, refreshButton])
        diskRow.orientation = .horizontal
        diskRow.alignment = .centerY
        diskRow.spacing = 10
        diskWell.setContentHuggingPriority(.defaultLow, for: .horizontal)
        refreshButton.widthAnchor.constraint(equalToConstant: 108).isActive = true
        diskWell.widthAnchor.constraint(equalTo: diskRow.widthAnchor, constant: -118).isActive = true

        let warningPanel = GlassPanelView(material: .underPageBackground, radius: 11)
        let warningIcon = NSImageView(
            image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "警告")!)
        warningIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        warningIcon.contentTintColor = .systemOrange
        let warningTitle = NSTextField(labelWithString: "继续前会再次确认并清空目标磁盘")
        warningTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        let warningText = NSTextField(labelWithString: "所有数据将被永久删除，请提前备份重要文件。")
        warningText.font = .systemFont(ofSize: 12)
        warningText.textColor = .secondaryLabelColor
        let warningLabels = NSStackView(views: [warningTitle, warningText])
        warningLabels.orientation = .vertical
        warningLabels.alignment = .leading
        warningLabels.spacing = 3
        let warningContent = NSStackView(views: [warningIcon, warningLabels])
        warningContent.orientation = .horizontal
        warningContent.alignment = .centerY
        warningContent.spacing = 13
        warningContent.translatesAutoresizingMaskIntoConstraints = false
        warningPanel.addSubview(warningContent)
        NSLayoutConstraint.activate([
            warningContent.leadingAnchor.constraint(equalTo: warningPanel.leadingAnchor, constant: 16),
            warningContent.trailingAnchor.constraint(lessThanOrEqualTo: warningPanel.trailingAnchor, constant: -16),
            warningContent.centerYAnchor.constraint(equalTo: warningPanel.centerYAnchor),
            warningPanel.heightAnchor.constraint(equalToConstant: 72),
        ])

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let footer = NSStackView(views: [statusRow, writeButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 16
        statusRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        writeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 126).isActive = true

        let imageSection = makeSection(title: "选择系统镜像", content: imageWell)
        let diskSection = makeSection(title: "选择目标 U 盘", content: diskRow)
        let content = NSStackView(views: [
            title,
            subtitle,
            imageSection,
            diskSection,
            warningPanel,
            footer,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.setCustomSpacing(7, after: title)
        content.setCustomSpacing(46, after: subtitle)
        content.setCustomSpacing(25, after: imageSection)
        content.setCustomSpacing(62, after: diskSection)
        content.setCustomSpacing(20, after: warningPanel)
        content.translatesAutoresizingMaskIntoConstraints = false
        workspace.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: workspace.leadingAnchor, constant: 40),
            content.trailingAnchor.constraint(equalTo: workspace.trailingAnchor, constant: -40),
            content.topAnchor.constraint(equalTo: workspace.topAnchor, constant: 72),
            content.bottomAnchor.constraint(lessThanOrEqualTo: workspace.bottomAnchor, constant: -34),
            subtitle.widthAnchor.constraint(equalTo: content.widthAnchor),
            imageWell.widthAnchor.constraint(equalTo: content.widthAnchor),
            diskRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            warningPanel.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        return workspace
    }

    private func makeSection(title: String, content: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        let stack = NSStackView(views: [label, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    @objc private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "选择系统镜像"
        panel.prompt = "选择"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["iso", "img"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension == "iso" || fileExtension == "img" else {
            showAlert("不支持的镜像格式", "请选择扩展名为 .iso 或 .img 的系统镜像。")
            return
        }
        imageURL = url
        imageField.stringValue = url.path
        imageField.toolTip = url.path
        statusLabel.stringValue = "镜像已选择，请确认目标 U 盘"
        updateWriteButton()
        updateProgressState()
    }

    @objc private func refreshDisks() {
        let previous = selectedDevice?.identifier
        diskScanGeneration += 1
        let generation = diskScanGeneration

        devices = []
        diskPopup.removeAllItems()
        diskPopup.addItem(withTitle: "正在扫描外置 U 盘…")
        diskPopup.isEnabled = false
        refreshButton.isEnabled = false
        if monitorTimer == nil {
            statusLabel.stringValue = "正在扫描外置 U 盘…"
        }
        updateWriteButton()
        updateProgressState()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let discovered = self.discoverUSBDevices()
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.diskScanGeneration else { return }
                self.applyDiscoveredDevices(discovered, previous: previous)
            }
        }
    }

    private func applyDiscoveredDevices(_ discovered: [USBDevice], previous: String?) {
        devices = discovered
        diskPopup.removeAllItems()

        if devices.isEmpty {
            diskPopup.addItem(withTitle: "未发现可写的外置 U 盘")
            diskPopup.isEnabled = false
            statusLabel.stringValue = imageURL == nil ? "请选择镜像并插入 U 盘" : "镜像已选择，请插入 U 盘"
        } else {
            devices.forEach { diskPopup.addItem(withTitle: $0.displayName) }
            diskPopup.isEnabled = true
            diskPopup.selectItem(at: 0)
            if let previous, let index = devices.firstIndex(where: { $0.identifier == previous }) {
                diskPopup.selectItem(at: index)
            }
            diskPopup.synchronizeTitleAndSelectedItem()
            statusLabel.stringValue = imageURL == nil ? "请选择系统镜像" : "镜像和目标 U 盘已就绪"
        }

        refreshButton.isEnabled = monitorTimer == nil
        updateWriteButton()
        updateProgressState()
    }

    private var selectedDevice: USBDevice? {
        guard diskPopup.isEnabled, diskPopup.indexOfSelectedItem >= 0,
            diskPopup.indexOfSelectedItem < devices.count
        else { return nil }
        return devices[diskPopup.indexOfSelectedItem]
    }

    private func discoverUSBDevices() -> [USBDevice] {
        guard let list = run("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"]),
            let plist = try? PropertyListSerialization.propertyList(from: list, options: [], format: nil),
            let root = plist as? [String: Any],
            let identifiers = root["WholeDisks"] as? [String]
        else { return [] }

        return identifiers.compactMap { identifier in
            guard let data = run("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(identifier)"]),
                let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                let info = value as? [String: Any],
                boolValue(in: info, keys: ["WholeDisk", "Whole"]) == true,
                (info["Internal"] as? Bool) == false,
                boolValue(in: info, keys: ["RemovableMedia", "Removable"]) == true,
                boolValue(in: info, keys: ["WritableMedia", "Writable"]) == true,
                let sizeNumber = info["TotalSize"] as? NSNumber
            else { return nil }

            let name = (info["MediaName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let protocolName = info["BusProtocol"] as? String ?? "USB"
            return USBDevice(
                identifier: identifier,
                name: (name?.isEmpty == false ? name! : "外置 U 盘"),
                size: sizeNumber.uint64Value,
                protocolName: protocolName
            )
        }.sorted { $0.identifier < $1.identifier }
    }

    private func boolValue(in dictionary: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dictionary[key] as? Bool {
                return value
            }
            if let value = dictionary[key] as? NSNumber {
                return value.boolValue
            }
        }
        return nil
    }

    private func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 3) -> Data? {
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                usleep(100_000)
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            return output.fileHandleForReading.readDataToEndOfFile()
        } catch {
            return nil
        }
    }

    @objc private func startWriting() {
        guard let imageURL, let disk = selectedDevice else { return }

        // Re-read immediately before asking the user, so a replugged disk cannot inherit stale UI state.
        let current = discoverUSBDevices().first { $0.identifier == disk.identifier }
        guard current == disk else {
            showAlert("目标磁盘已变化", "请点击“刷新 U 盘”并重新选择。")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "确定清空 \(disk.displayName)？"
        alert.informativeText = "该磁盘上的全部分区和文件都会被覆盖，无法恢复。\n\n镜像：\(imageURL.lastPathComponent)"
        alert.addButton(withTitle: "清空并写入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let jobDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("USBMaker-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
            let script = jobDirectory.appendingPathComponent("write-usb.command")
            let status = jobDirectory.appendingPathComponent("status.txt")
            try makeScript(image: imageURL, disk: disk, status: status).write(
                to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            statusFile = status

            NSWorkspace.shared.open(script)
            beginMonitoring()
        } catch {
            showAlert("无法启动写入", error.localizedDescription)
        }
    }

    private func makeScript(image: URL, disk: USBDevice, status: URL) -> String {
        let device = shellQuote(disk.path)
        let rawDevice = shellQuote(disk.rawPath)
        let imagePath = shellQuote(image.path)
        let statusPath = shellQuote(status.path)
        let expectedSize = disk.size

        return """
            #!/bin/zsh
            set -euo pipefail
            STATUS=\(statusPath)
            DEVICE=\(device)
            RAW_DEVICE=\(rawDevice)
            IMAGE=\(imagePath)
            EXPECTED_SIZE=\(expectedSize)

            update_status() { print -r -- "$1" >| "$STATUS" }
            failed() {
              code=$?
              update_status "FAILED|写入失败（退出码 $code），请查看 Terminal 中的错误"
              print '\n写入失败，请不要将此 U 盘用于安装。'
              exit $code
            }
            trap failed ZERR INT TERM

            update_status 'CHECKING|正在重新验证目标磁盘…'
            info_file="${STATUS:h}/disk-info.plist"
            /usr/sbin/diskutil info -plist "$DEVICE" >| "$info_file"
            plist_bool() { /usr/bin/plutil -extract "$1" raw -o - "$info_file" 2>/dev/null || true }
            [[ "$(plist_bool WholeDisk)" == 'true' || "$(plist_bool Whole)" == 'true' ]]
            [[ "$(plist_bool Internal)" == 'false' ]]
            [[ "$(plist_bool RemovableMedia)" == 'true' || "$(plist_bool Removable)" == 'true' ]]
            [[ "$(plist_bool WritableMedia)" == 'true' || "$(plist_bool Writable)" == 'true' ]]
            [[ "$(/usr/bin/plutil -extract TotalSize raw -o - "$info_file")" == "$EXPECTED_SIZE" ]]

            update_status 'UNMOUNTING|正在卸载 U 盘…'
            /usr/sbin/diskutil unmountDisk "$DEVICE"

            update_status 'AUTH|请在 Terminal 中输入 Mac 登录密码（输入时不显示字符）'
            print '即将写入：' "$DEVICE"
            print '请输入 Mac 登录密码（输入时不会显示字符）：'
            /usr/bin/sudo -v

            update_status 'WRITING|正在写入镜像，请勿拔出 U 盘…'
            /usr/bin/sudo /bin/dd if="$IMAGE" of="$RAW_DEVICE" bs=4m

            update_status 'SYNCING|正在同步数据…'
            /bin/sync
            /usr/sbin/diskutil eject "$DEVICE"
            update_status 'COMPLETE|制作完成，U 盘已安全弹出'
            print '\n制作完成，U 盘已安全弹出，可以拔出。'
            """
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func beginMonitoring() {
        spinner.startAnimation(nil)
        chooseButton.isEnabled = false
        refreshButton.isEnabled = false
        diskPopup.isEnabled = false
        writeButton.isEnabled = false
        statusLabel.stringValue = "Terminal 已打开，等待任务启动…"
        updateProgressState()

        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.readStatus()
        }
    }

    private func readStatus() {
        guard let statusFile,
            let text = try? String(contentsOf: statusFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return }

        let fields = text.split(separator: "|", maxSplits: 1).map(String.init)
        let state = fields[0]
        statusLabel.stringValue = fields.count > 1 ? fields[1] : state

        if state == "COMPLETE" || state == "FAILED" {
            monitorTimer?.invalidate()
            monitorTimer = nil
            spinner.stopAnimation(nil)
            chooseButton.isEnabled = true
            refreshButton.isEnabled = true
            refreshDisks()
            updateProgressState()

            if state == "COMPLETE" {
                showAlert("启动盘制作完成", "U 盘已经安全弹出，可以用于启动和安装系统。", style: .informational)
            } else {
                showAlert("启动盘制作失败", fields.count > 1 ? fields[1] : "请查看 Terminal 中的错误。")
            }
        }
    }

    private func updateWriteButton() {
        writeButton.isEnabled = imageURL != nil && selectedDevice != nil && monitorTimer == nil
    }

    private func updateProgressState() {
        let isWriting = monitorTimer != nil
        let hasImage = imageURL != nil
        let hasDisk = selectedDevice != nil

        configureStep(
            imageStepIcon,
            symbol: hasImage ? "checkmark.circle.fill" : "1.circle.fill",
            highlighted: true
        )
        configureStep(
            diskStepIcon,
            symbol: hasDisk ? "checkmark.circle.fill" : (hasImage ? "2.circle.fill" : "2.circle"),
            highlighted: hasImage || hasDisk
        )
        configureStep(
            writeStepIcon,
            symbol: isWriting ? "3.circle.fill" : "3.circle",
            highlighted: isWriting
        )

        imageStepSubtitle.stringValue = hasImage ? "镜像已选择" : "选择系统镜像"
        diskStepSubtitle.stringValue = hasDisk ? "目标已就绪" : "选择目标 U 盘"
        writeStepSubtitle.stringValue = isWriting ? "正在执行" : "写入启动盘"
    }

    private func configureStep(_ imageView: NSImageView, symbol: String, highlighted: Bool) {
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView.contentTintColor = highlighted ? .controlAccentColor : .tertiaryLabelColor
    }

    private func showAlert(_ title: String, _ message: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

@main
enum USBMakerApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
