//
//  VersionHistoryView.swift
//  Feather
//
//  Created by Nagata Asami on 27/7/25.
//

import SwiftUI
import AltSourceKit

// MARK: - VersionHistoryView
struct VersionHistoryView: View {
	@Environment(\.dismiss) var dismiss
	
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App
	let versions: [ASRepository.App.Version]
	/// Set when opened from the library: rows become tappable and the installed version is marked.
	var installedVersion: String? = nil
	var isPicking: Bool { installedVersion != nil }
	
	private func _download(_ version: ASRepository.App.Version) {
		guard let downloadURL = version.downloadURL else { return }
		_ = DownloadManager.shared.startDownload(
			from: downloadURL,
			id: app.currentUniqueId,
			sourceProvenance: SourceAppProvenance(
				sourceURL: sourceURL,
				repository: source,
				app: app,
				version: version
			)
		)
		dismiss()
	}
    
	var body: some View {
		ScrollView {
			LazyVStack(spacing: 12) {
				ForEach(versions) { version in
					AppVersionInfo(
						version: version.version,
						date: version.date?.date,
						description: version.localizedDescription ?? .localized("No release notes available"),
						size: version.size,
						isInstalled: isPicking && version.version == installedVersion
					)
					.padding(.horizontal)
					.background(Color(.systemBackground))
					.contentShape(Rectangle())
					.onTapGesture {
						if isPicking { _download(version) }
					}
					.contextMenu {
						if let downloadURL = version.downloadURL {
							Button {
								_download(version)
							} label: {
								Label(version.version, systemImage: "arrow.down")
							}
                            
							Button {
								UIPasteboard.general.string = downloadURL.absoluteString
							} label: {
								Label(.localized("Copy Download URL"), systemImage: "doc.on.clipboard")
							}
						}
					}
                    
					Divider().padding(.horizontal)
				}
			}
			.padding(.top, 8)
		}
	}
}
