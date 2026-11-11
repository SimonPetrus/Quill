//
//  SigningView.swift
//  Feather
//
//  Created by samara on 14.04.2025.
//

import SwiftUI
import PhotosUI
import NimbleViews

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@StateObject private var _optionsManager = OptionsManager.shared
	
	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _isAltPickerPresenting = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _isSigning = false
	@State private var _isChecking = false
	@State private var _selectedPhoto: PhotosPickerItem? = nil
	@State private var _idEditedByUser = false
	@State private var _idFromProfile = false
	@State var appIcon: UIImage?
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
	private func _selectedCert() -> CertificatePair? {
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}
	
	var app: AppInfoPresentable
	
	init(app: AppInfoPresentable) {
		self.app = app
		let storedCert = UserDefaults.standard.integer(forKey: "Quill.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
	}
		
	// MARK: Body
	var body: some View {
		NBNavigationView("", displayMode: .inline) {
			Form {
				_customizationOptions(for: app)
				_cert()
				_customizationProperties(for: app)
				
				// horrible
				Rectangle()
					.foregroundStyle(.clear)
					.frame(height: 30)
					.listRowBackground(EmptyView())
			}
			.overlay {
				VStack(spacing: 0) {
					Spacer()
					NBVariableBlurView()
						.frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 60 : 80)
						.rotationEffect(.degrees(180))
						.overlay {
							Button {
								_start()
							} label: {
								NBSheetButton(title: .localized("Start Signing"), style: .prominent)
									.padding()
							}
							.buttonStyle(.plain)
							.disabled(_isChecking)
							.offset(y: UIDevice.current.userInterfaceIdiom == .pad ? -20 : -40)
						}
				}
				.ignoresSafeArea(edges: .bottom)
			}

			.toolbar {
				NBToolbarButton(role: .dismiss)
				ToolbarItem(placement: .principal) {
					Image("Glyph")
						.resizable()
						.scaledToFit()
						.frame(height: 38)
				}
				NBToolbarButton(
					.localized("Reset"),
					style: .text,
					placement: .topBarTrailing
				) {
					_temporaryOptions = OptionsManager.shared.options
					appIcon = nil
					_idEditedByUser = false
					_applyQuillDefaults()
					_applyAutoIdentifier()
				}
			}
			.sheet(isPresented: $_isAltPickerPresenting) { SigningAlternativeIconView(app: app, appIcon: $appIcon, isModifing: .constant(true)) }
			.sheet(isPresented: $_isFilePickerPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.image],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self.appIcon = UIImage.fromFile(selectedFileURL)?.resizeToSquare()
					}
				)
				.ignoresSafeArea()
			}
			.photosPicker(isPresented: $_isImagePickerPresenting, selection: $_selectedPhoto)
			.onChange(of: _selectedPhoto) { newValue in
				guard let newValue else { return }
				
				Task {
					if let data = try? await newValue.loadTransferable(type: Data.self),
					   let image = UIImage(data: data)?.resizeToSquare() {
						appIcon = image
					}
				}
			}
			.disabled(_isSigning)
			.animation(.smooth, value: _isSigning)
			.onChange(of: _temporaryCertificate) { _ in
				_applyAutoIdentifier()
			}
		}
		.onAppear {
			_applyQuillDefaults()
			_applyAutoIdentifier()
			
			if
				let currentName = app.name,
				let newName = _temporaryOptions.displayNames[currentName]
			{
				_temporaryOptions.appName = newName
			}
		}
	}
}

// MARK: - Extension: bundle ID suggestion
extension SigningView {
	/// Bundle ID from the selected certificate's profile, or nil when it is a wildcard / unreadable.
	private func _profileBundleId() -> String? {
		guard
			let cert = _selectedCert(),
			let url = Storage.shared.getFile(.provision, from: cert)
		else { return nil }
		return CertificateReader(url).decoded?.fixedAppIDBundleID
	}
	
	/// False only when the selected profile is readable and has a fixed (non-wildcard) app ID.
	private func _selectedProfileIsWildcard() -> Bool {
		guard
			let cert = _selectedCert(),
			let url = Storage.shared.getFile(.provision, from: cert),
			let full = CertificateReader(url).decoded?.applicationIdentifier
		else { return true }
		return full.contains("*")
	}
	
	/// Quill itself: default to the installed copy's bundle ID (no PPQ suffix, no mapping), so the
	/// install replaces this app. The user may still change it (e.g. "Use profile ID").
	/// Also used by Reset, so the general options' identifier never applies to Quill.
	private func _applyQuillDefaults() {
		guard app.isQuillItself else { return }
		_temporaryOptions.ppqProtection = false
		_temporaryOptions.appIdentifier = Bundle.main.bundleIdentifier
	}

