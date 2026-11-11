//
//  TabbarView.swift
//  feather
//
//  Created by samara on 23.03.2025.
//

import SwiftUI

struct TabbarView: View {
	@ObservedObject private var _router = TabRouter.shared
	@State private var _selectedTab: TabEnum = .sources
	@State private var _lastRequest: UUID?

	var body: some View {
		TabView(selection: $_selectedTab) {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				TabEnum.view(for: tab)
					.tabItem {
						Label(tab.title, systemImage: tab.icon)
					}
					.tag(tab)
			}
		}
		// onReceive also delivers the current value on subscription (notification tapped on a cold launch).
		.onReceive(_router.$openLibraryRequest) { request in
			guard let request, request != _lastRequest else { return }
			_lastRequest = request
			_selectedTab = .library
		}
	}
}
