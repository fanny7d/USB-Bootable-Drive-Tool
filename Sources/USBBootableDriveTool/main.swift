// USB Bootable Drive Tool
// SPDX-License-Identifier: MIT

import AppKit
import Darwin
import Foundation
import Security
import UniformTypeIdentifiers

// Swift hides this legacy Authorization Services entry point even though macOS still exports it.
// It is used as a certificate-free bridge until the project can ship a Developer ID-authenticated
// SMAppService helper. The system owns the authorization UI; the app never receives credentials.
@_silgen_name("AuthorizationExecuteWithPrivileges")
private func executeWithPrivileges(
    _ authorization: AuthorizationRef,
    _ pathToTool: UnsafePointer<CChar>,
    _ options: AuthorizationFlags,
    _ arguments: UnsafePointer<UnsafeMutablePointer<CChar>>,
    _ communicationsPipe: UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
) -> OSStatus

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

struct WriteJobContext {
    let imageName: String
    let disk: USBDevice
    let startedAt: Date
}

enum WritePhase {
    case idle
    case writing
    case succeeded
    case failed
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
    private let logTextView = NSTextView()
    private let activityIcon = NSImageView()
    private let activityTitleLabel = NSTextField(labelWithString: "等待开始")
    private let activitySubtitleLabel = NSTextField(labelWithString: "选择镜像和目标 U 盘后即可制作")
    private let imageStepIcon = NSImageView()
    private let diskStepIcon = NSImageView()
    private let writeStepIcon = NSImageView()
    private let imageStepSubtitle = NSTextField(labelWithString: "选择系统镜像")
    private let diskStepSubtitle = NSTextField(labelWithString: "选择目标 U 盘")
    private let writeStepSubtitle = NSTextField(labelWithString: "写入启动盘")

    private var imageURL: URL?
    private var devices: [USBDevice] = []
    private var isWriting = false
    private var writePhase: WritePhase = .idle
    private var activeJob: WriteJobContext?
    private var diskScanGeneration = 0
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var pendingDiskRefresh: DispatchWorkItem?
    private let writerQueue = DispatchQueue(label: "cn.fanny7d.usb-maker.writer", qos: .userInitiated)

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
        guard isWriting else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "启动盘仍在制作"
        alert.informativeText = "为避免中断写入并损坏 U 盘，制作完成前不能退出应用。"
        alert.addButton(withTitle: "继续等待")
        alert.runModal()
        return .terminateCancel
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
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "USB 启动盘工具"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentMinSize = NSSize(width: 840, height: 600)
        window.contentMaxSize = NSSize(width: 1_240, height: 900)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let windowFrameName = NSWindow.FrameAutosaveName("USBMakerMainWindowV4")
        let restoredWindowFrame = window.setFrameUsingName(windowFrameName)
        window.setFrameAutosaveName(windowFrameName)
        if !restoredWindowFrame {
            window.center()
        }

        imageField.lineBreakMode = .byTruncatingMiddle
        imageField.maximumNumberOfLines = 1
        imageField.cell?.usesSingleLineMode = true
        imageField.cell?.truncatesLastVisibleLine = true
        imageField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageField.toolTip = "镜像文件路径"
        imageField.font = .systemFont(ofSize: 14)

        chooseButton.target = self
        chooseButton.action = #selector(chooseImage)
        chooseButton.bezelStyle = .push
        chooseButton.controlSize = .large
        refreshButton.target = self
        refreshButton.action = #selector(refreshDisks)
        refreshButton.title = ""
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
        refreshButton.imagePosition = .imageOnly
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.controlSize = .regular
        refreshButton.toolTip = "刷新 U 盘"
        refreshButton.setAccessibilityLabel("刷新 U 盘")
        diskPopup.target = self
        diskPopup.action = #selector(diskSelectionChanged)
        diskPopup.cell?.lineBreakMode = .byTruncatingMiddle
        diskPopup.cell?.usesSingleLineMode = true
        diskPopup.cell?.truncatesLastVisibleLine = true
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
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.toolTip = statusLabel.stringValue

        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.drawsBackground = false
        logTextView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        logTextView.textColor = .secondaryLabelColor
        logTextView.textContainerInset = NSSize(width: 10, height: 8)
        logTextView.string = "等待开始制作…"
        logTextView.setAccessibilityLabel("制作日志")

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
            sidebar.widthAnchor.constraint(equalToConstant: 264),

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
        guard !isWriting else { return }
        pendingDiskRefresh?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isWriting else { return }
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
            makeStep(icon: imageStepIcon, title: "系统镜像", subtitle: imageStepSubtitle),
            makeStep(icon: diskStepIcon, title: "目标设备", subtitle: diskStepSubtitle),
            makeStep(icon: writeStepIcon, title: "制作状态", subtitle: writeStepSubtitle),
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

