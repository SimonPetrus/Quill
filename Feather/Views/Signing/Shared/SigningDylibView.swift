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
					}
					.swipeActions(edge: .trailing) {
						Button(.localized("Export"), systemImage: "square.and.arrow.up") {
							_export(dylib)
						}
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
		.onAppear(perform: _loadDylibs)
	}
}

// MARK: - Extension: View
extension SigningDylibView {
	private func _export(_ dylib: String) {
		guard let appDir = Storage.shared.getAppDirectory(for: app) else { return }
		var rel = dylib
		for prefix in ["@rpath/", "@executable_path/", "@loader_path/"] where rel.hasPrefix(prefix) {
			rel = String(rel.dropFirst(prefix.count))
		}
		let candidates = [appDir.appendingPathComponent(rel), appDir.appendingPathComponent("Frameworks").appendingPathComponent(rel)]
		guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
		SigningExportHelper.share(url)
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
	
	/// Copies a file (or zips a directory) to a temporary folder and presents the share sheet.
	static func share(_ source: URL) {
		let fm = FileManager.default
		try? fm.removeItem(at: _root)
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
			try? fm.removeItem(at: _root)
			return
		}
		
		DispatchQueue.main.async {
			guard
				let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
				let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
				var top = window.rootViewController
			else { return }
			while let presented = top.presentedViewController { top = presented }
			
			let vc = UIActivityViewController(activityItems: [item], applicationActivities: nil)
			vc.completionWithItemsHandler = { _, _, _, _ in
				try? FileManager.default.removeItem(at: _root)
			}
			vc.popoverPresentationController?.sourceView = top.view
			vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
			vc.popoverPresentationController?.permittedArrowDirections = []
			top.present(vc, animated: true)
		}
	}
}
