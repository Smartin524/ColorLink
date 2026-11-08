import Foundation
import ImageIO

/// Reads embedded capture metadata only; filesystem dates may describe a Bluetooth import.
public enum ImageCaptureDate {
    public static func read(_ data: Data, timeZone: TimeZone = .current) -> Int64? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return nil }
        for (dateKey, offsetKey) in [
            (kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifOffsetTimeOriginal),
            (kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifOffsetTimeDigitized)
        ] {
            if let value = exif[dateKey as String] as? String,
               let date = parse(value, offset: exif[offsetKey as String] as? String, timeZone: timeZone) {
                return date
            }
        }
        return nil
    }

    static func parse(_ value: String, offset: String?, timeZone: TimeZone) -> Int64? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.isLenient = false
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let offset, !offset.isEmpty {
            guard offset.range(of: #"^[+-][0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
            let parts = offset.dropFirst().split(separator: ":")
            guard let hours = Int(parts[0]), let minutes = Int(parts[1]), hours <= 23, minutes < 60 else { return nil }
            let seconds = (hours * 3600 + minutes * 60) * (offset.first == "-" ? -1 : 1)
            guard let explicitZone = TimeZone(secondsFromGMT: seconds) else { return nil }
            formatter.timeZone = explicitZone
        }
        guard let date = formatter.date(from: text), formatter.string(from: date) == text,
              date.timeIntervalSince1970 > 0 else { return nil }
        return Int64(date.timeIntervalSince1970)
    }
}