        let preparationPanel = makePreparationPanel()
        let activityPanel = makeLogPanel()

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [statusRow, footerSpacer, writeButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 16
        statusRow.setContentHuggingPriority(.required, for: .horizontal)
        statusRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        writeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 126).isActive = true

        let content = NSStackView(views: [
            title,
            subtitle,
            preparationPanel,
            activityPanel,
            footer,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.setCustomSpacing(7, after: title)
        content.setCustomSpacing(24, after: subtitle)
        content.setCustomSpacing(16, after: preparationPanel)
        content.setCustomSpacing(14, after: activityPanel)
        content.translatesAutoresizingMaskIntoConstraints = false
        workspace.addSubview(content)

        let responsiveWidth = content.widthAnchor.constraint(equalTo: workspace.widthAnchor, constant: -72)
        responsiveWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: workspace.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: workspace.leadingAnchor, constant: 36),
            content.trailingAnchor.constraint(lessThanOrEqualTo: workspace.trailingAnchor, constant: -36),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            responsiveWidth,
            content.topAnchor.constraint(equalTo: workspace.topAnchor, constant: 72),
            content.bottomAnchor.constraint(equalTo: workspace.bottomAnchor, constant: -34),
            subtitle.widthAnchor.constraint(equalTo: content.widthAnchor),
            preparationPanel.widthAnchor.constraint(equalTo: content.widthAnchor),
            activityPanel.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        return workspace
    }

