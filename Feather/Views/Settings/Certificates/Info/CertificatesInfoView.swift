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
				if cert.updatePassword(entered) {
					_passwordMissing = false
				} else {
					UIAlertController.showAlertWithOk(
						title: .localized("Error"),
						message: .localized("Wrong password, or it could not be saved securely.")
					)
				}
			}
		}
		.onAppear {
			data = Storage.shared.getProvisionFileDecoded(for: cert)
			_passwordMissing = cert.isPasswordMissing
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
