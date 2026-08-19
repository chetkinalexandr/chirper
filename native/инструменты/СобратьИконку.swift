// Отрисовка SVG в PNG и сборка .icns без внешних зависимостей.
//
// Ни rsvg-convert, ни ImageMagick, ни cairosvg в системе может не быть, а
// тянуть их в зависимости сборки ради одной иконки неоправданно. WebKit есть
// в любой macOS, поэтому SVG рендерится им.
import Cocoa
import WebKit

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    FileHandle.standardError.write("Использование: СобратьИконку <вход.svg> <выход.png> <размер>\n".data(using: .utf8)!)
    exit(2)
}
let svgPath = arguments[1]
let pngPath = arguments[2]
guard let size = Int(arguments[3]), size > 0 else {
    FileHandle.standardError.write("Размер должен быть положительным числом\n".data(using: .utf8)!)
    exit(2)
}

guard let svg = try? String(contentsOfFile: svgPath, encoding: .utf8) else {
    FileHandle.standardError.write("Не удалось прочитать \(svgPath)\n".data(using: .utf8)!)
    exit(1)
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)

// Фон страницы прозрачный: иконка обязана лечь на любой фон Dock и Finder.
let html = """
<html><head><style>
*{margin:0;padding:0}
html,body{background:transparent;overflow:hidden}
svg{display:block;width:\(size)px;height:\(size)px}
</style></head><body>\(svg)</body></html>
"""

final class Рендерер: NSObject, WKNavigationDelegate {
    let выход: String
    let размер: Int

    init(выход: String, размер: Int) {
        self.выход = выход
        self.размер = размер
    }

    /// Пересэмплирует снимок в точный размер в пикселях.
    static func привести(_ источник: NSBitmapImageRep, к размеру: Int) -> Data? {
        guard let цель = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: размеру, pixelsHigh: размеру,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        цель.size = NSSize(width: размеру, height: размеру)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: цель)
        NSGraphicsContext.current?.imageInterpolation = .high
        источник.draw(in: NSRect(x: 0, y: 0, width: размеру, height: размеру))
        NSGraphicsContext.restoreGraphicsState()
        return цель.representation(using: .png, properties: [:])
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // WebKit сообщает о загрузке до того, как завершит раскладку и
        // растеризацию: без задержки снимок иногда выходит пустым.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = NSRect(x: 0, y: 0, width: self.размер, height: self.размер)
            // Без явной ширины снимок берётся с масштабом экрана: на Retina
            // запрошенные 256 пришли бы как 512, и весь iconset собрался бы
            // с неверными размерами.
            configuration.snapshotWidth = NSNumber(value: self.размер)
            webView.takeSnapshot(with: configuration) { image, error in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let representation = NSBitmapImageRep(data: tiff),
                      let png = representation.representation(using: .png, properties: [:]) else {
                    let текст = error?.localizedDescription ?? "снимок не получен"
                    FileHandle.standardError.write("Ошибка отрисовки: \(текст)\n".data(using: .utf8)!)
                    exit(1)
                }
                // WebKit отдаёт снимок в пикселях экрана: на Retina это вдвое
                // больше запрошенного. Приводим к точному размеру явно, иначе
                // iconutil получит iconset с неверными размерами и откажет.
                let итог: Data
                if representation.pixelsWide != self.размер || representation.pixelsHigh != self.размер {
                    guard let приведённый = Self.привести(representation, к: self.размер) else {
                        FileHandle.standardError.write("Не удалось привести снимок к \(self.размер) px\n".data(using: .utf8)!)
                        exit(1)
                    }
                    итог = приведённый
                } else {
                    итог = png
                }
                do {
                    try итог.write(to: URL(fileURLWithPath: self.выход))
                } catch {
                    FileHandle.standardError.write("Не удалось записать \(self.выход)\n".data(using: .utf8)!)
                    exit(1)
                }
                exit(0)
            }
        }
    }
}

let webView = WKWebView(
    frame: NSRect(x: 0, y: 0, width: size, height: size),
    configuration: WKWebViewConfiguration()
)
webView.setValue(false, forKey: "drawsBackground")
let рендерер = Рендерер(выход: pngPath, размер: size)
webView.navigationDelegate = рендерер
webView.loadHTMLString(html, baseURL: nil)

RunLoop.main.run(until: Date().addingTimeInterval(20))
FileHandle.standardError.write("Отрисовка не уложилась в отведённое время\n".data(using: .utf8)!)
exit(1)
