//
//  RemoteFileTableView.swift
//  SFTP-Browser
//
//  Created by Codex on 4/27/26.
//

import AppKit
import SwiftUI

struct RemoteFileTableView: NSViewRepresentable {
    let items: [RemoteItem]
    @Binding var selectedItemIDs: Set<RemoteItem.ID>
    let actionsEnabled: Bool
    let onOpen: (RemoteItem) -> Void
    let onQuickLook: () -> Void
    let onRefresh: () -> Void
    let onDownloadSelection: () -> Void
    let onRename: (RemoteItem) -> Void
    let onDelete: (RemoteItem) -> Void
    let onDeleteSelection: () -> Void
    let onCreateFolder: () -> Void
    let onUpload: ([URL]) -> Void
    let makeFilePromiseWriter: (RemoteItem) -> RemoteFilePromiseWriter?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyLatestModel()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private static let nameColumnID = NSUserInterfaceItemIdentifier("name")
        private static let sizeColumnID = NSUserInterfaceItemIdentifier("size")
        private static let modifiedColumnID = NSUserInterfaceItemIdentifier("modified")
        private static let permissionsColumnID = NSUserInterfaceItemIdentifier("permissions")

        var parent: RemoteFileTableView

        private let tableView = ContextMenuTableView(frame: .zero)
        private let scrollView = NSScrollView(frame: .zero)
        private let contextMenu = NSMenu(title: "Remote Item")
        private var isApplyingSelection = false
        private var contextMenuTargetItem: RemoteItem?
        private var activeFilePromiseWriters: [RemoteFilePromiseWriter] = []
        private var displayedItems: [RemoteItem] = []

        init(_ parent: RemoteFileTableView) {
            self.parent = parent
            super.init()
        }

        func makeScrollView() -> NSScrollView {
            configureTableView()
            configureColumns()
            configureScrollView()
            applyLatestModel()
            return scrollView
        }

        func applyLatestModel() {
            displayedItems = sortedItems(parent.items, using: tableView.sortDescriptors)
            tableView.reloadData()
            applySelectionToTable(parent.selectedItemIDs)
        }

        private func configureTableView() {
            tableView.dataSource = self
            tableView.delegate = self
            tableView.allowsMultipleSelection = true
            tableView.allowsEmptySelection = true
            tableView.selectionHighlightStyle = .regular
            tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            tableView.intercellSpacing = NSSize(width: 0, height: 0)
            tableView.rowHeight = 28
            tableView.usesAlternatingRowBackgroundColors = false
            tableView.backgroundColor = .textBackgroundColor
            tableView.doubleAction = #selector(handleDoubleClick)
            tableView.target = self
            tableView.onQuickLook = { [weak self] in
                self?.parent.onQuickLook()
            }
            tableView.onDeleteSelection = { [weak self] in
                self?.parent.onDeleteSelection()
            }
            tableView.registerForDraggedTypes([.fileURL])
            tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

            contextMenu.delegate = self
            contextMenu.autoenablesItems = false
            tableView.menu = contextMenu
        }

        private func configureColumns() {
            let nameColumn = NSTableColumn(identifier: Self.nameColumnID)
            nameColumn.title = "Name"
            nameColumn.minWidth = 220
            nameColumn.width = 360
            nameColumn.resizingMask = .autoresizingMask
            nameColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: Self.nameColumnID.rawValue,
                ascending: true,
                selector: #selector(NSString.localizedStandardCompare(_:))
            )

