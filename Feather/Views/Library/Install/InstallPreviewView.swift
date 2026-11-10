//
//  InstallPreview.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
import OSLog
import CoreData

// MARK: - View
struct InstallPreviewView: View {
	@Environment(\.dismiss) var dismiss

	@AppStorage("Quill.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	@AppStorage("Quill.installationMethod") private var _installationMethod: Int = 0
	@AppStorage(ServerInstaller.serverMethodKey) private var _serverMethod: Int = ServerInstaller.defaultServerMethod
	@State private var _isWebviewPresenting = false
	@State private var _isLogPresenting = false
	@State private var progressTask: Task<Void, Never>?
	
	var app: AppInfoPresentable
	@StateObject var viewModel: InstallerStatusViewModel
	@StateObject var installer: ServerInstaller
	
	@State var isSharing: Bool
	private let _deleteSignedAfterInstall: Bool
	/// Set once the IPA is fully handed to iOS (server) or the install finished (idevice).
	@State private var _installReached = false
	@State private var _deleteScheduled = false
	/// Set once the user acknowledged that Quill closes while it updates itself.
	@State private var _selfUpdateConfirmed = false
	
	init(app: AppInfoPresentable, isSharing: Bool = false, deleteSignedAfterInstall: Bool? = nil) {
		self.app = app
		self.isSharing = isSharing
		self._deleteSignedAfterInstall = deleteSignedAfterInstall ?? OptionsManager.shared.options.post_deleteSignedAfterInstall
		let viewModel = InstallerStatusViewModel(isIdevice: UserDefaults.standard.integer(forKey: "Quill.installationMethod") == 1)
		self._viewModel = StateObject(wrappedValue: viewModel)
		self._installer = StateObject(wrappedValue: try! ServerInstaller(app: app, viewModel: viewModel))
	}
	
	// MARK: Body
	var body: some View {
		let cornerRadius = {
			if #available(iOS 26.0, *) {
				28.0
			} else {
				10.5
			}
		}()
		
		ZStack {
			InstallProgressView(app: app, viewModel: viewModel)
			_status()
			_button()
			_logButton()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.background(Color(UIColor.secondarySystemBackground))
		.cornerRadius(cornerRadius)
		.padding()
		.sheet(isPresented: $_isWebviewPresenting) {
			SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
		}
		.onReceive(viewModel.$status) { newStatus in
			if _installationMethod == 0 {
				if case .ready = newStatus {
					if _serverMethod == 0 {
						if installer.diagnostics {
							let link = installer.iTunesLink
							InstallServerLog.shared.add("Opening \(link)")
							UIApplication.shared.open(URL(string: link)!) { opened in
								InstallServerLog.shared.add("itms-services link \(opened ? "opened" : "could NOT be opened")")
							}
						} else {
							UIApplication.shared.open(URL(string: installer.iTunesLink)!)
						}
					} else if _serverMethod == 1 {
						_isWebviewPresenting = true
					}
				}
				
				if case .sendingPayload = newStatus, _serverMethod == 1 {
					_isWebviewPresenting = false
				}
				
				if case .installing = newStatus {
					_installReached = true
					if progressTask == nil {
						progressTask = startInstallProgressPolling(
							bundleID: app.identifier!,
							viewModel: viewModel
						)
					}
				}
				
				if case .completed(.success) = newStatus {
					_installReached = true
				}
				
				if case .broken(_) = newStatus {
					_installReached = false
				}
				
				if case .completed(.failure(_)) = newStatus {
					_installReached = false
				}
				
				switch newStatus {
				case .completed, .broken(_):
					progressTask?.cancel()
					progressTask = nil
					#if !targetEnvironment(macCatalyst)
					BackgroundAudioManager.shared.stop()
					#endif
				default:
					break
				}
			} else if case .completed(.success) = newStatus {
				_installReached = true
			}
		}
		.onAppear(perform: _checkTrustThenInstall)
		
		#if !targetEnvironment(macCatalyst)
		.onAppear {
			BackgroundAudioManager.shared.start()
		}
		#endif
		
		.onDisappear {
			progressTask?.cancel()
			progressTask = nil
			_deleteSignedIfNeeded()
			
			#if !targetEnvironment(macCatalyst)
			BackgroundAudioManager.shared.stop()
			#endif
		}
	}
	
	/// Removes the signed copy (record + files) after a real install; never when sharing or on failure.
	private func _deleteSignedIfNeeded() {
		guard
			_deleteSignedAfterInstall,
			_installReached,
			!isSharing,
			app.isSigned,
			!_deleteScheduled
		else { return }
		_deleteScheduled = true
		
		let app = app
		// Let the sheet finish dismissing before the managed object goes away.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
			if let object = app as? NSManagedObject,
			   object.isDeleted || object.managedObjectContext == nil {
				return
			}
			Storage.shared.deleteApp(for: app)
		}
	}
	
