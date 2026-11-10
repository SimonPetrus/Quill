//
//  CertificatesInfoView.swift
//  Feather
//
//  Created by samara on 20.04.2025.
//

import SwiftUI
import NimbleViews
import Zsign

// MARK: - View
struct CertificatesInfoView: View {
	@Environment(\.dismiss) var dismiss
	@State var data: Certificate?
	@State private var _isEnteringPassword = false
	@State private var _newPassword = ""
	@State private var _passwordMissing = false
	
	var cert: CertificatePair
	
	// MARK: Body
	var body: some View {
		NBNavigationView(cert.nickname ?? "", displayMode: .inline) {
			Form {
				Section {} header: {
					Image("Cert")
						.resizable()
						.scaledToFit()
						.frame(width: 107, height: 107)
						.frame(maxWidth: .infinity, alignment: .center)
				}
				
				Section {
					Button(.localized("Enter / Update Password"), systemImage: "key") {
						_newPassword = ""
						_isEnteringPassword = true
					}
				} footer: {
					if _passwordMissing {
						Text(Storage.missingPasswordMessage)
							.foregroundStyle(.orange)
					}
				}
				
				if let data {
					_infoSection(data: data)
					_entitlementsSection(data: data)
					_miscSection(data: data)
				}
			}
			.toolbar {
				NBToolbarButton(role: .close)
			}
		}
		.alert(.localized("Certificate Password"), isPresented: $_isEnteringPassword) {
			SecureField(.localized("Password"), text: $_newPassword)
			Button(.localized("Cancel"), role: .cancel) { _newPassword = "" }
			Button(.localized("OK")) {
				let entered = _newPassword
				_newPassword = ""
				let message: String?
				switch cert.updatePassword(entered) {
				case .ok: message = nil
				case .wrong: message = .localized("The password is wrong.")
				case .unverifiable: message = .localized("The password could not be verified: the certificate files are not accessible.")
				case .keychainFailed: message = .localized("The password could not be saved securely.")
				}
				if let message {
					UIAlertController.showAlertWithOk(title: .localized("Error"), message: message)
				}
			}
		}
		.onAppear {
			data = Storage.shared.getProvisionFileDecoded(for: cert)
			cert.loadPasswordMissing { _passwordMissing = $0 }
		}
		.onReceive(NotificationCenter.default.publisher(for: .certificatePasswordStateChanged)) { _ in
			cert.loadPasswordMissing { _passwordMissing = $0 }
		}
	}
}

// MARK: - Extension: View
extension CertificatesInfoView {
	@ViewBuilder
	private func _infoSection(data: Certificate) -> some View {
		NBSection(.localized("Info")) {
			_info(.localized("Name"), description: data.Name)
			_info(.localized("AppID Name"), description: data.AppIDName)
			_info(.localized("Team Name"), description: data.TeamName)
		}
		
		Section {
			_info(.localized("Expires"), description: data.ExpirationDate.expirationInfo().formatted)
				.foregroundStyle(data.ExpirationDate.expirationInfo().color)
			
			_info(.localized("Revoked"), description: cert.revoked ? "✓" : "✗")
			
			if let ppq = data.PPQCheck {
				_info(.localized("PPQCheck"), description: ppq ? "✓" : "✗")
			}
		}
	}
	
	@ViewBuilder
	private func _entitlementsSection(data: Certificate) -> some View {
		if let entitlements = data.Entitlements {
			Section {
				NavigationLink(.localized("View Entitlements")) {
					CertificatesInfoEntitlementView(entitlements: entitlements)
				}
			}
		}
	}
	
	@ViewBuilder
	private func _miscSection(data: Certificate) -> some View {
		NBSection(.localized("Misc")) {
			_disclosure(.localized("Platform"), keys: data.Platform)
			
			if let all = data.ProvisionsAllDevices {
				_info(.localized("Provision All Devices"), description: all.description)
			}
			
			if let devices = data.ProvisionedDevices {
				_disclosure(.localized("Provisioned Devices"), keys: devices)
			}
			
			_disclosure(.localized("Team Identifiers"), keys: data.TeamIdentifier)
			
			if let prefix = data.ApplicationIdentifierPrefix{
				_disclosure(.localized("Identifier Prefix"), keys: prefix)
			}
		}
	}
	
	@ViewBuilder
	private func _info(_ title: String, description: String) -> some View {
		LabeledContent(title) {
			Text(description)
		}
		.copyableText(description)
	}
	
	@ViewBuilder
	private func _disclosure(_ title: String, keys: [String]) -> some View {
		DisclosureGroup(title) {
			ForEach(keys, id: \.self) { key in
				Text(key)
					.foregroundStyle(.secondary)
					.copyableText(key)
			}
		}
	}
}
