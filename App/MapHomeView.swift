import SwiftUI
import MapKit
import NetworkExtension
import Network

/// 诊断面板用:把 NEVPNStatus 映射成可读字符串(带 rawValue)。
private extension NEVPNStatus {
    var diagDesc: String {
        switch self {
        case .invalid: return "invalid(0)"
        case .disconnected: return "disconnected(1)"
        case .connecting: return "connecting(2)"
        case .connected: return "connected(3)"
        case .reasserting: return "reasserting(4)"
        case .disconnecting: return "disconnecting(5)"
        @unknown default: return "unknown"
        }
    }
}

/// App 启动时单次定位用户真实位置(GCJ-02 在中国大陆,iOS 自动偏移)。
/// 拿到位置就调 onLocation 回调,失败/拒权默默忽略,保持地图默认区域。
private final class LocationFetcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onLocation: ((CLLocationCoordinate2D) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestOneShot() {
        manager.requestWhenInUseAuthorization()
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break  // 等 locationManagerDidChangeAuthorization 触发
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async {
            self.onLocation?(loc.coordinate)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 失败默默忽略,保持默认地图区域
    }
}

/// 包装 MKLocalSearchCompleter 做搜索框实时输入联想。
/// completer 回调默认主线程,@Published 更新走 main async 保险。
private final class SearchCompleterHelper: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    @Published var results: [MKLocalSearchCompletion] = []

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    func updateQuery(_ fragment: String) {
        if fragment.isEmpty {
            results = []
            return
        }
        completer.queryFragment = fragment
    }

    func clear() {
        results = []
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        DispatchQueue.main.async {
            self.results = completer.results
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.results = []
        }
    }
}

