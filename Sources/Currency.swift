import AppKit
import SwiftUI
import Combine
import CoreAudio
import CoreBluetooth
import IOBluetooth
import IOKit
import IOKit.ps
import CoreWLAN
import CoreLocation
import EventKit
import UniformTypeIdentifiers
import ApplicationServices   // Accessibility API (AXUIElement) for quake window control
import QuartzCore            // CADisplayLink — vsync-synced panel animation

// MARK: - Currency converter

struct Ccy { let code: String; let flag: String }
// Add currencies here — this array is the single source of truth (API request,
// rate table, field rows, Tab/Shift-Tab wrap all derive from it). Only constraint:
// the code must be in the ECB reference set Frankfurter serves (USD, GBP, JPY,
// SGD, CNY, AUD, SEK, NOK, CHF, … — EUR is always the base). Keep EUR first.
let currencies = [Ccy(code: "EUR", flag: "🇪🇺"),
                  Ccy(code: "GBP", flag: "🇬🇧"),
                  Ccy(code: "THB", flag: "🇹🇭"),
                  Ccy(code: "MYR", flag: "🇲🇾")]

final class CurrencyModel: ObservableObject {
    @Published var rates: [String: Double] = ["EUR": 1]   // units per 1 EUR
    @Published var eur: Double = 1                         // source of truth
    @Published var asOf: String = ""                      // rate date from API
    private var lastFetch = Date.distantPast

    func refresh(force: Bool = false) {
        // ECB rates change at most once a business day — cache 6h (force bypasses).
        guard force || rates.count < 2 || Date().timeIntervalSince(lastFetch) > 21600 else { return }
        let to = currencies.map(\.code).filter { $0 != "EUR" }.joined(separator: ",")
        guard let url = URL(string: "https://api.frankfurter.app/latest?from=EUR&to=\(to)") else { return }
        lastFetch = Date()
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let r = obj["rates"] as? [String: Double] else { return }
            var table = r; table["EUR"] = 1
            let date = obj["date"] as? String ?? ""
            DispatchQueue.main.async { self?.rates = table; self?.asOf = date }
        }.resume()
    }

    func amount(_ code: String) -> Double { eur * (rates[code] ?? 0) }
    func set(_ code: String, _ v: Double) { eur = v / (rates[code] ?? 1) }
}

// AppKit field: Tab + Shift-Tab both work in the borderless panel (SwiftUI
// TextField only does forward), and parsing/formatting respects the locale
// decimal separator (comma on a Finnish Mac).
struct CurrencyField: NSViewRepresentable {
    var code: String
    var value: Double
    var onChange: (Double) -> Void

    private static let nf: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()
    // The borderless panel's key-view loop only links forward, so Shift-Tab is
    // dead. Register each field by code and move focus ourselves.
    // ponytail: 3 entries, process-lifetime, overwritten on rebuild — fine.
    private static var fields: [String: NSTextField] = [:]

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.alignment = .right
        tf.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        tf.textColor = NSColor(Gruv.fg0)
        tf.delegate = context.coordinator
        tf.stringValue = Self.nf.string(from: value as NSNumber) ?? ""
        Self.fields[code] = tf
        return tf
    }
    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.onChange = onChange
        // Don't stomp the field being typed in — only refresh the others.
        if tf.currentEditor() == nil {
            tf.stringValue = Self.nf.string(from: value as NSNumber) ?? ""
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(code: code, onChange: onChange) }

    static func focus(from code: String, step: Int) {
        let codes = currencies.map(\.code)
        guard let i = codes.firstIndex(of: code) else { return }
        let next = codes[(i + step + codes.count) % codes.count]
        guard let tf = fields[next] else { return }
        tf.window?.makeFirstResponder(tf)
        tf.selectText(nil)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let code: String
        var onChange: (Double) -> Void
        init(code: String, onChange: @escaping (Double) -> Void) {
            self.code = code; self.onChange = onChange
        }
        func controlTextDidChange(_ note: Notification) {
            guard let tf = note.object as? NSTextField else { return }
            if let n = CurrencyField.nf.number(from: tf.stringValue) {
                onChange(n.doubleValue)
            }
        }
        func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertBacktab(_:)) {
                CurrencyField.focus(from: code, step: -1); return true
            }
            if sel == #selector(NSResponder.insertTab(_:)) {
                CurrencyField.focus(from: code, step: 1); return true
            }
            return false
        }
    }
}

struct CurrencyTab: View {
    @ObservedObject var model: CurrencyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(currencies, id: \.code) { c in
                HStack {
                    Text(c.flag + "  " + c.code)
                        .foregroundColor(Gruv.fg2)
                        .frame(width: 76, alignment: .leading)
                    CurrencyField(code: c.code, value: model.amount(c.code)) { model.set(c.code, $0) }
                }
                .padding(10)
                .background(Gruv.bg1)
                .cornerRadius(8)
            }

            Spacer()

            HStack {
                Text(model.asOf.isEmpty ? "" : "ECB rate · \(model.asOf)")
                    .font(.system(size: 11))
                    .foregroundColor(Gruv.fg4)
                Spacer()
                Button { model.refresh(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(Gruv.fg2)
                }
                .buttonStyle(.plain)
                .help("Refresh rates")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { model.refresh() }
    }
}
