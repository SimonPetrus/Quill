//
//  AboutView.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct AboutView: View {
	@StateObject private var _updates = SelfUpdateManager.shared
	@AppStorage(SelfUpdateManager.sourceURLKey) private var _sourceURL: String = SelfUpdateManager.defaultSourceURL
	@AppStorage(SelfUpdateManager.autoCheckKey) private var _autoCheck: Bool = false
	
	// MARK: Body
	var body: some View {
		NBList(.localized("About")) {
			Section {
				VStack {
					FRAppIconView(size: 72)
					
					Text(Bundle.main.name)
						.font(.largeTitle)
						.bold()
						.foregroundStyle(Color.accentColor)
					
					HStack(spacing: 4) {
						Text(.localized("Version"))
						Text(Bundle.main.version)
					}
					.font(.footnote)
					.foregroundStyle(.secondary)
				}
			}
			.frame(maxWidth: .infinity)
			.listRowBackground(EmptyView())
			
			NBSection(.localized("Developer")) {
				Button {
					if let url = URL(string: "https://github.com/SimonPetrus/Quill") {
						UIApplication.shared.open(url)
					}
				} label: {
					HStack {
						Label(.localized("SimonPetrus"), systemImage: "person.crop.circle")
						Spacer()
						Image(systemName: "arrow.up.right")
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				}
				.buttonStyle(.plain)
			}
			
			_updateSection()
			
			Section {
				Text(.localized("Based on Feather (GPL-3.0)."))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .center)
			}
		}
	}
}

// MARK: - Extension: View
extension AboutView {
	private var _hasSource: Bool {
		!_sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}
	
	@ViewBuilder
	private func _updateSection() -> some View {
		NBSection(.localized("Updates")) {
			Toggle(.localized("Check automatically on launch"), isOn: $_autoCheck)
				.disabled(!_hasSource)
			
			Button(.localized("Check for Updates"), systemImage: "arrow.triangle.2.circlepath") {
				Task { await _updates.check() }
			}
			.disabled(!_hasSource || _updates.status == .checking)
			
			switch _updates.status {
			case .idle:
				EmptyView()
			case .checking:
				ProgressView()
			case .upToDate(let version):
				Text(verbatim: .localized("Quill is up to date (%@)", arguments: version))
					.foregroundStyle(.secondary)
			case .available(let version, let url):
				Text(verbatim: .localized("Update available: %@", arguments: version))
				Button(.localized("Open"), systemImage: "safari") {
					UIApplication.shared.open(url)
				}
			case .failed(let message):
				Text(verbatim: message)
					.foregroundStyle(.red)
			}
		} footer: {
			Text(.localized("Quill checks GitHub for new versions. Updates are never downloaded automatically."))
		}
	}
}
