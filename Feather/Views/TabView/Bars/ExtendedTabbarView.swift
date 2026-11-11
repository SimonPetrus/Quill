//
//  TabbarController.swift
//  feather
//
//  Created by samara on 5/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import SwiftUI
import NukeUI

@available(iOS 18, *)
struct ExtendedTabbarView: View {
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@AppStorage("Quill.tabCustomization") var customization = TabViewCustomization()
	@StateObject var viewModel = SourcesViewModel.shared
	@ObservedObject private var _router = TabRouter.shared
	/// Holds every tab value (tab raw values, "all-repositories", "source.<id>").
	@State private var _selectedTab: String = TabEnum.sources.rawValue
	
	@State private var _isAddingPresenting = false
	@State private var _lastRequest: UUID?
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
		
	var body: some View {
		TabView(selection: $_selectedTab) {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				Tab(tab.title, systemImage: tab.icon, value: tab.rawValue) {
					TabEnum.view(for: tab)
				}
			}
			
			ForEach(TabEnum.customizableTabs, id: \.hashValue) { tab in
				Tab(tab.title, systemImage: tab.icon, value: tab.rawValue) {
					TabEnum.view(for: tab)
				}
				.customizationID("tab.\(tab.rawValue)")
				.defaultVisibility(.hidden, for: .tabBar)
				.customizationBehavior(.reorderable, for: .tabBar, .sidebar)
				.hidden(horizontalSizeClass == .compact)
			}
			
			TabSection("Sources") {
				Tab(.localized("All Repositories"), systemImage: "globe.desk", value: "all-repositories") {
					NavigationStack {
						SourceAppsView(object: Array(_sources), viewModel: viewModel)
					}
				}
				
				ForEach(_sources, id: \.identifier) { source in
					Tab(value: "source.\(source.identifier ?? "")") {
						NavigationStack {
							SourceAppsView(object: [source], viewModel: viewModel)
						}
					} label: {
						_icon(source.name ?? .localized("Unknown"), iconUrl: source.iconURL)
					}
					.swipeActions {
						Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
							Storage.shared.deleteSource(for: source)
						}
					}
				}
			}
			.sectionActions {
				Button(.localized("Add Source"), systemImage: "plus") {
					_isAddingPresenting = true
				}
			}
			.defaultVisibility(.hidden, for: .tabBar)
			.hidden(horizontalSizeClass == .compact)
		}
		.tabViewStyle(.sidebarAdaptable)
		// onReceive also delivers the current value on subscription (notification tapped on a cold launch).
		.onReceive(_router.$openLibraryRequest) { request in
			guard let request, request != _lastRequest else { return }
			_lastRequest = request
			_selectedTab = TabEnum.library.rawValue
		}
		.onChange(of: _sources.map { $0.identifier ?? "" }) { _ in _validateSelection() }
		.onChange(of: horizontalSizeClass) { _ in _validateSelection() }
		.tabViewCustomization($customization)
		.sheet(isPresented: $_isAddingPresenting) {
			SourcesAddView()
				.presentationDetents([.medium])
		}
	}
	
	/// Falls back to Sources when the selected tab no longer exists (source deleted) or is hidden
	/// (compact width hides the sidebar-only tabs).
	private func _validateSelection() {
		let compact = horizontalSizeClass == .compact
		let value = _selectedTab
		let isValid: Bool
		if TabEnum.defaultTabs.contains(where: { $0.rawValue == value }) {
			isValid = true
		} else if TabEnum.customizableTabs.contains(where: { $0.rawValue == value }) {
			isValid = !compact
		} else if value == "all-repositories" {
			isValid = !compact
		} else if value.hasPrefix("source.") {
			let id = String(value.dropFirst("source.".count))
			isValid = !compact && _sources.contains(where: { ($0.identifier ?? "") == id })
		} else {
			isValid = false
		}
		if !isValid { _selectedTab = TabEnum.sources.rawValue }
	}
	
	@ViewBuilder
	private func _icon(_ title: String, iconUrl: URL?) -> some View {
		Label {
			Text(title)
		} icon: {
			if let iconURL = iconUrl {
				LazyImage(url: iconURL) { state in
					if let image = state.image {
						image
					} else {
						standardIcon
					}
				}
				.processors([.resize(width: 14), .circle()])
			} else {
				standardIcon
			}
		}
	}

	
	var standardIcon: some View {
		Image(systemName: "app.dashed")
	}
}