	/// True when `identifier` is the running Quill's bundle ID while this app is not Quill:
	/// installing it would replace Quill.
	private func _wouldReplaceQuill(_ identifier: String?) -> Bool {
		guard !app.isQuillItself, let identifier, let own = Bundle.main.bundleIdentifier else { return false }
		return sameBundleID(identifier.trimmingCharacters(in: .whitespaces), own)
	}

	/// Layers: profile suggestion, PPQ suffix, then user-defined identifier mappings.
	/// Never touches Quill itself, and never overwrites a manual edit.
	private func _applyAutoIdentifier() {
		guard !app.isQuillItself, !_idEditedByUser else { return }
		
		let ppqActive = _optionsManager.options.ppqProtection && (_selectedCert()?.ppQCheck ?? false)
		_temporaryOptions.appIdentifier = _optionsManager.options.appIdentifier
		_idFromProfile = false
		
		if ppqActive {
			// A fixed profile ID and the PPQ suffix conflict, so PPQ keeps its existing behaviour.
			if let identifier = app.identifier {
				_temporaryOptions.appIdentifier = "\(identifier).\(_optionsManager.options.ppqString)"
			}
		} else if
			_optionsManager.options.autoProfileBundleId,
			let profileId = _profileBundleId(),
			// Never pick Quill's own ID for another app silently: it would replace Quill.
			!_wouldReplaceQuill(profileId)
		{
			_temporaryOptions.appIdentifier = profileId
			_idFromProfile = true
		}
		
		if
			let currentBundleId = app.identifier,
			let newBundleId = _temporaryOptions.identifiers[currentBundleId]
		{
			_temporaryOptions.appIdentifier = newBundleId
			_idFromProfile = false
		}
	}
}

