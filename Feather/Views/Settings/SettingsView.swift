//
//  SettingsView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import NimbleViews
import UIKit
import Darwin
import IDeviceSwift

// MARK: - View
struct SettingsView: View {
	@AppStorage("Quill.selectedCert") private var _storedSelectedCert: Int = 0
	@AppStorage(NotificationManager.enabledKey) private var _expiryNotifications: Bool = false
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>
	
	private var selectedCertificate: CertificatePair? {
		guard
			_storedSelectedCert >= 0,
			_storedSelectedCert < _certificates.count
		else {
			return nil
		}
		return _certificates[_storedSelectedCert]
	}

    
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Settings")) {
			Form {
				_feedback()
                
				Section {
					NavigationLink(destination: AppearanceView()) {
						Label(.localized("Appearance"), systemImage: "paintbrush")
					}
				}
                
				NBSection(.localized("Certificates")) {
                    
					if let cert = selectedCertificate {
						CertificatesCellView(cert: cert)
					} else {
						Text(.localized("No Certificate"))
							.font(.footnote)
							.foregroundColor(.disabled())
					}
					NavigationLink(destination: CertificatesView()) {
						Label(.localized("Certificates"), systemImage: "checkmark.seal")
					}
					Toggle(isOn: _expiryNotificationsBinding) {
						Label(.localized("Expiry Notifications"), systemImage: "bell.badge")
					}
                 
				} footer: {
					Text(.localized("Add and manage certificates used for signing applications."))
				}
                
				NBSection(.localized("Features")) {
					NavigationLink(destination: ConfigurationView()) {
						Label(.localized("Signing Options"), systemImage: "signature")
					}
					NavigationLink(destination: ArchiveView()) {
						Label(.localized("Archive & Compression"), systemImage: "archivebox")
					}
					NavigationLink(destination: InstallationView()) {
						Label(.localized("Installation"), systemImage: "arrow.down.circle")
					}
				} footer: {
					Text(.localized("Configure the apps way of installing, its zip compression levels, and custom modifications to apps."))
				}
                
				_directories()
                
				Section {
					NavigationLink(destination: BackupView()) {
						Label(.localized("Backup & Restore"), systemImage: "externaldrive")
					}
				} footer: {
					Text(.localized("Back up your settings, sources and, optionally, certificates, or restore them from a backup file."))
				}
				
				Section {
					NavigationLink(destination: ResetView()) {
						Label(.localized("Reset"), systemImage: "trash")
					}
				} footer: {
					Text(.localized("Reset the applications sources, certificates, apps, and general contents."))
				}
			}
		}
	}
}

// MARK: - View extension
extension SettingsView {
	/// Turning the switch on asks for notification permission; if it is denied the switch stays off
	/// and the user is pointed to the system Settings.
	private var _expiryNotificationsBinding: Binding<Bool> {
		Binding(
			get: { _expiryNotifications },
			set: { newValue in
				guard newValue else {
					_expiryNotifications = false
					NotificationManager.shared.reschedule()
					return
				}
				NotificationManager.shared.requestAuthorization { granted in
					if granted {
						_expiryNotifications = true
						NotificationManager.shared.reschedule()
					} else {
						_expiryNotifications = false
						UIAlertController.showAlert(
							title: .localized("Notifications Disabled"),
							message: .localized("Notifications are turned off for Quill. Allow them in the system Settings to get certificate expiry reminders."),
							actions: [
								UIAlertAction(title: .localized("Open Settings"), style: .default) { _ in
									NotificationManager.shared.openSystemSettings()
								},
								UIAlertAction(title: .localized("Cancel"), style: .cancel)
							]
						)
					}
				}
			}
		)
	}
	
	@ViewBuilder
	private func _feedback() -> some View {
		Section {
			NavigationLink(destination: AboutView()) {
				Label {
					Text(verbatim: .localized("About %@", arguments: Bundle.main.name))
				} icon: {
					FRAppIconView(size: 23)
				}
			}
			// Quill signed with a fixed App ID that differs from its bundle ID: iOS then does not
			// hand shared files to it. Wildcard profiles and missing profiles show nothing.
			if let profileID = OwnSigningIdentity.mismatchedProfileBundleID {
				Button {
					UIAlertController.showAlertWithOk(
						title: .localized("Bundle ID Mismatch"),
						message: .localized(
							"Quill runs as %1$@, but its profile is only valid for %2$@. iOS then does not hand shared files to Quill.\n\n1. Back up your data in Backup & Restore (turn on Include Certificates).\n2. Sign Quill again with %2$@ (tap “Use profile ID” when signing Quill) and install it.\n3. Open the new Quill and restore the backup.",
							arguments: Bundle.main.bundleIdentifier ?? "-", profileID
						)
					)
				} label: {
					Label {
						Text(verbatim: .localized("Share import won't work: Quill must be signed with the profile's ID (%@).", arguments: profileID))
							.font(.footnote)
					} icon: {
						Image(systemName: "exclamationmark.triangle.fill")
							.foregroundStyle(.orange)
					}
				}
			}
		}
	}
    
	@ViewBuilder
	private func _directories() -> some View {
		NBSection(.localized("Misc")) {
			Button(.localized("Open Documents"), systemImage: "folder") {
				UIApplication.open(URL.documentsDirectory.toSharedDocumentsURL()!)
			}
			Button(.localized("Open Archives"), systemImage: "folder") {
				UIApplication.open(FileManager.default.archives.toSharedDocumentsURL()!)
			}
			Button(.localized("Export Logs"), systemImage: "doc.text") {
				Task { @MainActor in
					do {
						let url = try await LogExporter.export()
						UIActivityViewController.show(activityItems: [url])
					} catch {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: ErrorExplainer.message(for: error))
					}
				}
			}
		} footer: {
			Text(.localized("All of the apps files are contained in the documents directory, here are some quick links to these."))
		}
	}
}
