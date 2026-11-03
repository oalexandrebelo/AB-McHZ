import AppKit
import HetzCore

/// Linha "Brilho ───●─── 75" dentro do menu. Fica desabilitada até a primeira leitura DDC.
final class BrightnessView: NSView {
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "…")
    private let onChange: (UInt16) -> Void

    init(onChange: @escaping (UInt16) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 290, height: 30))
        let label = NSTextField(labelWithString: "Brilho")
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 20, y: 6, width: 52, height: 18)
        slider.frame = NSRect(x: 74, y: 5, width: 166, height: 20)
        slider.isContinuous = true
        slider.isEnabled = false
        slider.target = self
        slider.action = #selector(changed)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 242, y: 6, width: 34, height: 18)
        [label, slider, valueLabel].forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) não é usado")
    }

    func show(_ value: VCPValue) {
        slider.maxValue = Double(value.maximum)
        slider.doubleValue = Double(value.current)
        slider.isEnabled = true
        valueLabel.stringValue = "\(value.current)"
    }

    func showError(_ text: String) {
        valueLabel.stringValue = "—"
        toolTip = text
    }

    @objc private func changed() {
        let value = UInt16(slider.doubleValue.rounded())
        valueLabel.stringValue = "\(value)"
        onChange(value)
    }
}