	@ViewBuilder
	private func _status() -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Label(viewModel.statusLabel, systemImage: viewModel.statusImage)
				.labelStyle(.titleAndIcon)
				.animation(.smooth, value: viewModel.statusImage)
			if case .broken(let error) = viewModel.status {
				Text(ErrorExplainer.message(for: error))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(8)
					.textSelection(.enabled)
			}
		}
		.padding()
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
	}
	
	@ViewBuilder
	private func _button() -> some View {
		ZStack {
			if viewModel.isCompleted {
				Button {
					UIApplication.openApp(with: app.identifier ?? "")
				} label: {
					NBButton("Open", systemImage: "", style: .text)
				}
				.padding()
				.compatTransition()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		.animation(.easeInOut(duration: 0.3), value: viewModel.isCompleted)
	}
	
	/// Fully Local diagnostics: shows the install server log (connections, TLS, requests).
	@ViewBuilder
	private func _logButton() -> some View {
		if installer.diagnostics, !isSharing, _installationMethod == 0, _serverMethod == 0 {
			Button {
				_isLogPresenting = true
			} label: {
				Label(.localized("Show Log"), systemImage: "doc.text.magnifyingglass")
					.font(.footnote)
			}
			.padding()
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
			.sheet(isPresented: $_isLogPresenting) {
				InstallLogSheetView()
			}
		}
	}
	
	/// Fully Local + server install: warn first if the local CA is not trusted yet.
	private func _checkTrustThenInstall() {
		guard !isSharing, !app.isQuillItself, _installationMethod == 0, _serverMethod == 0 else {
			_install()
			return
		}
		
		// iOS 27.2+ blocks Fully Local: offer Semi Local first (one alert at a time), then the CA check.
		if ServerInstaller.isFullyLocalBlockedByOS {
			_showFullyLocalBlockedAlert()
			return
		}
		_checkTrustThenInstallLocal()
	}
	
	private func _showFullyLocalBlockedAlert() {
		UIAlertController.showAlert(
			title: .localized("Fully Local Blocked"),
			message: .localized("On iOS 27.2 and later, Fully Local installs are blocked by iOS. Use Semi Local (needs internet) or idevice (offline)."),
			actions: [
				UIAlertAction(title: .localized("Switch to Semi Local"), style: .default) { _ in
					_serverMethod = 1
					_install()
				},
				UIAlertAction(title: .localized("Try Anyway"), style: .destructive) { _ in
					_checkTrustThenInstallLocal()
				},
				UIAlertAction(title: .localized("Cancel"), style: .cancel) { _ in
					dismiss()
				}
			]
		)
	}
	
	private func _checkTrustThenInstallLocal() {
		Task.detached(priority: .userInitiated) {
			let trusted = ServerInstaller.isLocalCATrusted()
			await MainActor.run {
				if trusted {
					_install()
				} else {
					_showUntrustedAlert()
				}
			}
		}
	}
	
	private func _showUntrustedAlert() {
		UIAlertController.showAlert(
			title: .localized("Local CA Not Trusted"),
			message: .localized("To use Fully Local, install the Local CA first and enable full trust for it in Certificate Trust Settings."),
			actions: [
				UIAlertAction(title: .localized("Install Local CA"), style: .default) { _ in
					do {
						try LocalCAInstaller.shared.install()
					} catch {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: ErrorExplainer.message(for: error))
					}
					dismiss()
				},
				UIAlertAction(title: .localized("Continue Anyway"), style: .destructive) { _ in
					_install()
				},
				UIAlertAction(title: .localized("Cancel"), style: .cancel) { _ in
					dismiss()
				}
			]
		)
	}
	
	private func _install() {
		if !isSharing, app.isQuillItself {
			guard _installationMethod == 1 else {
				// The server dies together with Quill when iOS closes it, so the server method can't work.
				UIAlertController.showAlert(
					title: .localized("Install"),
					message: .localized("Quill can't install over itself with the server method. Switch Installation Type to idevice (needs pairing file + VPN), then try again."),
					actions: [
						UIAlertAction(title: .localized("Open Settings"), style: .default) { _ in
							dismiss()
							DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
								Self._presentInstallationSettings()
							}
						},
						UIAlertAction(title: .localized("Cancel"), style: .cancel) { _ in dismiss() }
					]
				)
				return
			}
			if !_selfUpdateConfirmed {
				UIAlertController.showAlert(
					title: .localized("Install"),
					message: .localized("Quill will close during the update; reopen it from the home screen."),
					actions: [
						UIAlertAction(title: .localized("Install"), style: .default) { _ in
							_selfUpdateConfirmed = true
							_install()
						},
						UIAlertAction(title: .localized("Cancel"), style: .cancel) { _ in dismiss() }
					]
				)
				return
			}
		}
		
		Task.detached {
			do {
				let handler = await ArchiveHandler(app: app, viewModel: viewModel)
				try await handler.move()
				
				let packageUrl = try await handler.archive()
				
				if await !isSharing {
					if await _installationMethod == 0 {
						await MainActor.run {
							installer.packageUrl = packageUrl
							viewModel.status = .ready
						}
						
						if case .installing = await viewModel.status {
							let task = await startInstallProgressPolling(
								bundleID: app.identifier!,
								viewModel: viewModel
							)

							await MainActor.run {
								progressTask = task
							}
						}
					} else if await _installationMethod == 1 {
						let handler = await InstallationProxy(viewModel: viewModel)
						try await handler.install(at: packageUrl, suspend: app.identifier == Bundle.main.bundleIdentifier!)
					}
				} else {
					let package = try await handler.moveToArchive(packageUrl, shouldOpen: !_useShareSheet)
					
					if await !_useShareSheet {
						await MainActor.run {
							dismiss()
						}
					} else {
						if let package {
							await MainActor.run {
								dismiss()
								UIActivityViewController.show(activityItems: [package])
							}
						}
					}
				}
			} catch {
				await progressTask?.cancel()
				
				await MainActor.run {
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: String(describing: error),
						action: {
							HeartbeatManager.shared.start(true)
							dismiss()
						}
					)
				}
			}
		}
	}
	
	/// Shows Settings → Installation in a sheet (the tab bar has no programmatic selection).
	@MainActor
	private static func _presentInstallationSettings() {
		let root = NBNavigationView(.localized("Installation")) { InstallationView() }
		UIApplication.topViewController()?.present(UIHostingController(rootView: root), animated: true)
	}
	
	private func startInstallProgressPolling(
		bundleID: String,
		viewModel: InstallerStatusViewModel
	) -> Task<Void, Never> {

		Task.detached(priority: .background) {
			var hasStarted = false

			while !Task.isCancelled {
				let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

				if rawProgress > 0 {
					hasStarted = true
				}

				let progress = await hasStarted
					? _normalizeInstallProgress(rawProgress)
					: 0.0

				Logger.misc.info("Install progress for \(bundleID): \(progress)")

				await MainActor.run {
					viewModel.installProgress = progress
				}

				if hasStarted && rawProgress == 0 {
					await MainActor.run {
						viewModel.installProgress = 1.0
						viewModel.status = .completed(.success(()))
					}
					break
				}

				try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
			}
		}
	}

	private func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
		min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
	}
}
