import SwiftUI
import AppKit

extension Notification.Name {
    static let mailToggleSidebar = Notification.Name("GaoMenHu.Mail.toggleSidebar")
    static let mailFocusSearch = Notification.Name("GaoMenHu.Mail.focusSearch")
    static let mailSettingsTab = Notification.Name("GaoMenHu.Mail.settingsTab")
    static let mailOpenAliasHelper = Notification.Name("GaoMenHu.Mail.openAliasHelper")
    static let mailOpenSettings = Notification.Name("GaoMenHu.Mail.openSettings")
    static let mailAppearanceChanged = Notification.Name("GaoMenHu.Mail.appearanceChanged")
}

struct MailSidebarRow: View {
    var title: String
    var symbol: String
    var count: Int?
    var selected: Bool
    var accent: Color = PortalTheme.accent
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Button(action:action) {
            HStack(spacing:10) {
                Image(systemName:symbol).font(.callout).frame(width:20)
                Text(title).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength:0)
                if let count {
                    Text(String(count)).font(.caption.monospacedDigit()).foregroundStyle(selected ? Color.white : .secondary)
                        .padding(.horizontal,7).padding(.vertical,2)
                        .background(selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.05),in:Capsule())
                }
            }.padding(.horizontal,10).frame(maxWidth:.infinity,minHeight:40)
                .foregroundStyle(selected ? Color.white : .primary)
                .background {
                    if selected {RoundedRectangle(cornerRadius:12,style:.continuous).fill(accent).shadow(color:accent.opacity(colorScheme == .dark ? 0.45 : 0.32),radius:5,y:2)}
                    else if hovered {RoundedRectangle(cornerRadius:12,style:.continuous).fill(Color.primary.opacity(0.06))}
                }
                .contentShape(RoundedRectangle(cornerRadius:12,style:.continuous))
        }.buttonStyle(.plain).onHover {hovered = $0}
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

@ToolbarContentBuilder
func mailToolbarItem<Content: View>(_ placement:ToolbarItemPlacement,@ViewBuilder content:@escaping () -> Content) -> some ToolbarContent {
    if #available(macOS 26.0,*) {ToolbarItem(placement:placement,content:content).sharedBackgroundVisibility(.hidden)}
    else {ToolbarItem(placement:placement,content:content)}
}

struct MailSidebarToggleIcon: View {
    @State private var hovered = false
    var body: some View {
        Image(systemName:"sidebar.left").frame(width:28,height:28)
            .background(Color.primary.opacity(hovered ? 0.08 : 0),in:RoundedRectangle(cornerRadius:6))
            .contentShape(Rectangle()).onHover {hovered = $0}.animation(.easeInOut(duration:0.12),value:hovered)
    }
}

struct MailWindowToolbarBackground: ViewModifier {
    func body(content:Content) -> some View {
        if #available(macOS 15.0,*) {
            content.toolbarBackground(Color(nsColor:.windowBackgroundColor),for:.windowToolbar)
                .toolbarBackgroundVisibility(.visible,for:.windowToolbar)
        } else { content.toolbarBackground(Color(nsColor:.windowBackgroundColor),for:.windowToolbar) }
    }
}
