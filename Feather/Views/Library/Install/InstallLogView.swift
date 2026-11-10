//
//  InstallLogView.swift
//  Feather
//
//  Shows the in-memory log of the last install server (Fully Local diagnostics).
//

import SwiftUI
import NimbleViews

// MARK: - View
struct InstallLogView: View {
	@ObservedObject private var _log = InstallServerLog.shared

	// MARK: Body
	var body: some View {
		let lines = _log.lines

		ScrollViewReader { proxy in
			ScrollView {
				if lines.isEmpty {
					Text(.localized("No log entries yet."))
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .center)
						.padding()
				} else {
					Text(lines.joined(separator: "\n"))
						.font(.system(.caption2, design: .monospaced))
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding()
						.id("bottom")
				}
			}
			.onAppear {
				proxy.scrollTo("bottom", anchor: .bottom)
			}
			.onChange(of: lines.count) { _ in
				proxy.scrollTo("bottom", anchor: .bottom)
			}
		}
		.navigationTitle(.localized("Install Log"))
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			NBToolbarButton(
				.localized("Copy"),
				systemImage: "doc.on.doc",
				style: .text,
				placement: .confirmationAction,
				isDisabled: lines.isEmpty
			) {
				UIPasteboard.general.string = _log.text
			}
		}
	}
}

// MARK: - Sheet
/// Standalone presentation (install screen) with its own navigation stack and close button.
struct InstallLogSheetView: View {
	var body: some View {
		NBNavigationView(.localized("Install Log"), displayMode: .inline) {
			InstallLogView()
				.toolbar {
					NBToolbarButton(role: .cancel)
				}
		}
	}
}
