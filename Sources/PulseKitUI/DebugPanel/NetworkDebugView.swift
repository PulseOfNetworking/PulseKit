// Sources/PulseKitUI/DebugPanel/NetworkDebugView.swift
//  PulseKit
//
//  Created by Pulse


import SwiftUI
import Combine

// MARK: - NetworkDebugView

/// A SwiftUI overlay that renders a live network log and metrics dashboard.
///
/// Add it as an overlay in your root view during development:
/// ```swift
/// ContentView()
///     .overlay(alignment: .bottomTrailing) {
///         NetworkDebugView(coordinator: pulseClient.observability)
///     }
/// ```
@available(iOS 16.0, macOS 13.0, *)
public struct NetworkDebugView: View {

    @StateObject private var viewModel: NetworkDebugViewModel
    @State private var isExpanded = false
    @State private var selectedTab: Tab = .logs

    public init(coordinator: ObservabilityCoordinator) {
        _viewModel = StateObject(wrappedValue: NetworkDebugViewModel(coordinator: coordinator))
    }

    private enum Tab: String, CaseIterable {
        case logs    = "Logs"
        case metrics = "Metrics"
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isExpanded {
                panelView
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            toggleButton
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
    }

    // MARK: - Toggle Button

    private var toggleButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: 50, height: 50)
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)

                VStack(spacing: 1) {
                    Image(systemName: "network")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.green)
                    if viewModel.recentErrorCount > 0 {
                        Text("\(viewModel.recentErrorCount)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .padding(16)
    }

    // MARK: - Panel

    private var panelView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("PulseKit Inspector", systemImage: "network")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button { viewModel.clearLogs() } label: {
                    Image(systemName: "trash").foregroundColor(.gray)
                }
                Button { isExpanded = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(white: 0.12))

            // Tab Bar
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(10)
            .background(Color(white: 0.1))

            Divider().background(Color.gray.opacity(0.3))

            // Content
            switch selectedTab {
            case .logs:    logsView
            case .metrics: metricsView
            }
        }
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 20)
        .frame(width: 380, height: 520)
        .padding(16)
    }

    // MARK: - Logs Tab

    private var logsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.events.indices, id: \.self) { index in
                        EventRow(event: viewModel.events[index])
                            .id(index)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: viewModel.events.count) { _ in
                if let last = viewModel.events.indices.last {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Metrics Tab

    private var metricsView: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Summary cards
                HStack(spacing: 10) {
                    MetricCard(title: "Requests", value: "\(viewModel.totalRequests)", color: .blue)
                    MetricCard(title: "Errors", value: "\(viewModel.totalErrors)", color: .red)
                    MetricCard(title: "Cached", value: "\(viewModel.cacheHits)", color: .green)
                }
                .padding(.horizontal, 10)

                Divider().background(Color.gray.opacity(0.3))

                // Per-endpoint stats
                ForEach(viewModel.endpointStats, id: \.endpoint) { stats in
                    EndpointStatRow(stats: stats)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - EventRow

@available(iOS 16.0, macOS 13.0, *)
private struct EventRow: View {
    let event: NetworkEvent

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(icon)
                .font(.system(size: 11))
                .frame(width: 16)
            Text(event.label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(labelColor)
                .lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private var icon: String {
        switch event {
        case .requestSent:          return "→"
        case .responseReceived(let r): return r.isSuccess ? "✓" : "✗"
        case .requestFailed:        return "✗"
        case .cacheHit:             return "⚡"
        case .requestRetrying:      return "↩"
        case .connectivityChanged:  return "📶"
        default:                    return "·"
        }
    }

    private var labelColor: Color {
        switch event {
        case .requestFailed:        return .red
        case .responseReceived(let r): return r.isSuccess ? .green : .orange
        case .cacheHit:             return Color(red: 0.4, green: 0.8, blue: 1.0)
        case .requestRetrying:      return .yellow
        default:                    return Color(white: 0.75)
        }
    }
}

// MARK: - MetricCard

@available(iOS 16.0, macOS 13.0, *)
private struct MetricCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - EndpointStatRow

@available(iOS 16.0, macOS 13.0, *)
private struct EndpointStatRow: View {
    let stats: EndpointStat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stats.endpoint)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
            HStack(spacing: 14) {
                Label("\(stats.count) req", systemImage: "arrow.up.arrow.down")
                Label(String(format: "%.0fms avg", stats.avgLatencyMs), systemImage: "clock")
                Label(String(format: "%.0f%% err", stats.errorRate * 100), systemImage: "exclamationmark.circle")
                    .foregroundColor(stats.errorRate > 0.1 ? .red : .gray)
            }
            .font(.system(size: 10))
            .foregroundColor(.gray)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - ViewModel

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class NetworkDebugViewModel: ObservableObject {

    @Published var events: [NetworkEvent] = []
    @Published var endpointStats: [EndpointStat] = []

    var totalRequests: Int { events.filter { if case .requestSent = $0 { return true }; return false }.count }
    var totalErrors: Int   { events.filter { if case .requestFailed = $0 { return true }; return false }.count }
    var cacheHits: Int     { events.filter { if case .cacheHit = $0 { return true }; return false }.count }
    var recentErrorCount: Int { totalErrors }

    private let coordinator: ObservabilityCoordinator
    private var pollTask: Task<Void, Never>?

    init(coordinator: ObservabilityCoordinator) {
        self.coordinator = coordinator
        startPolling()
    }

    func clearLogs() { events.removeAll() }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let fresh = await self.coordinator.recentEvents(limit: 200)
                await MainActor.run {
                    self.events = fresh.reversed()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s poll
            }
        }
    }
}

// MARK: - EndpointStat

struct EndpointStat: Identifiable {
    let id = UUID()
    let endpoint: String
    let count: Int
    let avgLatencyMs: Double
    let errorRate: Double
}
