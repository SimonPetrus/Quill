//
//  SigningFrameworksView.swift
//  Feather
//
//  Created by samara on 20.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct SigningFrameworksView: View {
	@State private var _frameworks: [String] = []
	@State private var _plugins: [String] = []
	
	private let _frameworksPath: String = "Frameworks"
	private let _pluginsPath: String = "PlugIns"
	
	@State private var _isEditing: Bool = false
	@State private var _selection: Set<String> = []
	@State private var _showRemoveAlert: Bool = false
	@State private var _isExporting: Bool = false
	@State private var _showExportError: Bool = false
	
	var app: AppInfoPresentable
	@Binding var options: Options?
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Frameworks & PlugIns")) {
			Group {
				if !_frameworks.isEmpty {
					NBSection(.localized("Frameworks")) {
						ForEach(_frameworks, id: \.self) { framework in
							_row("\(self._frameworksPath)/\(framework)", file: framework, folder: self._frameworksPath)
						}
					}
				}
				
				if !_plugins.isEmpty {
					NBSection(.localized("PlugIns")) {
						ForEach(_plugins, id: \.self) { plugin in
							_row("\(self._pluginsPath)/\(plugin)", file: plugin, folder: self._pluginsPath)
						}
					}
				}
				
				if
					_frameworks.isEmpty,
					_plugins.isEmpty
				{
					Text(.localized("No Frameworks or PlugIns Found."))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			}
			.disabled(options == nil)
		}
		.overlay { if _isExporting { ProgressView() } }
		.alert(.localized("Export Failed"), isPresented: $_showExportError) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(.localized("Could not export the selected item."))
		}
		.onAppear(perform: _listFrameworksAndPlugins)
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Button(_isEditing ? .localized("Done") : .localized("Edit")) {
					_isEditing.toggle()
					_selection.removeAll()
				}
				.disabled(_frameworks.isEmpty && _plugins.isEmpty)
			}
			
			if _isEditing {
				ToolbarItem(placement: .topBarTrailing) {
					Button(.localized("Remove Selected"), systemImage: "trash") {
						_showRemoveAlert = true
					}
					.disabled(_selection.isEmpty)
				}
			}
		}
		.alert(.localized("Remove Selected"), isPresented: $_showRemoveAlert) {
			Button(.localized("Remove"), role: .destructive) { _removeSelected() }
			Button(.localized("Cancel"), role: .cancel) {}
		} message: {
			Text(verbatim: .localized("Remove %lld selected items from the signed app?", arguments: _selection.count))
		}
	}
	
	@ViewBuilder
	private func _row(_ title: String, file: String, folder: String) -> some View {
		if _isEditing {
			Button {
				if _alreadyRemoved(title) { return }
				if _selection.contains(title) { _selection.remove(title) } else { _selection.insert(title) }
			} label: {
				HStack {
					Text(title).foregroundStyle(.primary)
					Spacer()
					Image(systemName: (_selection.contains(title) || _alreadyRemoved(title)) ? "checkmark.circle.fill" : "circle")
						.foregroundStyle(_alreadyRemoved(title) ? Color.secondary : (_selection.contains(title) ? Color.accentColor : Color.secondary))
				}
			}
			.disabled(_alreadyRemoved(title))
		} else {
			SigningToggleCellView(
				title: title,
				options: $options,
				arrayKeyPath: \.removeFiles
			)
			.contextMenu {
				Button(.localized("Export"), systemImage: "square.and.arrow.up") { _export(folder: folder, file: file) }
					.disabled(_isExporting)
			}
			.swipeActions(edge: .trailing) {
				Button(.localized("Export"), systemImage: "square.and.arrow.up") { _export(folder: folder, file: file) }
					.disabled(_isExporting)
					.tint(.blue)
			}
		}
	}
	
	private func _alreadyRemoved(_ title: String) -> Bool {
		options?.removeFiles.contains(title) ?? false
	}

	private func _export(folder: String, file: String) {
		guard !_isExporting, let path = Storage.shared.getAppDirectory(for: app) else { return }
		_isExporting = true
		SigningExportHelper.share(path.appendingPathComponent(folder).appendingPathComponent(file), completion: { _isExporting = false }, failure: {
			_isExporting = false
			_showExportError = true
		})
	}
	
	private func _removeSelected() {
		guard var opts = options else { return }
		for title in _selection where !opts.removeFiles.contains(title) {
			opts.removeFiles.append(title)
		}
		options = opts
		_selection.removeAll()
		_isEditing = false
	}
}

// MARK: - Extension: View
extension SigningFrameworksView {
	private func _listFrameworksAndPlugins() {
		guard let path = Storage.shared.getAppDirectory(for: app) else { return }
		
		_frameworks = _listFiles(at: path.appendingPathComponent(_frameworksPath))
		_plugins = _listFiles(at: path.appendingPathComponent(_pluginsPath))
	}
	
	private func _listFiles(at path: URL) -> [String] {
		(try? FileManager.default.contentsOfDirectory(atPath: path.path)) ?? []
	}
}
