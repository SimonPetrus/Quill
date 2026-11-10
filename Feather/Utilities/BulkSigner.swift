//
//  BulkSigner.swift
//  Quill
//
//  Signs several library apps one after another with the global signing options.
//

import SwiftUI
import UIKit
import NimbleViews
import OSLog

// MARK: - Model
@MainActor
final class BulkSigner: ObservableObject {
	struct Failure: Identifiable {
		let id = UUID()
		let name: String
		let message: String
	}
	
	enum State { case running, finished }
	
	@Published private(set) var state: State = .running
	@Published private(set) var index = 0
	@Published private(set) var currentName = ""
	@Published private(set) var succeeded = 0
	@Published private(set) var failures: [Failure] = []
	@Published private(set) var skipped = 0
	@Published private(set) var unprocessed = 0
	@Published private(set) var deletedOriginals = false
	@Published private(set) var isCancelling = false
	
	let total: Int
	private let _apps: [AppInfoPresentable]
	private let _options: Options
	private let _certificate: CertificatePair?
	private var _backgroundTask: UIBackgroundTaskIdentifier = .invalid
	
	init(apps: [AppInfoPresentable], options: Options, certificate: CertificatePair?) {
		self._apps = apps
		self.total = apps.count
		self._options = options
		self._certificate = certificate
	}
	
	/// Finishes the current app, then stops.
	func cancel() {
		isCancelling = true
	}
	
	func start() {
		_backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "QuillBulkSigning") { [weak self] in
			// Out of background time: stop after the current app.
			Task { @MainActor in self?.cancel() }
		}
		
		Task { @MainActor in
			for (offset, app) in _apps.enumerated() {
				if isCancelling {
					unprocessed = _apps.count - offset
					break
				}
				
				index = offset + 1
				currentName = app.name ?? .localized("Unknown")
				
				guard Storage.shared.getAppDirectory(for: app) != nil else {
					skipped += 1
					continue
				}
				
				let error = await _sign(app)
				if let error {
					Logger.signing.error("Bulk signing failed for \(self.currentName): \(error.localizedDescription)")
					failures.append(Failure(name: currentName, message: error.localizedDescription))
				} else {
					succeeded += 1
					// Same behavior as single signing: delete the unsigned original.
					if _options.post_deleteAppAfterSigned, !app.isSigned {
						Storage.shared.deleteApp(for: app)
						deletedOriginals = true
					}
				}
			}
			
			state = .finished
			if _backgroundTask != .invalid {
				UIApplication.shared.endBackgroundTask(_backgroundTask)
				_backgroundTask = .invalid
			}
		}
	}
	
	private func _sign(_ app: AppInfoPresentable) async -> Error? {
		var options = _options
		
		// Same per-app adjustments SigningView applies on appear.
		if
			options.ppqProtection,
			let identifier = app.identifier,
			let cert = _certificate,
			cert.ppQCheck
		{
			options.appIdentifier = "\(identifier).\(options.ppqString)"
		}
		if
			let currentBundleId = app.identifier,
			let newBundleId = options.identifiers[currentBundleId]
		{
			options.appIdentifier = newBundleId
		}
		if
			let currentName = app.name,
			let newName = options.displayNames[currentName]
		{
			options.appName = newName
		}
		
		return await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
			FR.signPackageFile(app, using: options, icon: nil, certificate: _certificate) { error in
				continuation.resume(returning: error)
			}
		}
	}
}

// MARK: - View
struct BulkSigningView: View {
	@ObservedObject var signer: BulkSigner
	var onClose: () -> Void
	
	var body: some View {
		NBNavigationView(.localized("Re-sign"), displayMode: .inline) {
			Form {
				switch signer.state {
				case .running: _running()
				case .finished: _summary()
				}
			}
			.toolbar {
				if signer.state == .finished {
					ToolbarItem(placement: .topBarTrailing) {
						Button(.localized("Close")) { onClose() }
					}
				}
			}
		}
		.interactiveDismissDisabled(signer.state == .running)
	}
	
	@ViewBuilder
	private func _running() -> some View {
		Section {
			VStack(alignment: .leading, spacing: 12) {
				Text(verbatim: String.localized("Signing %d / %d", arguments: signer.index, signer.total))
					.font(.headline)
				Text(signer.currentName)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(2)
				ProgressView(value: Double(max(signer.index - 1, 0)), total: Double(max(signer.total, 1)))
			}
			.padding(.vertical, 4)
			
			if signer.isCancelling {
				Text(.localized("Stopping after the current app…"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			} else {
				Button(.localized("Cancel"), role: .destructive) { signer.cancel() }
			}
		}
	}
	
	@ViewBuilder
	private func _summary() -> some View {
		Section {
			LabeledContent(.localized("Signed"), value: "\(signer.succeeded)")
			LabeledContent(.localized("Failed"), value: "\(signer.failures.count)")
			LabeledContent(.localized("Skipped"), value: "\(signer.skipped)")
			if signer.unprocessed > 0 {
				LabeledContent(.localized("Not processed"), value: "\(signer.unprocessed)")
			}
		}
		
		if !signer.failures.isEmpty {
			Section(.localized("Failed")) {
				ForEach(signer.failures) { failure in
					VStack(alignment: .leading, spacing: 2) {
						Text(failure.name)
						Text(failure.message)
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				}
			}
		}
		
		Section {
			Text(.localized("Install After Signing is not applied when re-signing multiple apps."))
			if signer.deletedOriginals {
				Text(.localized("Unsigned originals were deleted (Delete After Signing)."))
			}
		}
		.font(.footnote)
		.foregroundStyle(.secondary)
	}
}
