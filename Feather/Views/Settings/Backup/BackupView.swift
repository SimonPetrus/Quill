//
//  BackupView.swift
//  Quill
//
//  Backup (share sheet) and restore (file importer) of settings, sources and certificates.
//

import SwiftUI
import NimbleViews
import OSLog

// MARK: - View
struct BackupView: View {
	@State private var _includeCertificates = false
	@State private var _password = ""
	@State private var _passwordRepeat = ""
	@State private var _isWorking = false

	@State private var _isImporting = false
	@State private var _pickedURL: URL?
	@State private var _isAskingPassword = false
	@State private var _restorePassword = ""

	private var _passwordValid: Bool {
		!_includeCertificates
			|| (_password.count >= BackupHandler.minPasswordLength && _password == _passwordRepeat)
	}

	// MARK: Body
	var body: some View {
		NBList(.localized("Backup & Restore")) {
			Section {
				Toggle(.localized("Include Certificates"), systemImage: "checkmark.seal", isOn: $_includeCertificates)
				if _includeCertificates {
					SecureField(.localized("Backup Password"), text: $_password)
						.textContentType(.newPassword)
					SecureField(.localized("Repeat Password"), text: $_passwordRepeat)
						.textContentType(.newPassword)
				}
			} header: {
				Text(.localized("Backup"))
			} footer: {
				if _includeCertificates {
					Text(.localized("The backup is encrypted with this password (at least 8 characters). If you forget the password, the certificates in the backup cannot be opened. The password is not stored anywhere."))
				} else {
					Text(.localized("Settings and sources are saved. Turn on certificates to include them; certificate backups are always encrypted."))
				}
			}

			Section {
				Button(.localized("Back Up"), systemImage: "square.and.arrow.up") {
					_backup()
				}
				.disabled(!_passwordValid || _isWorking)

				Button(.localized("Restore from Backup"), systemImage: "square.and.arrow.down") {
					_isImporting = true
				}
				.disabled(_isWorking)
			} footer: {
				Text(.localized("Restoring adds what is missing. Existing certificates and sources are skipped and never overwritten."))
			}
		}
		.fileImporter(isPresented: $_isImporting, allowedContentTypes: [.quillBackup]) { result in
			switch result {
			case .success(let url):
				_didPick(url)
			case .failure(let error):
				_show(title: .localized("Error"), message: error.localizedDescription)
			}
		}
		.alert(.localized("Backup Password"), isPresented: $_isAskingPassword) {
			SecureField(.localized("Backup Password"), text: $_restorePassword)
			Button(.localized("Cancel"), role: .cancel) {
				_restorePassword = ""
				if let url = _pickedURL { try? FileManager.default.removeItem(at: url) }
				_pickedURL = nil
			}
			Button(.localized("Restore")) {
				if let url = _pickedURL { _restore(url, password: _restorePassword) }
				_restorePassword = ""
			}
		} message: {
			Text(.localized("This backup is encrypted. Enter its password."))
		}
		.overlay {
			if _isWorking { ProgressView().controlSize(.large) }
		}
	}
}

// MARK: - Actions
extension BackupView {
	private func _backup() {
		_isWorking = true
		let includeCertificates = _includeCertificates
		let password = _password
		Task {
			do {
				let url = try await BackupHandler.createBackup(
					includeCertificates: includeCertificates,
					password: includeCertificates ? password : nil
				)
				_isWorking = false
				UIActivityViewController.show(activityItems: [url])
			} catch {
				_isWorking = false
				_show(title: .localized("Error"), message: error.localizedDescription)
			}
		}
	}

	private func _didPick(_ url: URL) {
		// The picked file is only reachable inside the security scope; copy it out first.
		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }
		let copy = FileManager.default.temporaryDirectory
			.appendingPathComponent("QuillRestore-\(UUID().uuidString).quillbackup")
		do {
			try FileManager.default.copyItem(at: url, to: copy)
			if try BackupHandler.isEncrypted(at: copy) {
				_pickedURL = copy
				_restorePassword = ""
				_isAskingPassword = true
			} else {
				_restore(copy, password: nil)
			}
		} catch {
			try? FileManager.default.removeItem(at: copy)
			_show(title: .localized("Error"), message: error.localizedDescription)
		}
	}

	private func _restore(_ url: URL, password: String?) {
		_isWorking = true
		Task {
			do {
				let summary = try await BackupHandler.restore(from: url, password: password)
				_isWorking = false
				_pickedURL = nil
				try? FileManager.default.removeItem(at: url)
				_show(title: .localized("Restore Complete"), message: _summaryText(summary))
			} catch BackupError.wrongPassword {
				// The copy is kept so the password can be tried again.
				_isWorking = false
				_show(title: .localized("Error"), message: BackupError.wrongPassword.localizedDescription) {
					_isAskingPassword = true
				}
			} catch {
				_isWorking = false
				_pickedURL = nil
				try? FileManager.default.removeItem(at: url)
				_show(title: .localized("Error"), message: error.localizedDescription)
			}
		}
	}

	private func _summaryText(_ s: BackupSummary) -> String {
		var lines: [String] = []
		if s.settingsRestored { lines.append(.localized("Settings restored.")) }
		lines.append(.localized("Sources: %d added, %d skipped.", arguments: s.sourcesAdded, s.sourcesSkipped))
		lines.append(.localized("Certificates: %d added, %d skipped, %d failed.", arguments: s.certificatesAdded, s.certificatesSkipped, s.certificatesFailed))
		return lines.joined(separator: "\n")
	}

	private func _show(title: String, message: String, completion: (() -> Void)? = nil) {
		DispatchQueue.main.async {
			UIAlertController.showAlertWithOk(title: title, message: message, action: completion)
		}
	}
}
