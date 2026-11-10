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
	
	private let _frameworksPath: String = .localized("Frameworks")
	private let _pluginsPath: String = .localized("PlugIns")
	
	var app: AppInfoPresentable
	@Binding var options: Options?
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Frameworks & PlugIns")) {
			Group {
				if !_frameworks.isEmpty {
					NBSection(_frameworksPath) {
						ForEach(_frameworks, id: \.self) { framework in
							_row("\(self._frameworksPath)/\(framework)", file: framework, folder: self._frameworksPath)
						}
					}
				}
				
				if !_plugins.isEmpty {
					NBSection(_pluginsPath) {
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
		.onAppear(perform: _listFrameworksAndPlugins)
	}
	
	@ViewBuilder
	private func _row(_ title: String, file: String, folder: String) -> some View {
		SigningToggleCellView(
			title: title,
			options: $options,
			arrayKeyPath: \.removeFiles
		)
		.contextMenu {
			Button(.localized("Export"), systemImage: "square.and.arrow.up") { _export(folder: folder, file: file) }
		}
		.swipeActions(edge: .trailing) {
			Button(.localized("Export"), systemImage: "square.and.arrow.up") { _export(folder: folder, file: file) }
				.tint(.blue)
		}
	}
	
	private func _export(folder: String, file: String) {
		guard let path = Storage.shared.getAppDirectory(for: app) else { return }
		SigningExportHelper.share(path.appendingPathComponent(folder).appendingPathComponent(file))
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