struct MapHomeView: View {
    @State private var mapSelection: MapSelection<MKMapItem>?
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    )
    @State private var searchText: String = ""
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var selectedLocationName: String?
    @State private var showLocationSheet = false
    @State private var showRestartLocationGuide = false
    @State private var showDisableGuide = false
    @State private var showRestartPhoneGuide = false
    @State private var currentLocationName: String = UserDefaults.standard.string(forKey: "currentLocationName") ?? ""
    @State private var vpnConnected: Bool = false
    @State private var vpnStatus: NEVPNStatus = .invalid
    @State private var savedLocations: [SavedLocation] = []
    @State private var recentLocations: [SavedLocation] = []
    @State private var showFavoritesSheet = false
    @State private var showSettings = false
    @State private var spoofingState: SpoofingState = .off
    @State private var justFavorited: Bool = false
    @State private var lastErrorReason: String = ""
    @State private var isSpoofing: Bool = false
    @StateObject private var locationFetcher = LocationFetcher()
    @StateObject private var searchCompleter = SearchCompleterHelper()
    @State private var spoofedDisplayCoord: CLLocationCoordinate2D? = nil
    @State private var lastKnownUserCoord: CLLocationCoordinate2D? = nil
    @State private var realUserCoord: CLLocationCoordinate2D? = nil

    @State private var locationSheetHeight: CGFloat = 220

    var body: some View {
        ZStack {
            // 全屏地图
            MapReader { proxy in
                Map(position: $cameraPosition, selection: $mapSelection) {
                    if let coord = selectedCoordinate {
                        Marker("Target Location", coordinate: coord)
                            .tint(.red)
                    }
                    UserAnnotation()
                }
                .mapStyle(.standard(pointsOfInterest: .all))
                .mapFeatureSelectionAccessory(.automatic)
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .ignoresSafeArea()
                .onTapGesture(coordinateSpace: .global) { tapLocation in
                    // 空白点击才取坐标(POI 内置选中由 selection 绑定处理)
                    if let coordinate = proxy.convert(tapLocation, from: .global) {
                        selectCoordinate(coordinate)
                    }
                }
                .onChange(of: mapSelection) { _, newSelection in
                    handleMapSelection(newSelection)
                }
            }

            // 底部叠层:右下角"回到我的位置"按钮 + 底部卡片
            VStack(spacing: 0) {
                Spacer()
                HStack {
                    Spacer()
                    if let userCoord = lastKnownUserCoord {
                        Button {
                            withAnimation {
                                cameraPosition = .region(MKCoordinateRegion(
                                    center: userCoord,
                                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                                ))
                            }
                        } label: {
                            Image(systemName: "location.fill")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                        }
                        .accessibilityLabel(isSpoofActive ? "Show spoofed location" : "Show my location")
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 8)

                bottomCard
            }
        }
        .sheet(isPresented: $showLocationSheet) {
            locationSheet
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { locationSheetHeight = $0 }
                .presentationDetents([.height(locationSheetHeight)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showRestartLocationGuide) {
            restartLocationGuide
                // Dismissing by swipe would skip the Done handler and strand the state in .pending.
                .interactiveDismissDisabled()
        }
        .alert("Turn Off Spoofing?", isPresented: $showDisableGuide) {
            Button("Cancel", role: .cancel) { }
            Button("Turn Off", role: .destructive) {
                disableSpoofing()
            }
        } message: {
            Text("After turning off, restart Location Services once to get your real location back.")
        }
        .sheet(isPresented: $showRestartPhoneGuide) {
            disableRestartGuide
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showFavoritesSheet) {
            favoritesSheet
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            refreshVPNStatus()
        }
        .onAppear {
            refreshVPNStatus()
            loadSavedLocations()
            loadRecentLocations()
            // 启动时单次定位到用户真实位置,移地图镜头过去(失败/拒权保持默认)
            locationFetcher.onLocation = { coord in
                lastKnownUserCoord = coord
                realUserCoord = coord
                withAnimation {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    ))
                }
            }
            locationFetcher.requestOneShot()
            // 根据当前数据恢复 spoofingState
            let savedName = UserDefaults.standard.string(forKey: "currentLocationName") ?? ""
            spoofingState = (!savedName.isEmpty && vpnConnected) ? .on(name: savedName) : .off
        }
    }

    private var isSpoofActive: Bool {
        if case .on = spoofingState { return true }
        return false
    }

    // MARK: - 子视图

    // 底部卡片:搜索栏 + 输入联想 + 状态信息 + 主操作。
    private var bottomCard: some View {
        VStack(spacing: 12) {
            searchBar
            if !searchCompleter.results.isEmpty && !searchText.isEmpty {
                suggestionsList
            }
            statusSection
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                .fill(.regularMaterial)
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.1), radius: 8, y: -4)
        }
    }

    // 搜索联想列表
    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(searchCompleter.results.prefix(5).enumerated()), id: \.element) { index, completion in
                if index > 0 { Divider().padding(.leading, 44) }
                Button(action: { selectCompletion(completion) }) {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(completion.title)
                                .foregroundStyle(.primary)
                            if !completion.subtitle.isEmpty {
                                Text(completion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    // 状态信息(图标+文案)+ 主操作(.on 关闭定位 / .failed 重试)
    private var statusSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: spoofingState.symbolName)
                    .font(.title3)
                    .foregroundStyle(spoofingState.tint)
                    .frame(width: 28)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(spoofingState.primaryText)
                        .font(.headline)
                        .lineLimit(2)
                    if let sub = spoofingState.subText {
                        Text(sub)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if case .on = spoofingState {
                Button(role: .destructive) { showDisableGuide = true } label: {
                    Text("Turn Off Spoofing").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else if case .failed = spoofingState {
                Button { spoofingState = .off } label: {
                    Text("Dismiss").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 16)
        .animation(.default, value: spoofingState)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search for a place", text: $searchText)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { performSearch() }
                    .onChange(of: searchText) { _, new in searchCompleter.updateQuery(new) }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))

            circleToolbarButton(systemImage: "star", label: "Saved locations") {
                showFavoritesSheet = true
            }
            circleToolbarButton(systemImage: "gearshape", label: "Settings") {
                showSettings = true
            }
        }
        .padding(.horizontal, 16)
    }

    private func circleToolbarButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(Color(uiColor: .tertiarySystemFill), in: Circle())
        }
        .accessibilityLabel(label)
    }

    private var locationSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    if let name = selectedLocationName {
                        Text(name)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Looking up address…")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    if let coord = selectedCoordinate {
                        Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                Button(action: { addCurrentSelectionToFavorites() }) {
                    Label(justFavorited ? "Saved" : "Save",
                          systemImage: justFavorited ? "checkmark" : "star")
                        .frame(maxWidth: .infinity)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.bordered)
                .tint(justFavorited ? .green : .accentColor)
                .disabled(justFavorited || selectedLocationName == nil)
                .sensoryFeedback(.success, trigger: justFavorited) { _, new in new }

                PrimaryButton(title: isSpoofing ? "Activating…" : "Use This Location", isBusy: isSpoofing) {
                    setAsLocation()
                }
                .layoutPriority(1)
            }
            .controlSize(.large)
        }
        .padding(20)
        .padding(.top, 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let restartLocationSteps = [
        "Open the Settings app",
        "Tap Privacy & Security",
        "Tap Location Services",
        "Turn Location Services off",
        "Wait about 3 seconds",
        "Turn Location Services back on",
    ]

    private func restartGuide(title: String, subtitle: String, onDone: @escaping () -> Void) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    NumberedSteps(steps: Self.restartLocationSteps, emphasized: [4])
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Done", action: onDone)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var restartLocationGuide: some View {
        restartGuide(
            title: "One Last Step",
            subtitle: "Restart Location Services so iOS picks up the new location."
        ) {
            showRestartLocationGuide = false
            // pending → on
            let name = UserDefaults.standard.string(forKey: "currentLocationName") ?? ""
            DiagLog.add("User tapped [Done]: name=\(name), state→on, will stop VPN")
            if !name.isEmpty {
                spoofingState = .on(name: name)
                // 镜头移到伪装位置,用户直观看到"已生效"
                if let target = spoofedDisplayCoord {
                    lastKnownUserCoord = target  // 让"回到我的位置"按钮跳到伪装坐标
                    withAnimation {
                        cameraPosition = .region(MKCoordinateRegion(
                            center: target,
                            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                        ))
                    }
                }
            }
            // 定位已进系统缓存焊死,关 VPN 恢复全手机网络;伪装位置由 iOS 缓存维持,不受影响。
            // 状态卡 .on 独立于 vpnConnected(全局观察者只刷 vpnStatus/vpnConnected,不重置 spoofingState)。
            ContentView.vpnManager?.connection.stopVPNTunnel()
        }
    }

    private var disableRestartGuide: some View {
        restartGuide(
            title: "Spoofing Turned Off",
            subtitle: "Restart Location Services to get your real location back."
        ) {
            showRestartPhoneGuide = false
            spoofingState = .off
        }
    }

    private var favoritesSheet: some View {
        NavigationStack {
            List {
                // 最近使用
                if !recentLocations.isEmpty {
                    Section("Recent") {
                        ForEach(recentLocations) { saved in
                            Button(action: { selectFavorite(saved) }) {
                                favoriteRow(saved: saved, iconName: "clock.fill", iconColor: .gray)
                            }
                        }
                    }
                }

                // 我的收藏
                Section("Favorites") {
                    if savedLocations.isEmpty {
                        ContentUnavailableView(
                            "No Favorites Yet",
                            systemImage: "star",
                            description: Text("Tap Save on a location to keep it here.")
                        )
                    } else {
                        ForEach(savedLocations) { saved in
                            Button(action: { selectFavorite(saved) }) {
                                favoriteRow(saved: saved, iconName: "star.fill", iconColor: .orange)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteFavorite(saved)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Saved Locations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showFavoritesSheet = false }
                }
            }
        }
    }

    @ViewBuilder
    private func favoriteRow(saved: SavedLocation, iconName: String, iconColor: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.name)
                    .foregroundStyle(.primary)
                Text(String(format: "%.4f, %.4f", saved.latitude, saved.longitude))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    // MARK: - 动作

    private func selectCoordinate(_ coordinate: CLLocationCoordinate2D) {
        selectedCoordinate = coordinate
        selectedLocationName = nil
        showLocationSheet = true

        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            if let placemark = placemarks?.first {
                let name = [placemark.name, placemark.locality, placemark.country]
                    .compactMap { $0 }
                    .joined(separator: ", ")
                DispatchQueue.main.async {
                    self.selectedLocationName = name.isEmpty ? "Unknown location" : name
                }
            }
        }
    }

    private func handleMapSelection(_ selection: MapSelection<MKMapItem>?) {
        guard let selection else { return }

        // 自定义 Marker 走 .value;POI 走 .feature
        if let mapItem = selection.value {
            applyMapItem(mapItem)
            return
        }
        guard let feature = selection.feature else { return }

        // POI:用 MKMapItemRequest 异步换成 MKMapItem,取 name + coordinate
        Task { @MainActor in
            do {
                let mapItem = try await MKMapItemRequest(feature: feature).mapItem
                applyMapItem(mapItem)
            } catch {
                // 兜底:直接用 feature 自带字段
                applySelectedLocation(
                    name: feature.title ?? "Unknown place",
                    coordinate: feature.coordinate
                )
            }
        }
    }

    private func applyMapItem(_ mapItem: MKMapItem) {
        applySelectedLocation(
            name: mapItem.name ?? "Unknown place",
            coordinate: mapItem.placemark.coordinate
        )
    }

    private func applySelectedLocation(name: String, coordinate: CLLocationCoordinate2D) {
        selectedCoordinate = coordinate
        selectedLocationName = name
        showLocationSheet = true
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }
    }

    private func performSearch() {
        guard !searchText.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        let search = MKLocalSearch(request: request)
        search.start { response, _ in
            if let item = response?.mapItems.first {
                let coord = item.placemark.coordinate
                DispatchQueue.main.async {
                    self.cameraPosition = .region(MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    ))
                    self.selectedCoordinate = coord
                    self.selectedLocationName = item.name
                    self.showLocationSheet = true
                }
            }
        }
    }

    /// 用户从联想列表选中某条 → 用 MKLocalSearch 解析成 MKMapItem → 移镜头 + 弹位置抽屉。
    /// 选中后清空 searchText 与 completer.results,自然收起联想列表与键盘。
    private func selectCompletion(_ completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        search.start { response, _ in
            guard let item = response?.mapItems.first else { return }
            DispatchQueue.main.async {
                let coord = item.placemark.coordinate
                withAnimation {
                    self.cameraPosition = .region(MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    ))
                }
                self.selectedCoordinate = coord
                self.selectedLocationName = item.name ?? completion.title
                self.showLocationSheet = true
                self.searchText = ""
                self.searchCompleter.clear()
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }

    private func setAsLocation() {
        guard let coord = selectedCoordinate else { return }
        let name = selectedLocationName ?? "Unknown location"
        spoofedDisplayCoord = coord  // GCJ-02 显示坐标,用户点"我已完成"后地图移到这里
        DiagLog.add("Set Location entry: coord=(\(coord.latitude), \(coord.longitude)) name=\(name) vpnConnected=\(vpnConnected) → \(vpnConnected ? "hot-restart" : "cold-start") branch")

        // 进入 pending 状态(尚未生效)
        spoofingState = .pending(name: name, isClosing: false)
        isSpoofing = true

        // GCJ-02 转 WGS-84
        let converted = CoordinateConverter.gcj02ToWgs84(lat: coord.latitude, lng: coord.longitude)
        LocationConfiguration.shared.setCoordinates(latitude: converted.latitude, longitude: converted.longitude)
        UserDefaults.standard.set(name, forKey: "currentLocationName")
        currentLocationName = name
        DiagLog.add("Coordinates written (WGS-84) to LocationConfiguration + UserDefaults")

        // 收藏/最近存原始 GCJ-02 坐标(用于显示和地图回显),设为定位时才在 setAsLocation 内转 WGS-84
        addToRecentLocations(name: name, latitude: coord.latitude, longitude: coord.longitude)

        // 检查 VPN 状态,需要时自动连
        if !vpnConnected {
            connectVPNForSpoofing(expectedLat: converted.latitude, expectedLon: converted.longitude) { success, errorMsg in
                if success {
                    DiagLog.add("[cold-start] connectVPNForSpoofing callback success → close sheet, show tutorial in 1s")
                    // VPN 连上后,弹出"重启定位服务"教学
                    DispatchQueue.main.async {
                        showLocationSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            showRestartLocationGuide = true
                            DiagLog.add("[cold-start] Restart Location Services tutorial shown")
                            isSpoofing = false
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        DiagLog.add("[cold-start] connectVPNForSpoofing callback failure:\(errorMsg ?? "unknown error"))")
                        // 失败,显示具体原因
                        spoofingState = .failed(reason: errorMsg ?? "unknown error")
                        isSpoofing = false
                        showLocationSheet = false
                    }
                }
            }
        } else {
            // VPN 已连:无感重启 tunnel,让 Network Extension 重读新坐标。
            // 临时观察者驱动 stop→等disconnect→start→等connect 两阶段状态机,8 秒超时。
            showLocationSheet = false
            restartVPNForNewCoordinates(expectedLat: converted.latitude, expectedLon: converted.longitude)
        }
    }

    private func loadRecentLocations() {
        if let data = UserDefaults.standard.data(forKey: "recentLocations"),
           let decoded = try? JSONDecoder().decode([SavedLocation].self, from: data) {
            recentLocations = decoded
        }
    }

    private func saveRecentLocations() {
        if let encoded = try? JSONEncoder().encode(recentLocations) {
            UserDefaults.standard.set(encoded, forKey: "recentLocations")
        }
    }

    private func addToRecentLocations(name: String, latitude: Double, longitude: Double) {
        // 去重:相同 name 移到顶部
        recentLocations.removeAll { $0.name == name }
        let new = SavedLocation(name: name, latitude: latitude, longitude: longitude)
        recentLocations.insert(new, at: 0)
        // 限制最多 5 个
        if recentLocations.count > 5 {
            recentLocations = Array(recentLocations.prefix(5))
        }
        saveRecentLocations()
    }

    /// 主动探测 NE Tunnel 进程内 Go 代理 (127.0.0.1:8888) 的 TCP 就绪状态。
    /// 127.0.0.1 在 NEProxySettings 例外清单里(见 Tunnel/PacketTunnelProvider.swift),
    /// 本次 connect 不会被代理拦截,直达 Tunnel 进程的 Go HTTP server。
    /// 轮询每 0.3 秒,单次 connect 超时 1 秒(防 socket 挂在 preparing/waiting),
    /// 总超时由参数控制;探到 .ready → completion(true),否则到总超时 → completion(false)。
    private func probeGoProxyReady(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        DiagLog.add("[probe] Probing Go proxy 127.0.0.1:8888 (timeout \(Int(timeout))s)")

        var attemptCount = 0
        func attempt() {
            attemptCount += 1
            let myAttempt = attemptCount
            let conn = NWConnection(host: "127.0.0.1", port: 8888, using: .tcp)
            var settled = false

            let retryOrFail: () -> Void = {
                if Date() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        attempt()
                    }
                } else {
                    let elapsed = Date().timeIntervalSince(started)
                    DiagLog.add("[probe] Attempt \(myAttempt) timed out, Go readiness probe gave up (\(String(format: "%.2f", elapsed))s)")
                    completion(false)
                }
            }

            conn.stateUpdateHandler = { state in
                guard !settled else { return }
                switch state {
                case .ready:
                    settled = true
                    let elapsed = Date().timeIntervalSince(started)
                    DiagLog.add("[probe] Attempt \(myAttempt) TCP .ready, Go proxy available (\(String(format: "%.2f", elapsed))s)")
                    conn.cancel()
                    completion(true)
                case .failed, .cancelled:
                    settled = true
                    conn.cancel()
                    retryOrFail()
                default:
                    break  // .setup / .waiting / .preparing 等中间态忽略,等 ready/failed/单次超时
                }
            }
            conn.start(queue: .main)

            // 单次 connect 1 秒兜底
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard !settled else { return }
                settled = true
                DiagLog.add("[probe] Attempt \(myAttempt) 1s timeout, retrying")
                conn.cancel()
                retryOrFail()
            }
        }
        attempt()
    }

    /// 通过 NETunnelProviderSession.sendProviderMessage 向 Tunnel 进程查询 Go 代理当前持有的坐标。
    /// Tunnel 协议:发 "getCoords" UTF-8,收 17 字节(1 字节 enabled + 8 字节 lat LE + 8 字节 lon LE)。
    /// 回调在主线程触发;session 不可用或 sendProviderMessage 抛错均回 nil。
    private func queryGoCoordsViaIPC(completion: @escaping ((lat: Double, lon: Double, enabled: Bool)?) -> Void) {
        guard let manager = ContentView.vpnManager,
              let session = manager.connection as? NETunnelProviderSession else {
            DiagLog.add("[IPC] session unavailable (manager nil or connection not NETunnelProviderSession)")
            completion(nil)
            return
        }
        let request = Data("getCoords".utf8)
        do {
            try session.sendProviderMessage(request) { response in
                DispatchQueue.main.async {
                    guard let data = response, data.count == 17 else {
                        completion(nil)
                        return
                    }
                    let enabled = data[0] != 0
                    let lat = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: Double.self) }
                    let lon = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 9, as: Double.self) }
                    completion((lat: lat, lon: lon, enabled: enabled))
                }
            }
        } catch {
            DiagLog.add("[IPC] sendProviderMessage error:\(error.localizedDescription)")
            completion(nil)
        }
    }

    /// 弹"重启定位服务"教学前,确认 Go 已加载新坐标——根治 App Group UserDefaults 跨进程同步竞态。
    /// 循环 IPC 查询 Go 当前持有的坐标,与 expected(WGS-84)做 epsilon (1e-5) 比对。
    /// 匹配 → completion(true);不匹配或 IPC 失败 → 0.3 秒后重试;到总超时仍未匹配 → completion(false)。
    private func confirmCoordsReady(expectedLat: Double, expectedLon: Double, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        DiagLog.add("[confirm] Starting expected=(\(String(format: "%.6f", expectedLat)), \(String(format: "%.6f", expectedLon))) timeout \(Int(timeout))s)")

        var attemptCount = 0
        func attempt() {
            attemptCount += 1
            let myAttempt = attemptCount
            queryGoCoordsViaIPC { result in
                if let r = result {
                    let dLat = abs(r.lat - expectedLat)
                    let dLon = abs(r.lon - expectedLon)
                    if dLat < 1e-5 && dLon < 1e-5 {
                        let elapsed = Date().timeIntervalSince(started)
                        DiagLog.add("[confirm] Attempt \(myAttempt) matched Go=(\(String(format: "%.6f", r.lat)), \(String(format: "%.6f", r.lon))) enabled=\(r.enabled) (\(String(format: "%.2f", elapsed))s)")
                        completion(true)
                        return
                    }
                    DiagLog.add("[confirm] Attempt \(myAttempt) mismatch Go=(\(String(format: "%.6f", r.lat)), \(String(format: "%.6f", r.lon))) dLat=\(String(format: "%.6f", dLat)) dLon=\(String(format: "%.6f", dLon)), retry in 0.3s")
                } else {
                    DiagLog.add("[confirm] Attempt \(myAttempt) IPC failed, retry in 0.3s")
                }
                if Date() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { attempt() }
                } else {
                    let elapsed = Date().timeIntervalSince(started)
                    DiagLog.add("[confirm] Attempt \(myAttempt) timed out, coord confirmation gave up (\(String(format: "%.2f", elapsed))s))")
                    completion(false)
                }
            }
        }
        attempt()
    }

    /// 主动触发 VPN 连接(冷启动场景)。事件驱动等 .connected,然后给 Go 代理一段就绪缓冲再回调。
    /// 复用 RestartState 持有 observer/finished;object: nil 全接收 + 身份过滤;30 秒超时。
    /// 关键:NE status == .connected 不代表 Go 代理 127.0.0.1:8888 已 ListenAndServe,
    /// 所以 .connected 后再延迟 2 秒,确保用户重启定位服务时代理已经能接请求。
    private func connectVPNForSpoofing(expectedLat: Double, expectedLon: Double, completion: @escaping (Bool, String?) -> Void) {
        DiagLog.add("[cold-start] Entering connectVPNForSpoofing")
        DiagLog.add("[cold-start] Preparing VPN config (installAndStartVPN: restart→save→reload→bind)")

        ContentView.installAndStartVPN { result in
            switch result {
            case .failure(let error):
                DiagLog.add("[cold-start] Failed: VPN config prep failed \(error.localizedDescription)")
                completion(false, "VPN config prep failed: \(error.localizedDescription)")
            case .success(let manager):
                DiagLog.add("[cold-start] VPN config ready and enabled, preparing startVPNTunnel")

                let state = RestartState()

                let finish: (Bool, String?) -> Void = { ok, errMsg in
                    guard !state.finished else { return }
                    state.finished = true
                    if let observer = state.observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    if ok {
                        DiagLog.add("[cold-start] VPN connected, starting Go proxy readiness probe (timeout 10s)")
                        probeGoProxyReady(timeout: 10) { ready in
                            if ready {
                                DiagLog.add("[cold-start] Go TCP ready, starting coord confirmation (timeout 15s)")
                                confirmCoordsReady(expectedLat: expectedLat, expectedLon: expectedLon, timeout: 15) { matched in
                                    if matched {
                                        DiagLog.add("[cold-start] Coords confirmed, callback completion(true)")
                                        completion(true, nil)
                                    } else {
                                        DiagLog.add("[cold-start] Coord confirmation timed out, callback completion(false)")
                                        completion(false, "Go proxy ready but coord confirmation timed out, please retry")
                                    }
                                }
                            } else {
                                DiagLog.add("[cold-start] Go TCP readiness probe timed out, callback completion(false)")
                                completion(false, "Go proxy readiness timed out, please retry")
                            }
                        }
                    } else {
                        DiagLog.add("[cold-start] finish failed:\(errMsg ?? "VPN start failed")
                        completion(false, errMsg ?? "VPN start failed")
                    }
                }

                state.observer = NotificationCenter.default.addObserver(
                    forName: .NEVPNStatusDidChange,
                    object: nil,
                    queue: .main
                ) { notification in
                    guard !state.finished else { return }
                    guard let conn = notification.object as? NEVPNConnection,
                          conn === manager.connection else { return }
                    DiagLog.add("[cold-start] Observer received status change: \(manager.connection.status.diagDesc)")
                    switch manager.connection.status {
                    case .connected:
                        finish(true, nil)
                    case .invalid:
                        finish(false, "VPN config invalid, please retry")
                    default:
                        break  // 忽略 .connecting / .disconnecting / .disconnected / .reasserting 中间态
                    }
                }

                // 兜底:进来时已是 .connected(罕见,但不接住会被 30 秒超时拖死)
                if manager.connection.status == .connected {
                    finish(true, nil)
                    return
                }

                do {
                    try manager.connection.startVPNTunnel()
                    DiagLog.add("[cold-start] startVPNTunnel called, waiting for .connected event")
                } catch {
                    finish(false, "VPN start failed: \(error.localizedDescription)")
                    return
                }

                // 30 秒超时(与 restartVPNForNewCoordinates 保持一致)
                DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
                    finish(false, "VPN connection timed out, please retry")
                }
            }
        }
    }

    /// 重连状态持有器:用 class 包住 phase/finished/observer,
    /// 避免 var 被多个 closure 捕获时出现"初始化前捕获"的不稳定写法。
    private final class RestartState {
        var phase = 0
        var finished = false
        var observer: NSObjectProtocol?
    }

    /// VPN 已连状态下切换坐标,需要重启 tunnel 让 NE 重读新坐标。
    /// 用临时独立的 NEVPNStatusDidChange 观察者驱动两阶段状态机:
    /// 阶段0:stopVPNTunnel → 等 .disconnected;阶段1:startVPNTunnel → 等 .connected。
    /// 8 秒超时兜底,RestartState.finished token 防止超时与成功回调冲突。
    /// 整个过程藏在 setAsLocation 已设的 pending 幕布后,成功才弹"重启定位服务"教学。
    private func restartVPNForNewCoordinates(expectedLat: Double, expectedLon: Double) {
        DiagLog.add("[hot-restart] Entering restartVPNForNewCoordinates")
        guard let manager = ContentView.vpnManager else {
            DiagLog.add("[hot-restart] Failed: vpnManager is nil")
            spoofingState = .failed(reason: "VPN config not initialized. Please restart the app.")
            isSpoofing = false
            return
        }

        let state = RestartState()

        let finish: (Bool, String?) -> Void = { ok, errMsg in
            guard !state.finished else { return }
            state.finished = true
            if let observer = state.observer {
                NotificationCenter.default.removeObserver(observer)
            }
            if ok {
                DiagLog.add("[hot-restart] VPN reconnected, starting Go proxy readiness probe (timeout 10s)")
                probeGoProxyReady(timeout: 10) { ready in
                    if ready {
                        DiagLog.add("[hot-restart] Go TCP ready, starting coord confirmation (timeout 15s)")
                        confirmCoordsReady(expectedLat: expectedLat, expectedLon: expectedLon, timeout: 15) { matched in
                            if matched {
                                DiagLog.add("[hot-restart] Coords confirmed, showing restart Location Services tutorial in 0.3s")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showRestartLocationGuide = true
                                    DiagLog.add("[hot-restart] Restart Location Services tutorial shown")
                                    isSpoofing = false
                                }
                            } else {
                                DiagLog.add("[hot-restart] Coord confirmation timed out, setting failed")
                                spoofingState = .failed(reason: "Coordinate confirmation timed out. Please retry.")
                                isSpoofing = false
                            }
                        }
                    } else {
                        DiagLog.add("[hot-restart] Go TCP readiness probe timed out, setting failed")
                        spoofingState = .failed(reason: "Go proxy readiness timed out. Please retry.")
                        isSpoofing = false
                    }
                }
            } else {
                DiagLog.add("[hot-restart] finish failed:\(errMsg ?? "VPN reconnect failed")
                spoofingState = .failed(reason: errMsg ?? "VPN reconnect failed")
                isSpoofing = false
            }
        }

        // object: nil 全接收,closure 内部用 === 身份过滤;
        // 避免真机上因 object 过滤导致收不到 NEVPNStatusDidChange 而一直超时。
        state.observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { notification in
            guard !state.finished else { return }
            // 只处理来自当前 manager.connection 的事件
            guard let conn = notification.object as? NEVPNConnection,
                  conn === manager.connection else { return }
            let status = manager.connection.status
            DiagLog.add("[hot-restart] Observer received status change: \(status.diagDesc) phase=\(state.phase)")
            switch (state.phase, status) {
            case (0, .disconnected), (0, .invalid):
                DiagLog.add("[hot-restart] phase 0→1: tunnel stopped, calling startVPNTunnel waiting for .connected")
                state.phase = 1
                do {
                    try manager.connection.startVPNTunnel()
                } catch {
                    finish(false, "VPN start failed: \(error.localizedDescription)")
                }
            case (1, .connected):
                DiagLog.add("[hot-restart] phase 1 got .connected, calling finish(true)")
                finish(true, nil)
            default:
                break  // 忽略 .connecting / .disconnecting / .reasserting 中间态
            }
        }

        // 异常兜底:若进来时已是 disconnected(理论上 vpnConnected==true 保证不会),
        // 直接跳阶段 1 启动 tunnel,否则触发 stop 等观察者推进。
        if manager.connection.status == .disconnected || manager.connection.status == .invalid {
            state.phase = 1
            do {
                try manager.connection.startVPNTunnel()
            } catch {
                finish(false, "VPN start failed: \(error.localizedDescription)")
            }
        } else {
            DiagLog.add("[hot-restart] Calling stopVPNTunnel, waiting for .disconnected event")
            manager.connection.stopVPNTunnel()
        }

        // 30 秒超时(放宽以适应 GoSpoofer 关闭 drain 与真机 NE 切换的真实耗时)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
            finish(false, "VPN reconnect timed out, check network")
        }
    }

    private func disableSpoofing() {
        let oldName = currentLocationName

        // 进入 pending(关闭中)
        spoofingState = .pending(name: oldName, isClosing: true)

        // 关 VPN
        if let manager = ContentView.vpnManager {
            manager.connection.stopVPNTunnel()
        }
        // 清坐标
        LocationConfiguration.shared.clearCoordinates()
        UserDefaults.standard.removeObject(forKey: "currentLocationName")
        currentLocationName = ""
        lastKnownUserCoord = realUserCoord  // 关闭伪装后,"回到我的位置"恢复跳真实坐标

        // 弹出"请重启定位服务"教学
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            showRestartPhoneGuide = true
        }
    }

    private func loadSavedLocations() {
        if let data = UserDefaults.standard.data(forKey: "savedLocations"),
           let decoded = try? JSONDecoder().decode([SavedLocation].self, from: data) {
            savedLocations = decoded
        }
    }

    private func saveSavedLocations() {
        if let encoded = try? JSONEncoder().encode(savedLocations) {
            UserDefaults.standard.set(encoded, forKey: "savedLocations")
        }
    }

    private func addCurrentSelectionToFavorites() {
        guard let coord = selectedCoordinate,
              let name = selectedLocationName else { return }
        // 避免重复
        if savedLocations.contains(where: { $0.name == name }) {
            // 已存在也给反馈,让用户知道点击生效
            triggerFavoritedFeedback()
            return
        }
        let new = SavedLocation(
            name: name,
            latitude: coord.latitude,
            longitude: coord.longitude
        )
        savedLocations.append(new)
        saveSavedLocations()
        triggerFavoritedFeedback()
    }

    private func triggerFavoritedFeedback() {
        // 视觉反馈(触感由 locationSheet 的 .sensoryFeedback 触发)
        justFavorited = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            justFavorited = false
        }
    }

    private func selectFavorite(_ saved: SavedLocation) {
        let coord = CLLocationCoordinate2D(latitude: saved.latitude, longitude: saved.longitude)
        selectedCoordinate = coord
        selectedLocationName = saved.name
        cameraPosition = .region(MKCoordinateRegion(
            center: coord,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
        showFavoritesSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            showLocationSheet = true
        }
    }

    private func deleteFavorite(_ saved: SavedLocation) {
        savedLocations.removeAll { $0.id == saved.id }
        saveSavedLocations()
    }

    private func refreshVPNStatus() {
        if let manager = ContentView.vpnManager {
            vpnStatus = manager.connection.status
            vpnConnected = (vpnStatus == .connected)
        }
    }
}
