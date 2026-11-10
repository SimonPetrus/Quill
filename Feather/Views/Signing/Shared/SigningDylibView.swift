//
//  SigningOptionsDylibSharedView.swift
//  Feather
//
//  Created by samara on 19.04.2025.
//

import SwiftUI
import NimbleViews
import Zsign
import Zip
import UIKit

// MARK: - View
struct SigningDylibView: View {
	@State private var _dylibs: [String] = []
	@State private var _hiddenDylibCount: Int = 0
	@State private var _isExporting: Bool = false
	@State private var _showExportError: Bool = false
	
	var app: AppInfoPresentable
	@Binding var options: Options?
	
	var body: some View {
		NBList(.localized("Dylibs"), type: .list) {
			Section {
				ForEach(_dylibs, id: \.self) { dylib in
					SigningToggleCellView(
						title: dylib,
						options: $options,
						arrayKeyPath: \.disInjectionFiles
					)
					.contextMenu {
						Button(.localized("Export"), systemImage: "square.and.arrow.up") {
							_export(dylib)
						}
						.disabled(_isExporting)
					}
					.swipeActions(edge: .trailing) {
						Button(.localized("Export"), systemImage: "square.and.arrow.up") {
							_export(dylib)
						}
						.disabled(_isExporting)
						.tint(.blue)
					}
				}
			}
			.disabled(options == nil)
			
			NBSection(.localized("Hidden")) {
				Text(verbatim: .localized("%lld required system dylibs not shown.", arguments: _hiddenDylibCount))
					.font(.footnote)
					.foregroundColor(.disabled())
			}
		}
		.overlay { if _isExporting { ProgressView() } }
		.alert(.localized("Export Failed"), isPresented: $_showExportError) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(.localized("Could not export the selected item."))
		}
		.onAppear(perform: _loadDylibs)
	}
}

// MARK: - Extension: View
extension SigningDylibView {
	private func _export(_ dylib: String) {
		guard !_isExporting, let appDir = Storage.shared.getAppDirectory(for: app) else { return }
		var rel = dylib
		for prefix in ["@rpath/", "@executable_path/", "@loader_path/"] where rel.hasPrefix(prefix) {
			rel = String(rel.dropFirst(prefix.count))
		}
		let candidates = [appDir.appendingPathComponent(rel), appDir.appendingPathComponent("Frameworks").appendingPathComponent(rel)]
		guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
			_showExportError = true
			return
		}
		_isExporting = true
		SigningExportHelper.share(url, completion: { _isExporting = false }, failure: {
			_isExporting = false
			_showExportError = true
		})
	}
	
	private func _loadDylibs() {
		guard let path = Storage.shared.getAppDirectory(for: app) else { return }
		
		let bundle = Bundle(url: path)
		let execPath = path.appendingPathComponent(bundle?.exec ?? "").relativePath
		
		let allDylibs = Zsign.listDylibs(appExecutable: execPath).map { $0 as String }
		
		_dylibs = allDylibs.filter { $0.hasPrefix("@rpath") || $0.hasPrefix("@executable_path") }
		_hiddenDylibCount = allDylibs.count - _dylibs.count
	}
}

// MARK: - Export helper
enum SigningExportHelper {
	private static var _root: URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("QuillExport", isDirectory: true)
	}

	/// Removes export folders older than an hour (never touches a share that is still open).
	private static func _cleanOld() {
		let fm = FileManager.default
		let cutoff = Date().addingTimeInterval(-3600)
		let items = (try? fm.contentsOfDirectory(at: _root, includingPropertiesForKeys: [.creationDateKey])) ?? []
		for item in items {
			let date = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
			if date < cutoff { try? fm.removeItem(at: item) }
		}
	}

	/// Copies a file (or zips a directory) to a temporary folder off the main thread,
	/// then presents the share sheet on the main thread. `completion(false)` on failure.
	static func share(_ source: URL, completion: @escaping () -> Void = {}, failure: @escaping () -> Void = {}) {
		DispatchQueue.global(qos: .userInitiated).async {
			let fm = FileManager.default
			_cleanOld()
			let dir = _root.appendingPathComponent(UUID().uuidString, isDirectory: true)
			let item: URL
			do {
				try fm.createDirectory(at: dir, withIntermediateDirectories: true)
				var isDir: ObjCBool = false
				fm.fileExists(atPath: source.path, isDirectory: &isDir)
				if isDir.boolValue {
					item = dir.appendingPathComponent(source.lastPathComponent + ".zip")
					try Zip.zipFiles(paths: [source], zipFilePath: item, password: nil, progress: nil)
				} else {
					item = dir.appendingPathComponent(source.lastPathComponent)
					try fm.copyItem(at: source, to: item)
				}
			} catch {
				try? fm.removeItem(at: dir)
				DispatchQueue.main.async { failure() }
				return
			}

			DispatchQueue.main.async {
				guard
					let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
					let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
					var top = window.rootViewController
				else {
					try? fm.removeItem(at: dir)
					failure()
					return
				}
				while let presented = top.presentedViewController { top = presented }

				let vc = UIActivityViewController(activityItems: [item], applicationActivities: nil)
				vc.completionWithItemsHandler = { _, _, _, _ in
					try? FileManager.default.removeItem(at: dir)
				}
				vc.popoverPresentationController?.sourceView = top.view
				vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
				vc.popoverPresentationController?.permittedArrowDirections = []
				top.present(vc, animated: true)
				completion()
			}
		}
	}
}
