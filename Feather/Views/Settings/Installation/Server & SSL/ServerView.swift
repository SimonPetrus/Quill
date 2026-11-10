//
//  ServerView.swift
//  Feather
//
//  Created by samara on 6.05.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct ServerView: View {
	@Environment(\.scenePhase) private var _scenePhase
	@State private var _isTrusted: Bool?
	
	@AppStorage("Feather.ipFix") private var _ipFix: Bool = false
	@AppStorage("Feather.serverMethod") private var _serverMethod: Int = 0
	private let _serverMethods: [String] = [.localized("Fully Local"), .localized("Semi Local")]
	
	// MARK: Body
	var body: some View {
		Group {
			Section {
				Picker(
					.localized("Server Type"), 
					systemImage: "server.rack", 
					selection: $_serverMethod
				) {
					ForEach(_serverMethods.indices, id: \.description) { index in
						Text(_serverMethods[index]).tag(index)
					}
				}
				Toggle(
					.localized("Only use localhost address"), 
					systemImage: "lifepreserver", 
					isOn: $_ipFix
				)
				.disabled(_serverMethod != 1)
			}
			
			if _serverMethod == 0 {
				Section {
					Button(.localized("Install Local CA"), systemImage: "checkmark.shield") {
						do {
							try LocalCAInstaller.shared.install()
						} catch {
							UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
						}
					}
					
					HStack {
						Label {
							Text(.localized("Trust Status"))
						} icon: {
							Image(systemName: "lock.shield")
						}
						Spacer()
						if let trusted = _isTrusted {
							Text(trusted ? String.localized("Trusted") : String.localized("Not Trusted"))
								.foregroundStyle(trusted ? Color.green : Color.red)
						}
					}
				} footer: {
					Text(.localized("1) Install the profile: Settings → General → VPN & Device Management.\n2) Settings → General → About → Certificate Trust Settings → enable full trust for \"Feather Local Root CA\".\nThe profile must open in Safari. If another browser is your default, copy the address to Safari."))
				}
			}
		}
		.onAppear(perform: _refreshTrust)
		.onChange(of: _scenePhase) { phase in
			if phase == .active { _refreshTrust() }
		}
		.onChange(of: _serverMethod) { _ in _refreshTrust() }
	}
	
	private func _refreshTrust() {
		guard _serverMethod == 0 else { return }
		Task.detached(priority: .utility) {
			let trusted = ServerInstaller.isLocalCATrusted()
			await MainActor.run { _isTrusted = trusted }
		}
	}
}