    private func makePreparationPanel() -> NSView {
        let panel = GlassPanelView(material: .contentBackground, radius: 14)

        let heading = NSTextField(labelWithString: "制作准备")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(labelWithString: "确认镜像与目标设备")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let header = NSStackView(views: [heading, hint])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2

        chooseButton.title = "选择…"
        chooseButton.controlSize = .regular
        chooseButton.widthAnchor.constraint(equalToConstant: 82).isActive = true

        let imageRow = makePreparationRow(
            symbol: "doc.badge.gearshape",
            title: "系统镜像",
            detail: imageField,
            controls: [chooseButton]
        )

        diskPopup.controlSize = .regular
        diskPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        refreshButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let diskHint = NSTextField(labelWithString: "外置、可移动且可写的整块磁盘")
        diskHint.font = .systemFont(ofSize: 12)
        diskHint.textColor = .secondaryLabelColor
        diskHint.lineBreakMode = .byTruncatingTail
        diskHint.maximumNumberOfLines = 1
        diskHint.toolTip = "仅显示外置、可移动且可写的整块磁盘"
        let diskRow = makePreparationRow(
            symbol: "externaldrive",
            title: "目标 U 盘",
            detail: diskHint,
            controls: [diskPopup, refreshButton]
        )

        let firstSeparator = NSBox()
        firstSeparator.boxType = .separator
        let secondSeparator = NSBox()
        secondSeparator.boxType = .separator

        let stack = NSStackView(views: [header, firstSeparator, imageRow, secondSeparator, diskRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(12, after: header)
        stack.setCustomSpacing(5, after: firstSeparator)
        stack.setCustomSpacing(5, after: imageRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 15),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -15),
            firstSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            secondSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            diskRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageRow.heightAnchor.constraint(equalToConstant: 46),
            diskRow.heightAnchor.constraint(equalToConstant: 46),
        ])
        return panel
    }

    private func makePreparationRow(
        symbol: String,
        title: String,
        detail: NSView,
        controls: [NSView]
    ) -> NSView {
        let icon = NSImageView(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let text = NSStackView(views: [titleLabel, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setContentHuggingPriority(.required, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, text, spacer] + controls)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func makeLogPanel() -> NSView {
        let panel = GlassPanelView(material: .contentBackground, radius: 14)
        activityIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        activityIcon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        activityTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        activitySubtitleLabel.font = .systemFont(ofSize: 12)
        activitySubtitleLabel.textColor = .secondaryLabelColor
        activitySubtitleLabel.lineBreakMode = .byTruncatingTail
        activitySubtitleLabel.maximumNumberOfLines = 1
        activitySubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let activityText = NSStackView(views: [activityTitleLabel, activitySubtitleLabel])
        activityText.orientation = .vertical
        activityText.alignment = .leading
        activityText.spacing = 2
        activityText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [activityIcon, activityText])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 11

        let separator = NSBox()
        separator.boxType = .separator
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = logTextView
        let stack = NSStackView(views: [header, separator, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)

        logTextView.minSize = NSSize(width: 0, height: 0)
        logTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.autoresizingMask = [.width]
        logTextView.textContainer?.widthTracksTextView = true

        NSLayoutConstraint.activate([
            panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -6),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.setContentHuggingPriority(.defaultLow, for: .vertical)
        return panel
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
        writePhase = .idle
        imageField.stringValue = url.lastPathComponent
        imageField.toolTip = url.path
        setStatus(readinessStatus())
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
        if !isWriting && writePhase == .idle {
            setStatus("正在扫描外置 U 盘…")
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
            diskPopup.toolTip = nil
        } else {
            devices.forEach { diskPopup.addItem(withTitle: $0.displayName) }
            diskPopup.isEnabled = true
            diskPopup.selectItem(at: 0)
            if let previous, let index = devices.firstIndex(where: { $0.identifier == previous }) {
                diskPopup.selectItem(at: index)
            }
            diskPopup.synchronizeTitleAndSelectedItem()
            diskPopup.toolTip = selectedDevice?.displayName
        }

        if writePhase == .idle {
            setStatus(readinessStatus())
        } else if writePhase == .succeeded {
            setStatus("制作完成，U 盘已安全弹出")
        }

        refreshButton.isEnabled = !isWriting
        updateWriteButton()
        updateProgressState()
    }

    @objc private func diskSelectionChanged() {
        diskPopup.toolTip = selectedDevice?.displayName
        if writePhase == .idle {
            setStatus(readinessStatus())
        }
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

        guard let imageSize = try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            imageSize > 0
        else {
            showAlert("无法读取镜像", "请确认镜像文件仍然存在且可以读取。")
            return
        }

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

        activeJob = WriteJobContext(imageName: imageURL.lastPathComponent, disk: disk, startedAt: Date())
        beginWriting()
        writerQueue.async { [weak self] in
            self?.performAuthorizedWrite(image: imageURL, imageSize: UInt64(imageSize), disk: disk)
        }
    }

    private func makePrivilegedScript(image: URL, imageSize: UInt64, disk: USBDevice) -> String {
        let device = shellQuote(disk.path)
        let rawDevice = shellQuote(disk.rawPath)
        let imagePath = shellQuote(image.path)
        let expectedSize = disk.size

        return """
            set -euo pipefail
            exec 2>&1
            DEVICE=\(device)
            RAW_DEVICE=\(rawDevice)
            IMAGE=\(imagePath)
            EXPECTED_DISK_SIZE=\(expectedSize)
            EXPECTED_IMAGE_SIZE=\(imageSize)

            emit() { print -r -- "$1" }
            info_file=$(/usr/bin/mktemp /private/tmp/usb-maker-info.XXXXXX)
            cleanup() { /bin/rm -f "$info_file" }
            failed() {
              code=$?
              emit "FAILED|写入失败（退出码 $code），请勿使用这个 U 盘启动"
              exit $code
            }
            trap cleanup EXIT
            trap failed ZERR INT TERM

            emit 'CHECKING|正在重新验证镜像和目标磁盘…'
            [[ "$DEVICE" == /dev/disk<-> ]]
            [[ "$RAW_DEVICE" == /dev/rdisk<-> ]]
            [[ -f "$IMAGE" && -r "$IMAGE" ]]
            [[ "$(/usr/bin/stat -f %z "$IMAGE")" == "$EXPECTED_IMAGE_SIZE" ]]
            /usr/sbin/diskutil info -plist "$DEVICE" >| "$info_file"
            plist_bool() { /usr/bin/plutil -extract "$1" raw -o - "$info_file" 2>/dev/null || true }
            [[ "$(plist_bool WholeDisk)" == 'true' || "$(plist_bool Whole)" == 'true' ]]
            [[ "$(plist_bool Internal)" == 'false' ]]
            [[ "$(plist_bool RemovableMedia)" == 'true' || "$(plist_bool Removable)" == 'true' ]]
            [[ "$(plist_bool WritableMedia)" == 'true' || "$(plist_bool Writable)" == 'true' ]]
            [[ "$(/usr/bin/plutil -extract TotalSize raw -o - "$info_file")" == "$EXPECTED_DISK_SIZE" ]]

            emit 'UNMOUNTING|正在卸载 U 盘…'
            /usr/sbin/diskutil unmountDisk "$DEVICE"

            emit 'WRITING|正在写入镜像，请勿拔出 U 盘…'
            /bin/dd if="$IMAGE" of="$RAW_DEVICE" bs=4m &
            dd_pid=$!
            while /bin/kill -0 "$dd_pid" 2>/dev/null; do
              /bin/sleep 1
              /bin/kill -INFO "$dd_pid" 2>/dev/null || true
            done
            wait "$dd_pid"

            emit 'SYNCING|正在同步数据…'
            /bin/sync
            /usr/sbin/diskutil eject "$DEVICE"
            emit 'COMPLETE|制作完成，U 盘已安全弹出'
            """
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func beginWriting() {
        isWriting = true
        writePhase = .writing
        spinner.startAnimation(nil)
        chooseButton.isEnabled = false
        refreshButton.isEnabled = false
        diskPopup.isEnabled = false
        writeButton.isEnabled = false
        setStatus("正在请求 macOS 系统授权…")
        logTextView.string = ""
        appendLog("准备制作启动盘")
        appendLog("正在请求系统管理员授权；验证方式由 macOS 决定。")
        updateProgressState()
    }

    private func performAuthorizedWrite(image: URL, imageSize: UInt64, disk: USBDevice) {
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else {
            finishWriting(success: false, message: authorizationError(createStatus))
            return
        }
        defer { AuthorizationFree(authorization, []) }

        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        let authorizationStatus = copyWriteAuthorization(authorization, disk: disk, flags: flags)
        guard authorizationStatus == errAuthorizationSuccess else {
            let cancelled = authorizationStatus == errAuthorizationCanceled
            finishWriting(
                success: false,
                message: cancelled ? "已取消系统授权，未写入 U 盘" : authorizationError(authorizationStatus),
                showFailureAlert: !cancelled
            )
            return
        }

        let script = makePrivilegedScript(image: image, imageSize: imageSize, disk: disk)
        let rawArguments = ["-c", script]
        var arguments: [UnsafeMutablePointer<CChar>?] = rawArguments.map { strdup($0) }
        arguments.append(nil)
        defer { arguments.compactMap { $0 }.forEach { free($0) } }

        var communicationsPipe: UnsafeMutablePointer<FILE>?
        let executionStatus = "/bin/zsh".withCString { executable in
            arguments.withUnsafeMutableBufferPointer { buffer in
                let argumentPointer = UnsafeRawPointer(buffer.baseAddress!)
                    .assumingMemoryBound(to: UnsafeMutablePointer<CChar>.self)
                return executeWithPrivileges(
                    authorization,
                    executable,
                    [],
                    argumentPointer,
                    &communicationsPipe
                )
            }
        }
        guard executionStatus == errAuthorizationSuccess, let communicationsPipe else {
            finishWriting(success: false, message: authorizationError(executionStatus))
            return
        }

        var terminalState: (success: Bool, message: String)?
        var buffer = [CChar](repeating: 0, count: 4096)
        while fgets(&buffer, Int32(buffer.count), communicationsPipe) != nil {
            let line = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let result = handleWriterOutput(line) {
                terminalState = result
            }
        }
        fclose(communicationsPipe)

        guard let terminalState else {
            finishWriting(success: false, message: "特权写入进程意外结束，未收到完成状态")
            return
        }
        finishWriting(success: terminalState.success, message: terminalState.message)
    }

    private func copyWriteAuthorization(
        _ authorization: AuthorizationRef,
        disk: USBDevice,
        flags: AuthorizationFlags
    ) -> OSStatus {
        let toolPath = "/bin/zsh"
        let prompt = "USB 启动盘工具需要授权清空并写入 \(disk.displayName)。"

        return kAuthorizationRightExecute.withCString { rightName in
            toolPath.withCString { toolPointer in
                prompt.withCString { promptPointer in
                    kAuthorizationEnvironmentPrompt.withCString { promptName in
                        var right = AuthorizationItem(
                            name: rightName,
                            valueLength: strlen(toolPointer),
                            value: UnsafeMutableRawPointer(mutating: toolPointer),
                            flags: 0
                        )
                        var promptItem = AuthorizationItem(
                            name: promptName,
                            valueLength: strlen(promptPointer),
                            value: UnsafeMutableRawPointer(mutating: promptPointer),
                            flags: 0
                        )
                        return withUnsafeMutablePointer(to: &right) { rightPointer in
                            withUnsafeMutablePointer(to: &promptItem) { promptItemPointer in
                                var rights = AuthorizationRights(count: 1, items: rightPointer)
                                var environment = AuthorizationEnvironment(count: 1, items: promptItemPointer)
                                return AuthorizationCopyRights(
                                    authorization,
                                    &rights,
                                    &environment,
                                    flags,
                                    nil
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleWriterOutput(_ line: String) -> (success: Bool, message: String)? {
        let fields = line.split(separator: "|", maxSplits: 1).map(String.init)
        let recognizedStates = Set(["CHECKING", "UNMOUNTING", "WRITING", "SYNCING", "COMPLETE", "FAILED"])
        let hasRecognizedState = fields.count > 1 && recognizedStates.contains(fields[0])
        let state = hasRecognizedState ? fields[0] : "OUTPUT"
        let message = hasRecognizedState ? fields[1] : line

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appendLog(message)
            if state != "OUTPUT" {
                self.setStatus(message)
                self.setActivitySubtitle(message)
            }
        }

        switch state {
        case "COMPLETE":
            return (true, message)
        case "FAILED":
            return (false, message)
        default:
            return nil
        }
    }

    private func finishWriting(success: Bool, message: String, showFailureAlert: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let completedJob = self.activeJob
            self.activeJob = nil
            self.isWriting = false
            self.writePhase = success ? .succeeded : (showFailureAlert ? .failed : .idle)
            self.spinner.stopAnimation(nil)
            self.chooseButton.isEnabled = true
            self.refreshButton.isEnabled = true
            self.setStatus(message)
            if !self.logTextView.string.hasSuffix(message) {
                self.appendLog(message)
            }
            self.updateProgressState()
            self.refreshDisks()

            if success, let completedJob {
                self.presentWriteResult(success: true, message: message, job: completedJob)
            } else if showFailureAlert, let completedJob {
                self.presentWriteResult(success: false, message: message, job: completedJob)
            }
        }
    }

    private func presentWriteResult(success: Bool, message: String, job: WriteJobContext) {
        let elapsed = max(0, Int(Date().timeIntervalSince(job.startedAt)))
        let duration = elapsed >= 60 ? "\(elapsed / 60) 分 \(elapsed % 60) 秒" : "\(elapsed) 秒"

        let alert = NSAlert()
        alert.alertStyle = success ? .informational : .critical
        alert.messageText = success ? "启动盘制作完成" : "启动盘制作未完成"
        alert.informativeText = success ? "镜像已经写入并完成同步，目标 U 盘已安全弹出，可以拔出。" : message
        alert.icon = resultIcon(success: success)
        alert.accessoryView = resultDetailsView(
            rows: [
                ("镜像", job.imageName),
                ("目标", job.disk.displayName),
                ("耗时", duration),
                ("结果", success ? "已安全弹出" : "未完成，请检查日志"),
            ],
            success: success
        )
        alert.addButton(withTitle: success ? "完成" : "返回检查")
        alert.beginSheetModal(for: window) { _ in }
    }

    private func resultIcon(success: Bool) -> NSImage? {
        let symbol = success ? "checkmark.circle.fill" : "xmark.octagon.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: success ? "成功" : "失败")
        return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 54, weight: .medium))
    }

    private func resultDetailsView(rows: [(String, String)], success: Bool) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        for (title, value) in rows {
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.alignment = .right
            titleLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true

            let valueLabel = NSTextField(labelWithString: value)
            valueLabel.font = .systemFont(ofSize: 12.5)
            valueLabel.textColor = title == "结果" ? (success ? .systemGreen : .systemRed) : .labelColor
            valueLabel.lineBreakMode = .byTruncatingMiddle
            valueLabel.maximumNumberOfLines = 1
            valueLabel.toolTip = value
            valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let row = NSStackView(views: [titleLabel, valueLabel])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 12
            row.widthAnchor.constraint(equalToConstant: 410).isActive = true
            stack.addArrangedSubview(row)
        }

        let panel = GlassPanelView(material: .contentBackground, radius: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(equalToConstant: 438),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        return panel
    }

    private func appendLog(_ message: String) {
        let prefix = logTextView.string.isEmpty ? "" : "\n"
        logTextView.textStorage?.append(NSAttributedString(string: prefix + message))
        logTextView.scrollToEndOfDocument(nil)
    }

    private func setStatus(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.toolTip = message
    }

    private func setActivitySubtitle(_ message: String) {
        activitySubtitleLabel.stringValue = message
        activitySubtitleLabel.toolTip = message
    }

    private func authorizationError(_ status: OSStatus) -> String {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "系统授权失败：\(detail)"
    }

    private func updateWriteButton() {
        writeButton.isEnabled = imageURL != nil && selectedDevice != nil && !isWriting
    }

    private func readinessStatus() -> String {
        if imageURL == nil && selectedDevice == nil {
            return "请选择镜像并插入 U 盘"
        }
        if imageURL == nil {
            return "请选择系统镜像"
        }
        if selectedDevice == nil {
            return "镜像已选择，请插入 U 盘"
        }
        return "镜像和目标 U 盘已就绪"
    }

    private func updateProgressState() {
        let hasImage = imageURL != nil
        let hasDisk = selectedDevice != nil

        switch writePhase {
        case .succeeded:
            configureStep(imageStepIcon, symbol: "doc.fill", color: .systemGreen)
            configureStep(diskStepIcon, symbol: "eject.fill", color: .systemGreen)
            configureStep(writeStepIcon, symbol: "checkmark.circle.fill", color: .systemGreen)
            imageStepSubtitle.stringValue = "镜像已写入"
            diskStepSubtitle.stringValue = "已安全弹出"
            writeStepSubtitle.stringValue = "制作完成"
            configureStep(activityIcon, symbol: "checkmark.circle.fill", color: .systemGreen)
            activityTitleLabel.stringValue = "制作完成"
            setActivitySubtitle("镜像已写入，U 盘已安全弹出")
        case .failed:
            configureStep(imageStepIcon, symbol: "doc.fill", color: .secondaryLabelColor)
            configureStep(diskStepIcon, symbol: "externaldrive.fill", color: .systemOrange)
            configureStep(writeStepIcon, symbol: "xmark.circle.fill", color: .systemRed)
            imageStepSubtitle.stringValue = "保留所选镜像"
            diskStepSubtitle.stringValue = "请检查设备"
            writeStepSubtitle.stringValue = "制作未完成"
            configureStep(activityIcon, symbol: "xmark.octagon.fill", color: .systemRed)
            activityTitleLabel.stringValue = "制作未完成"
            setActivitySubtitle(statusLabel.stringValue)
        case .writing:
            configureStep(imageStepIcon, symbol: "doc.fill", color: .controlAccentColor)
            configureStep(diskStepIcon, symbol: "externaldrive.fill", color: .controlAccentColor)
            configureStep(writeStepIcon, symbol: "arrow.down.circle.fill", color: .controlAccentColor)
            imageStepSubtitle.stringValue = "使用所选镜像"
            diskStepSubtitle.stringValue = "目标已锁定"
            writeStepSubtitle.stringValue = "正在写入"
            configureStep(activityIcon, symbol: "arrow.down.circle.fill", color: .controlAccentColor)
            activityTitleLabel.stringValue = "正在制作启动盘"
            setActivitySubtitle(statusLabel.stringValue)
        case .idle:
            configureStep(
                imageStepIcon,
                symbol: hasImage ? "doc.fill" : "doc",
                color: hasImage ? .controlAccentColor : .tertiaryLabelColor
            )
            configureStep(
                diskStepIcon,
                symbol: hasDisk ? "externaldrive.fill" : "externaldrive",
                color: hasDisk ? .controlAccentColor : .tertiaryLabelColor
            )
            configureStep(writeStepIcon, symbol: "arrow.down.circle", color: .tertiaryLabelColor)
            imageStepSubtitle.stringValue = hasImage ? "镜像已选择" : "选择系统镜像"
            diskStepSubtitle.stringValue = hasDisk ? "目标已就绪" : "选择外置 U 盘"
            writeStepSubtitle.stringValue = hasImage && hasDisk ? "可以开始制作" : "等待准备完成"
            configureStep(
                activityIcon,
                symbol: hasImage && hasDisk ? "checkmark.circle" : "clock",
                color: hasImage && hasDisk ? .controlAccentColor : .tertiaryLabelColor
            )
            activityTitleLabel.stringValue = hasImage && hasDisk ? "准备就绪" : "等待开始"
            setActivitySubtitle(readinessStatus())
        }
    }

    private func configureStep(_ imageView: NSImageView, symbol: String, color: NSColor) {
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView.contentTintColor = color
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