// MARK: - Extension: View
extension SigningView {
	@ViewBuilder
	private func _customizationOptions(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Customization")) {
			Menu {
				Button(.localized("Select Alternative Icon"), systemImage: "app.dashed") { _isAltPickerPresenting = true }
				Button(.localized("Choose from Files"), systemImage: "folder") { _isFilePickerPresenting = true }
				Button(.localized("Choose from Photos"), systemImage: "photo") { _isImagePickerPresenting = true }
			} label: {
				if let icon = appIcon {
					Image(uiImage: icon)
						.appIconStyle()
				} else {
					FRAppIconView(app: app, size: 56)
				}
			}
			
			_infoCell(.localized("Name"), desc: _temporaryOptions.appName ?? app.name) {
				SigningPropertiesView(
					title: .localized("Name"),
					initialValue: _temporaryOptions.appName ?? (app.name ?? ""),
					bindingValue: $_temporaryOptions.appName
				)
			}
			if app.isQuillItself {
				Text(verbatim: String.localized(
					"This is Quill itself. The installed bundle ID (%@) is used by default, so it updates this app in place. Another ID installs a separate copy without your data.",
					arguments: Bundle.main.bundleIdentifier ?? "-"
				))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			_infoCell(.localized("Identifier"), desc: _temporaryOptions.appIdentifier ?? app.identifier) {
				SigningPropertiesView(
					title: .localized("Identifier"),
					initialValue: _temporaryOptions.appIdentifier ?? (app.identifier ?? ""),
					bindingValue: Binding(
						get: { _temporaryOptions.appIdentifier },
						set: {
							_temporaryOptions.appIdentifier = $0
							_idEditedByUser = true
							_idFromProfile = false
						}
					)
				)
			}
			if _idFromProfile {
				Text(.localized("From provisioning profile"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			} else if let profileId = _profileBundleId() {
				Text(verbatim: String.localized("This profile is only valid for the %@ identifier.", arguments: profileId))
					.font(.footnote)
					.foregroundStyle(.secondary)
				if _temporaryOptions.appIdentifier != profileId, !_wouldReplaceQuill(profileId) {
					Button(.localized("Use profile ID")) {
						_temporaryOptions.appIdentifier = profileId
						_idEditedByUser = true
						_idFromProfile = true
					}
				}
			}
			if _wouldReplaceQuill(_temporaryOptions.appIdentifier) {
				Label(.localized("This is Quill's bundle ID: installing this app replaces Quill and deletes its data."), systemImage: "exclamationmark.triangle.fill")
					.font(.footnote)
					.foregroundStyle(.red)
			}
			_infoCell(.localized("Version"), desc: _temporaryOptions.appVersion ?? app.version) {
				SigningPropertiesView(
					title: .localized("Version"),
					initialValue: _temporaryOptions.appVersion ?? (app.version ?? ""),
					bindingValue: $_temporaryOptions.appVersion
				)
			}
		}
	}
	
	@ViewBuilder
	private func _cert() -> some View {
		NBSection(.localized("Signing")) {
			if let cert = _selectedCert() {
				NavigationLink {
					CertificatesView(selectedCert: $_temporaryCertificate)
				} label: {
					CertificatesCellView(
						cert: cert
					)
				}
			} else {
				Text(.localized("No Certificate"))
					.font(.footnote)
					.foregroundColor(.disabled())
			}
		}
	}
	
	@ViewBuilder
	private func _customizationProperties(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Advanced")) {
			DisclosureGroup(.localized("Modify")) {
				NavigationLink(.localized("Existing Dylibs")) {
					SigningDylibView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
				
				NavigationLink(.localized("Frameworks & PlugIns")) {
					SigningFrameworksView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
			
				NavigationLink(.localized("Entitlements") + " (BETA)") {
					SigningEntitlementsView(
						bindingValue: $_temporaryOptions.appEntitlementsFile
					)
				}
				
				NavigationLink(.localized("Tweaks")) {
					SigningTweaksView(
						options: $_temporaryOptions
					)
				}
			}
			
			NavigationLink(.localized("Properties")) {
				Form { SigningOptionsView(
					options: $_temporaryOptions,
					temporaryOptions: _optionsManager.options,
					isWildcardProfile: _selectedProfileIsWildcard()
				)}
				.navigationTitle(.localized("Properties"))
			}
		}
	}
	
	@ViewBuilder
	private func _infoCell<V: View>(_ title: String, desc: String?, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			LabeledContent(title) {
				Text(desc ?? .localized("Unknown"))
			}
		}
	}
}

// MARK: - Extension: View (import)
extension SigningView {
	private func _start() {
		guard
			_selectedCert() != nil || _temporaryOptions.signingOption != .default
		else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate"),
				isCancel: true
			)
			return
		}

		if
			_temporaryOptions.signingOption == .default,
			let cert = _selectedCert(),
			cert.isPasswordMissing
		{
			UIAlertController.showAlertWithOk(
				title: .localized("Password Missing"),
				message: Storage.missingPasswordMessage,
				isCancel: true
			)
			return
		}

		// Make sure the certificate belongs to its provisioning profile before signing.
		if
			_temporaryOptions.signingOption == .default,
			let cert = _selectedCert(),
			let p12URL = Storage.shared.getFile(.certificate, from: cert),
			let provisionURL = Storage.shared.getFile(.provision, from: cert)
		{
			_isChecking = true
			CertificatePairValidator.check(
				p12URL: p12URL,
				password: cert.resolvedPassword,
				provisionURL: provisionURL,
				continueTitle: .localized("Sign Anyway"),
				proceed: { _isChecking = false; _beginSigning() },
				cancel: { _isChecking = false }
			)
			return
		}
		
		_beginSigning()
	}
	
	private func _beginSigning() {
		let generator = UIImpactFeedbackGenerator(style: .light)
		generator.impactOccurred()
		_isSigning = true
		
		// Only for this signing: Quill itself never gets a PPQ suffix; without a chosen ID it keeps
		// the installed copy's bundle ID (the release IPA itself carries "app.quill.sign").
		if app.isQuillItself {
			_temporaryOptions.ppqProtection = false
			if (_temporaryOptions.appIdentifier ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
				_temporaryOptions.appIdentifier = Bundle.main.bundleIdentifier
			}
		}
		
		FR.signPackageFile(
			app,
			using: _temporaryOptions,
			icon: appIcon,
			certificate: _selectedCert()
		) { error in
			if let error {
				let ok = UIAlertAction(title: .localized("Dismiss"), style: .cancel) { _ in
					dismiss()
				}
				
				UIAlertController.showAlert(
					title: "Error",
					message: ErrorExplainer.message(for: error),
					actions: [ok]
				)
			} else {
				if
					_temporaryOptions.post_deleteAppAfterSigned,
					!app.isSigned
				{
					Storage.shared.deleteApp(for: app)
				}
				
				if _temporaryOptions.post_installAppAfterSigned {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
						NotificationCenter.default.post(name: Notification.Name("Quill.installApp"), object: nil, userInfo: ["deleteSignedAfterInstall": _temporaryOptions.post_deleteSignedAfterInstall])
					}
				}
				dismiss()
			}
		}
	}
}
