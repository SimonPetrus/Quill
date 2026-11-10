//
//  AboutView.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct AboutView: View {
	// MARK: Body
	var body: some View {
		NBList(.localized("About")) {
			Section {
				VStack {
					FRAppIconView(size: 72)
					
					Text(Bundle.main.name)
						.font(.largeTitle)
						.bold()
						.foregroundStyle(Color.accentColor)
					
					HStack(spacing: 4) {
						Text(.localized("Version"))
						Text(Bundle.main.version)
					}
					.font(.footnote)
					.foregroundStyle(.secondary)
				}
			}
			.frame(maxWidth: .infinity)
			.listRowBackground(EmptyView())
			
			NBSection(.localized("Credits")) {
				Label("SP", systemImage: "person.crop.circle")
			}
			
			Section {
				Text(.localized("Based on Feather (GPL-3.0)."))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .center)
			}
		}
	}
}
