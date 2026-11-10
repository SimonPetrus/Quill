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
	@State private var _isTestingConnection = false
	
	@AppStorage("Quill.ipFix") private var _ipFix: Bool = false
	@AppStorage(ServerInstaller.serverMethodKey) private var _serverMethod: Int = ServerInstaller.defaultServerMethod
	@AppStorage(ServerInstaller.nameConstraintsKey) private var _nameConstraints: Bool = true
	@AppStorage(ServerInstaller.diagnosticsKey) private var _diagnostics: Bool = false
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
				
				if _serverMethod == 0, ServerInstaller.isFullyLocalBlockedByOS {
					Text(.localized("On iOS 27.2 and later, Fully Local installs are blocked by iOS. Use Semi Local (needs internet) or idevice (offline)."))
						.font(.footnote)
						.foregroundStyle(.orange)
				}
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
					
					Button {
						_testConnection()
					} label: {
						HStack {
							Label(.localized("Test Connection"), systemImage: "network")
							if _isTestingConnection {
								Spacer()
								ProgressView()
							}
						}
					}
					.disabled(_isTestingConnection)
					
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
					Text(.localized("1) Install the profile: Settings → General → VPN & Device Management.\n2) Settings → General → About → Certificate Trust Settings → enable full trust for \"Quill Local Root CA\".\nThe profile must open in Safari. If another browser is your default, copy the address to Safari."))
				}

				Section {
					Toggle(
						.localized("Restrict CA to localhost"),
						systemImage: "scope",
						isOn: $_nameConstraints
					)
				} header: {
					Text(.localized("Advanced"))
				} footer: {
					Text(.localized("After changing this, install and trust the CA again (for testing)."))
				}
			}

			Section {
				Toggle(
					.localized("Diagnostic mode"),
					systemImage: "stethoscope",
					isOn: $_diagnostics
				)

				if _diagnostics {
					NavigationLink {
						InstallLogView()
					} label: {
						Label(.localized("Last Install Log"), systemImage: "doc.text.magnifyingglass")
					}
				}
			} header: {
				if _serverMethod != 0 {
					Text(.localized("Advanced"))
				}
			} footer: {
				Text(.localized("Records the install connection; turn on only for troubleshooting."))
			}
		}
		.onAppear(perform: _refreshTrust)
		.onChange(of: _scenePhase) { phase in
			if phase == .active { _refreshTrust() }
		}
		.onChange(of: _serverMethod) { _ in _refreshTrust() }
		.onChange(of: _nameConstraints) { _ in _regenerateCA() }
	}

	/// The stored root no longer matches the setting: a new root (and server certificate) is created.
	private func _regenerateCA() {
		_isTrusted = nil
		Task.detached(priority: .userInitiated) {
			do {
				try ServerInstaller.createServerCert()
			} catch {
				await MainActor.run {
					UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
				}
			}
			let trusted = ServerInstaller.isLocalCATrusted()
			await MainActor.run { _isTrusted = trusted }
		}
	}
	
	private func _testConnection() {
		guard !_isTestingConnection else { return }
		_isTestingConnection = true
		
		Task.detached(priority: .userInitiated) {
			let lines = await LocalConnectionTester.run()
			await MainActor.run {
				_isTestingConnection = false
				UIAlertController.showAlertWithOk(
					title: .localized("Test Connection"),
					message: lines.joined(separator: "\n")
				)
			}
		}
	}
	
	private func _refreshTrust() {
		guard _serverMethod == 0 else { return }
		Task.detached(priority: .utility) {
			let trusted = ServerInstaller.isLocalCATrusted()
			await MainActor.run { _isTrusted = trusted }
		}
	}
}
