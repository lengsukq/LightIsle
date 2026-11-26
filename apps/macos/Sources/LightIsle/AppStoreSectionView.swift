import SwiftUI

struct AppStoreSectionView: View {
    @ObservedObject var appsCenter: NativeAppsModel
    @Binding var selectedInstallLocationID: String
    let onRequestUpgrade: (NativeAppStorePlugin) -> Void

    @State private var selectedCategory = "all"
    @State private var searchQuery = ""
    @State private var showingConfigSheet = false

    private var store: NativeAppStoreSnapshot? {
        appsCenter.store
    }

    private var allPlugins: [NativeAppStorePlugin] {
        store?.plugins ?? []
    }

    private var availableCategories: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for plugin in allPlugins {
            let cat = plugin.category.isEmpty ? "utility" : plugin.category
            if seen.insert(cat).inserted {
                ordered.append(cat)
            }
        }
        return ordered
    }

    private var filteredPlugins: [NativeAppStorePlugin] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allPlugins.filter { plugin in
            if selectedCategory != "all" && plugin.category != selectedCategory {
                return false
            }
            if needle.isEmpty {
                return true
            }
            if plugin.name.lowercased().contains(needle) ||
                plugin.id.lowercased().contains(needle) ||
                plugin.description.lowercased().contains(needle) {
                return true
            }
            return (plugin.tags ?? []).contains(where: { $0.lowercased().contains(needle) })
        }
    }

    private var installTargetBlockedReason: String? {
        guard let locations = appsCenter.appStorage?.locations, !locations.isEmpty else { return nil }
        let target: NativeAppStorageLocation?
        if selectedInstallLocationID.isEmpty {
            target = locations.first(where: { $0.isDefault }) ?? locations.first
        } else {
            target = locations.first(where: { $0.id == selectedInstallLocationID })
        }
        guard let loc = target else { return nil }
        if !loc.online {
            return "安装目标「\(loc.name)」当前已离线，请先重新连接硬盘或改选其他位置。"
        }
        if !loc.writable {
            return "安装目标「\(loc.name)」当前不可写，请检查磁盘权限后再安装。"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar
            if let blocked = installTargetBlockedReason {
                Label(blocked, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.warningText)
            }
            if let storeError = store?.error, !storeError.isEmpty {
                storeErrorBanner(storeError)
            }
            if allPlugins.count > 3 {
                filterBar
            }
            contentSection
        }
        .onChange(of: appsCenter.appStorage?.locations) { _, newLocations in
            guard !selectedInstallLocationID.isEmpty else { return }
            if !(newLocations ?? []).contains(where: { $0.id == selectedInstallLocationID }) {
                selectedInstallLocationID = ""
            }
        }
        .sheet(isPresented: $showingConfigSheet) {
            AppStoreConfigSheetView(appsCenter: appsCenter, isPresented: $showingConfigSheet)
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("在线插件商店")
                .font(.system(size: 15, weight: .semibold))
            IsleStatusPill(
                text: (store?.isOfficial ?? true) ? "官方 Git 仓库" : "自定义 Git 源",
                tone: (store?.isOfficial ?? true) ? .accent : .neutral,
                icon: "arrow.down.circle.fill"
            )
            if let mirror = store?.mirrorPrefix, !mirror.isEmpty {
                IsleStatusPill(text: "已启用镜像加速", tone: .success)
            }
            if let updatable = store?.updatableCount, updatable > 0 {
                IsleStatusPill(text: "\(updatable) 个可更新", tone: .warning, showDot: true)
            }
            Spacer(minLength: 8)
            if let locations = appsCenter.appStorage?.locations, locations.count > 1 {
                HStack(spacing: 6) {
                    Text("安装到")
                        .font(.system(size: 12))
                        .foregroundStyle(IsleTheme.secondaryText)
                    Picker("安装位置", selection: $selectedInstallLocationID) {
                        Text("默认（\(locations.first(where: { $0.isDefault })?.name ?? "内置盘")）").tag("")
                        ForEach(locations) { loc in
                            let statusSuffix = !loc.online ? "（离线）" : (loc.writable ? "" : "（只读）")
                            Text("\(loc.kind == "external" ? "其他盘" : "内置盘") · \(loc.name)\(statusSuffix)").tag(loc.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
            }
            Button {
                showingConfigSheet = true
            } label: {
                Label("商店源…", systemImage: "gearshape")
            }
            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            .disabled(appsCenter.busy)

            Button {
                appsCenter.refreshStore()
            } label: {
                Label("刷新商店", systemImage: "arrow.clockwise")
            }
            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            .disabled(appsCenter.busy)
        }
    }

    private func storeErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(IsleTheme.warningText)
            VStack(alignment: .leading, spacing: 2) {
                Text("无法同步在线商店目录")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(IsleTheme.warningText)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(IsleTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("配置加速镜像…") {
                showingConfigSheet = true
            }
            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            .disabled(appsCenter.busy)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    categoryFilterChip(id: "all", title: "全部（\(allPlugins.count)）")
                    ForEach(availableCategories, id: \.self) { category in
                        categoryFilterChip(id: category, title: Self.categoryLabel(for: category))
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(IsleTheme.secondaryText)
                TextField("搜索商店轻应用…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(IsleTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: 190)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
    }

    private func categoryFilterChip(id: String, title: String) -> some View {
        let selected = selectedCategory == id
        return Button {
            selectedCategory = id
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(
                    selected ? IsleFluidPalette.brandIndigo : Color.primary.opacity(0.06),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var contentSection: some View {
        if allPlugins.isEmpty {
            LiquidCard {
                VStack(spacing: 10) {
                    IsleHeaderIconBadge(icon: "bag.fill", tint: IsleFluidPalette.brandIndigo, size: 44)
                    Text("尚未拉取在线插件商店目录")
                        .font(.system(size: 14, weight: .semibold))
                    Text("基础家庭轻应用托管在 Git 仓库（plugins-store），按需下载并通过 SHA-256 校验安装，不占用主程序体积。")
                        .font(.system(size: 12))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button("立即拉取目录") {
                            appsCenter.refreshStore()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(appsCenter.busy)

                        Button("配置镜像或自定义源…") {
                            showingConfigSheet = true
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(appsCenter.busy)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        } else if filteredPlugins.isEmpty {
            LiquidCard {
                HStack {
                    Text("当前筛选条件下没有匹配的插件。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(IsleTheme.secondaryText)
                    Spacer()
                    Button("重置筛选") {
                        selectedCategory = "all"
                        searchQuery = ""
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                ForEach(filteredPlugins) { plugin in
                    pluginCard(plugin)
                }
            }
        }
    }

    private func pluginCard(_ plugin: NativeAppStorePlugin) -> some View {
        let visual = Self.pluginVisual(for: plugin)
        let installBlocked = installTargetBlockedReason != nil
        let sizeText = Self.formatSize(plugin.sizeBytes)
        let modeText = plugin.mode == "static" ? "0 MB 纯静态" : "按需动态"

        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                IsleHeaderIconBadge(icon: visual.icon, tint: visual.tint, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .lineLimit(1)
                    Text("v\(plugin.version) · \(modeText)\(sizeText.isEmpty ? "" : " · \(sizeText)")")
                        .font(.system(size: 11))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if plugin.updateAvailable {
                    IsleStatusPill(text: "可更新", tone: .warning, showDot: true)
                } else if plugin.installed {
                    IsleStatusPill(text: "已安装", tone: .success, showDot: true)
                } else {
                    IsleStatusPill(text: Self.categoryLabel(for: plugin.category), tone: .neutral)
                }
            }

            Text(plugin.description)
                .font(.system(size: 12.5))
                .foregroundStyle(IsleTheme.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(alignment: .center) {
                if let installedVer = plugin.installedVersion, plugin.updateAvailable {
                    Text("当前 v\(installedVer) → v\(plugin.version)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(IsleTheme.warningText)
                } else {
                    Text(plugin.author ?? "LightIsle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if plugin.updateAvailable {
                    Button("更新 v\(plugin.version)") {
                        onRequestUpgrade(plugin)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    .disabled(appsCenter.busy)
                } else if plugin.installed {
                    Button("已安装") {}
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(true)
                } else {
                    Button("下载安装") {
                        appsCenter.installStorePlugin(
                            id: plugin.id,
                            locationID: selectedInstallLocationID.isEmpty ? nil : selectedInstallLocationID
                        )
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    .disabled(appsCenter.busy || installBlocked)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(IsleItemCardSurface(interactive: (!plugin.installed && !installBlocked) || plugin.updateAvailable))
    }

    private static func formatSize(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "" }
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }

    static func categoryLabel(for category: String) -> String {
        switch category {
        case "network": return "网络监控"
        case "finance": return "财务订阅"
        case "home": return "家庭生活"
        case "utility": return "实用工具"
        case "media": return "影音工具"
        case "system": return "系统扩展"
        default: return "轻应用"
        }
    }

    private static func pluginVisual(for plugin: NativeAppStorePlugin) -> (icon: String, tint: Color) {
        switch plugin.id {
        case "network-pulse": return ("antenna.radiowaves.left.and.right", IsleFluidPalette.brandBlue)
        case "family-subscriptions": return ("creditcard.fill", IsleFluidPalette.brandCyan)
        case "warranty-vault": return ("shield.checkered", IsleFluidPalette.brandIndigo)
        case "family-board": return ("note.text", .orange)
        case "medicine-expiry": return ("cross.case.fill", .pink)
        case "utility-ledger": return ("bolt.fill", .yellow)
        case "baby-growth": return ("figure.and.child.holdinghands", .mint)
        case "house-info": return ("house.fill", IsleFluidPalette.brandViolet)
        case "weekly-menu": return ("fork.knife.circle.fill", .orange)
        case "pet-care": return ("pawprint.fill", .brown)
        default:
            switch plugin.category {
            case "network": return ("antenna.radiowaves.left.and.right", IsleFluidPalette.brandBlue)
            case "finance": return ("yensign.circle.fill", IsleFluidPalette.brandCyan)
            case "home": return ("house.fill", IsleFluidPalette.brandViolet)
            default: return ("sparkles", IsleFluidPalette.brandIndigo)
            }
        }
    }
}

struct AppStoreConfigSheetView: View {
    @ObservedObject var appsCenter: NativeAppsModel
    @Binding var isPresented: Bool

    @State private var registryURL = ""
    @State private var mirrorPrefix = ""

    private let mirrorPresets: [(label: String, prefix: String)] = [
        ("直连 GitHub", ""),
        ("ghfast.top 加速", "https://ghfast.top/"),
        ("gh-proxy.com 加速", "https://gh-proxy.com/")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                IsleHeaderIconBadge(icon: "bag.badge.plus", tint: IsleFluidPalette.brandIndigo, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("配置 Git 在线插件商店")
                        .font(.system(size: 17, weight: .semibold))
                    Text("可切换自建 Git 商店源或配置国内 GitHub 镜像加速前缀。")
                        .font(.system(size: 12))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
                Spacer()
            }

            AppleSettingsGroup(
                title: "商店索引地址（registry.json）",
                footer: "官方默认地址：\(appsCenter.store?.defaultUrl ?? "https://raw.githubusercontent.com/lengsukq/LightIsle/main/plugins-store/registry.json")。仅允许 HTTPS 地址。"
            ) {
                TextField("留空则使用官方默认 Git 仓库", text: $registryURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(12)
            }

            AppleSettingsGroup(
                title: "GitHub 加速镜像前缀（可选）",
                footer: "仅对 GitHub / raw.githubusercontent.com 地址生效；例如填入 https://ghfast.top/ 后将自动加速索引与 .liapp.zip 下载。"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("例如 https://ghfast.top/（留空表示直连）", text: $mirrorPrefix)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, design: .monospaced))
                    HStack(spacing: 8) {
                        ForEach(mirrorPresets, id: \.label) { preset in
                            Button(preset.label) {
                                mirrorPrefix = preset.prefix
                            }
                            .buttonStyle(
                                LiquidButtonStyle(
                                    variant: mirrorPrefix.trimmingCharacters(in: .whitespacesAndNewlines) == preset.prefix ? .prominent : .secondary,
                                    size: .small
                                )
                            )
                        }
                    }
                }
                .padding(12)
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(IsleTheme.successText)
                Text("所有下载的 .liapp.zip 均强制执行 SHA-256 校验；非官方自定义商店源下载的插件默认进入「待激活确认」状态，由管理员核对后再启用。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(IsleTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Button("恢复官方默认") {
                    appsCenter.updateStoreConfig(registryURL: "", mirrorPrefix: "", resetDefault: true)
                    isPresented = false
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))
                .disabled(appsCenter.busy)

                Spacer()

                Button("取消") {
                    isPresented = false
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))

                Button("保存并刷新商店") {
                    appsCenter.updateStoreConfig(
                        registryURL: registryURL,
                        mirrorPrefix: mirrorPrefix,
                        resetDefault: false
                    )
                    isPresented = false
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                .disabled(appsCenter.busy)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            if let store = appsCenter.store {
                registryURL = store.isOfficial ? "" : store.registryUrl
                mirrorPrefix = store.mirrorPrefix ?? ""
            }
        }
    }
}
