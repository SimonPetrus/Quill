//
//  AppVersionInfo.swift
//  Feather
//
//  Created by Nagata Asami on 27/7/25.
//

import SwiftUI

struct AppVersionInfo: View {
	let version: String
	let date: Date?
	let description: String
	let size: UInt?
	let isInstalled: Bool
    
	init(
		version: String,
		date: Date? = nil,
		description: String,
		size: UInt? = nil,
		isInstalled: Bool = false
	) {
		self.version = version
		self.date = date
		self.description = description
		self.size = size
		self.isInstalled = isInstalled
	}
    
	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack {
				Text("Version \(version)")
					.font(.subheadline)
					.foregroundStyle(.secondary)
                
				if isInstalled {
					Text(.localized("Installed"))
						.font(.caption.weight(.semibold))
						.foregroundStyle(Color.accentColor)
				}
                
				Spacer()
                
				if let size {
					Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}
                
				if let date {
					Text(date.formatted(.relative(presentation: .named)))
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}
			}
			.padding(.vertical, 4)
            
			ExpandableText(text: description, lineLimit: 3)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
} 
