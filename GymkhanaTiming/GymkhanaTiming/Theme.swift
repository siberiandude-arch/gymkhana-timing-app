import SwiftUI

/// Общий визуальный стиль приложения — тёмный фон, оранжевый акцент (цвет
/// конусов), скруглённая жирная типографика, моноширинный шрифт для
/// секундомера. Собран целиком из цвета/шрифтов/SF Symbols — без растровых
/// картинок, т.к. их пока взять неоткуда (см. обсуждение иконки).
enum AppTheme {
    static let background = Color.black
    static let surface = Color(white: 0.12)
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.0)
    static let accentSecondary = Color(red: 0.25, green: 0.6, blue: 1.0)
    static let textSecondary = Color(white: 0.65)
}

extension Font {
    static func appTitle(_ size: CGFloat = 34) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }
    static func appHeadline(_ size: CGFloat = 18) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }
    static func appTimer(_ size: CGFloat = 48) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }
}

private struct AppBackground: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.07, green: 0.05, blue: 0.02)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            content
        }
    }
}

extension View {
    func appBackground() -> some View { modifier(AppBackground()) }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = AppTheme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appHeadline())
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appHeadline(16))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppTheme.accent.opacity(0.7), lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Круглая кнопка "назад" поверх видео/фото — используется и в записи, и в
/// калибровке, выглядит одинаково в обоих местах.
struct RoundIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.bold())
            .foregroundColor(.white)
            .padding(12)
            .background(Color.black.opacity(0.5))
            .clipShape(Circle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