            let sizeColumn = NSTableColumn(identifier: Self.sizeColumnID)
            sizeColumn.title = "Size"
            sizeColumn.minWidth = 90
            sizeColumn.width = 110
            sizeColumn.resizingMask = .userResizingMask
            sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: Self.sizeColumnID.rawValue, ascending: true)

            let modifiedColumn = NSTableColumn(identifier: Self.modifiedColumnID)
            modifiedColumn.title = "Modified"
            modifiedColumn.minWidth = 130
            modifiedColumn.width = 150
            modifiedColumn.resizingMask = .userResizingMask
            modifiedColumn.sortDescriptorPrototype = NSSortDescriptor(key: Self.modifiedColumnID.rawValue, ascending: true)

            let permissionsColumn = NSTableColumn(identifier: Self.permissionsColumnID)
            permissionsColumn.title = "Permissions"
            permissionsColumn.minWidth = 96
            permissionsColumn.width = 108
            permissionsColumn.resizingMask = .userResizingMask
            permissionsColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: Self.permissionsColumnID.rawValue,
                ascending: true,
                selector: #selector(NSString.localizedStandardCompare(_:))
            )

            tableView.addTableColumn(nameColumn)
            tableView.addTableColumn(sizeColumn)
            tableView.addTableColumn(modifiedColumn)
            tableView.addTableColumn(permissionsColumn)
        }

        private func configureScrollView() {
            scrollView.hasHorizontalScroller = true
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.documentView = tableView
        }

        private func item(at row: Int) -> RemoteItem? {
            guard displayedItems.indices.contains(row) else {
                return nil
            }
            return displayedItems[row]
        }

        private func selectedItemIDsFromTable() -> Set<RemoteItem.ID> {
            var ids = Set<RemoteItem.ID>()
            for row in tableView.selectedRowIndexes {
                guard let item = item(at: row) else {
                    continue
                }
                ids.insert(item.id)
            }
            return ids
        }

        private func selectedItemsFromTable() -> [RemoteItem] {
            tableView.selectedRowIndexes.compactMap { item(at: $0) }
        }

        private func applySelectionToTable(_ selectedItemIDs: Set<RemoteItem.ID>) {
            isApplyingSelection = true
            defer { isApplyingSelection = false }

            let indexSet = IndexSet(
                displayedItems.enumerated().compactMap { index, item in
                    selectedItemIDs.contains(item.id) ? index : nil
                }
            )
            tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
        }

        private func sortedItems(_ items: [RemoteItem], using sortDescriptors: [NSSortDescriptor]) -> [RemoteItem] {
            guard let sortDescriptor = sortDescriptors.first, let key = sortDescriptor.key else {
                return items
            }

            return items.sorted { lhs, rhs in
                let lhsRank = sortRank(lhs)
                let rhsRank = sortRank(rhs)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }

                let comparison = compare(lhs, rhs, key: key)
                if comparison == .orderedSame {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }

                return sortDescriptor.ascending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }
        }

        private func compare(_ lhs: RemoteItem, _ rhs: RemoteItem, key: String) -> ComparisonResult {
            switch key {
            case Self.nameColumnID.rawValue:
                return lhs.name.localizedStandardCompare(rhs.name)
            case Self.sizeColumnID.rawValue:
                return compare(lhs.sizeBytes, rhs.sizeBytes)
            case Self.modifiedColumnID.rawValue:
                return compare(lhs.modifiedAt, rhs.modifiedAt)
            case Self.permissionsColumnID.rawValue:
                return lhs.permissionsDescription.localizedStandardCompare(rhs.permissionsDescription)
            default:
                return lhs.name.localizedStandardCompare(rhs.name)
            }
        }

        private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
            if lhs < rhs {
                return .orderedAscending
            }
            if lhs > rhs {
                return .orderedDescending
            }
            return .orderedSame
        }

        private func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
            switch (lhs, rhs) {
            case (.none, .none):
                return .orderedSame
            case (.none, .some):
                return .orderedDescending
            case (.some, .none):
                return .orderedAscending
            case let (.some(lhs), .some(rhs)):
                return compare(lhs, rhs)
            }
        }

        private func contextTargetItem() -> RemoteItem? {
            if tableView.contextClickedRow >= 0, let item = item(at: tableView.contextClickedRow) {
                return item
            }

            return nil
        }

        private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true
            ]
            let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
            return objects.compactMap { object in
                (object as? URL) ?? (object as? NSURL)?.absoluteURL
            }
        }

        @objc
        private func handleDoubleClick() {
            guard let item = item(at: tableView.clickedRow) else {
                return
            }
            parent.onOpen(item)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            contextMenuTargetItem = contextTargetItem()

            let refreshItem = NSMenuItem(
                title: "Refresh",
                action: #selector(handleRefreshMenuAction),
                keyEquivalent: ""
            )
            refreshItem.target = self
            refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            refreshItem.isEnabled = parent.actionsEnabled
            menu.addItem(refreshItem)

            let newFolderItem = NSMenuItem(
                title: "New Folder",
                action: #selector(handleNewFolderMenuAction),
                keyEquivalent: ""
            )
            newFolderItem.target = self
            newFolderItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
            newFolderItem.isEnabled = parent.actionsEnabled
            menu.addItem(newFolderItem)

            guard contextMenuTargetItem != nil else {
                return
            }

            menu.addItem(.separator())

            let selectedItems = selectedItemsFromTable()
            let downloadItem = NSMenuItem(
                title: selectedItems.count > 1 ? "Download \(selectedItems.count) Items" : "Download",
                action: #selector(handleDownloadMenuAction),
                keyEquivalent: ""
            )
            downloadItem.target = self
            downloadItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
            downloadItem.isEnabled = parent.actionsEnabled
                && !selectedItems.isEmpty
                && !selectedItems.contains { $0.isSymlink }
            menu.addItem(downloadItem)

            let renameItem = NSMenuItem(
                title: "Rename",
                action: #selector(handleRenameMenuAction),
                keyEquivalent: ""
            )
            renameItem.target = self
            renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
            renameItem.isEnabled = parent.actionsEnabled && tableView.selectedRowIndexes.count <= 1
            menu.addItem(renameItem)

            let deleteItem = NSMenuItem(
                title: "Delete",
                action: #selector(handleDeleteMenuAction),
                keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            deleteItem.isEnabled = parent.actionsEnabled
            menu.addItem(deleteItem)
        }

        @objc
        private func handleRefreshMenuAction() {
            parent.onRefresh()
        }

        @objc
        private func handleDownloadMenuAction() {
            parent.onDownloadSelection()
        }

        @objc
        private func handleNewFolderMenuAction() {
            parent.onCreateFolder()
        }

        @objc
        private func handleRenameMenuAction() {
            guard let contextMenuTargetItem, tableView.selectedRowIndexes.count <= 1 else {
                return
            }
            parent.onRename(contextMenuTargetItem)
        }

        @objc
        private func handleDeleteMenuAction() {
            guard let contextMenuTargetItem else {
                return
            }
            parent.onDelete(contextMenuTargetItem)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            displayedItems.count
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection else {
                return
            }
            parent.selectedItemIDs = selectedItemIDsFromTable()
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            displayedItems = sortedItems(parent.items, using: tableView.sortDescriptors)
            tableView.reloadData()
            applySelectionToTable(parent.selectedItemIDs)
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: any NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard parent.actionsEnabled, !fileURLs(from: info.draggingPasteboard).isEmpty else {
                return []
            }

            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: any NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            let urls = fileURLs(from: info.draggingPasteboard)
            guard parent.actionsEnabled, !urls.isEmpty else {
                return false
            }

            parent.onUpload(urls)
            return true
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard
                parent.actionsEnabled,
                let item = item(at: row),
                let writer = parent.makeFilePromiseWriter(item)
            else {
                return nil
            }

            activeFilePromiseWriters.append(writer)
            return NSFilePromiseProvider(fileType: writer.fileType, delegate: writer)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let item = item(at: row), let tableColumn else {
                return nil
            }

            let columnID = tableColumn.identifier
            let identifier = NSUserInterfaceItemIdentifier("cell-\(columnID.rawValue)")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? NSTableCellView(frame: .zero)
            cell.identifier = identifier
            cell.textField = nil
            cell.imageView = nil
            cell.subviews.forEach { $0.removeFromSuperview() }

            if columnID == Self.nameColumnID {
                let imageView = NSImageView()
                imageView.image = NSImage(
                    systemSymbolName: symbolName(for: item),
                    accessibilityDescription: accessibilityDescription(for: item)
                )
                imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                imageView.contentTintColor = tintColor(for: item)
                imageView.translatesAutoresizingMaskIntoConstraints = false

                let textField = NSTextField(labelWithString: item.name)
                textField.lineBreakMode = .byTruncatingMiddle
                textField.translatesAutoresizingMaskIntoConstraints = false

                cell.addSubview(imageView)
                cell.addSubview(textField)
                cell.imageView = imageView
                cell.textField = textField

                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])

                return cell
            }

            let text: String
            let alignment: NSTextAlignment
            switch columnID {
            case Self.sizeColumnID:
                text = item.isDirectory || item.isSymlink ? "" : item.sizeDescription
                alignment = .right
            case Self.modifiedColumnID:
                text = item.modifiedDescription
                alignment = .left
            case Self.permissionsColumnID:
                text = item.permissionsDescription
                alignment = .left
            default:
                text = ""
                alignment = .left
            }

            let textField = NSTextField(labelWithString: text)
            textField.alignment = alignment
            textField.lineBreakMode = .byTruncatingTail
            textField.textColor = .secondaryLabelColor
            textField.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])

            return cell
        }

        private func sortRank(_ item: RemoteItem) -> Int {
            if item.isDirectory {
                return 0
            }
            if item.isSymlink {
                return 1
            }
            return 2
        }

        private func symbolName(for item: RemoteItem) -> String {
            if item.isDirectory {
                return "folder"
            }
            if item.isSymlink {
                return "link"
            }
            return "doc"
        }

        private func accessibilityDescription(for item: RemoteItem) -> String {
            if item.isDirectory {
                return "Folder"
            }
            if item.isSymlink {
                return "Symlink"
            }
            return "File"
        }

        private func tintColor(for item: RemoteItem) -> NSColor {
            if item.isDirectory {
                return .controlAccentColor
            }
            if item.isSymlink {
                return .tertiaryLabelColor
            }
            return .secondaryLabelColor
        }
    }
}

@MainActor
private final class ContextMenuTableView: NSTableView {
    private(set) var contextClickedRow = -1
    var onQuickLook: (() -> Void)?
    var onDeleteSelection: (() -> Void)?

    private func applyContextSelection(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        contextClickedRow = row

        guard row >= 0 else {
            return
        }

        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        applyContextSelection(for: event)
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        applyContextSelection(for: event)
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        if modifiers.isEmpty, event.charactersIgnoringModifiers == " " {
            onQuickLook?()
            return
        }
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            onDeleteSelection?()
            return
        }

        super.keyDown(with: event)
    }
}
