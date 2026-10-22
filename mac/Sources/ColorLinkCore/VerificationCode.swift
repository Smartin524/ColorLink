import Foundation

/// 从短信里找验证码。
///
/// 规则：短信里得出现“验证码 / code / OTP”这类关键词，然后在 4～8 位的数字（其次是带数字的字母数字组合）
/// 里挑离关键词最近的那个，关键词后面的优先（验证码通常写在关键词后面）。
/// 后面紧跟“元 / 分钟 / 次 / 号”这类单位、前面有货币符号的数字直接排除，
/// 以避开“5 分钟内有效”“支付 1000 元”这类干扰。
public enum VerificationCode {
    private static let keywords = [
        "验证码", "校验码", "动态码", "动态密码", "确认码", "安全码", "登录码", "授权码", "短信码",
        // 不加 "pin"：会误中 shopping 之类的单词
        "驗證碼", "認證碼", "code", "otp", "passcode",
    ]

    private static let digits = try! NSRegularExpression(pattern: "(?<![0-9A-Za-z])[0-9]{4,8}(?![0-9A-Za-z])")
    private static let alnum = try! NSRegularExpression(
        pattern: "(?<![0-9A-Za-z])(?=[A-Za-z]*[0-9])(?=[0-9]*[A-Za-z])[A-Za-z0-9]{4,8}(?![0-9A-Za-z])"
    )

    public static func extract(from text: String) -> String? {
        let lower = text.lowercased() as NSString
        // 所有关键词出现的位置
        var anchors: [NSRange] = []
        for k in keywords {
            var range = lower.range(of: k)
            while range.location != NSNotFound {
                anchors.append(range)
                let next = range.location + range.length
                range = lower.range(of: k, options: [], range: NSRange(location: next, length: lower.length - next))
            }
        }
        guard !anchors.isEmpty else { return nil }

        let ns = text as NSString
        for regex in [digits, alnum] {
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .filter { !isQuantity($0.range, in: ns) }
            let best = matches.min { a, b in distance(a.range, anchors) < distance(b.range, anchors) }
            if let best { return ns.substring(with: best.range) }
        }
        return nil
    }

    private static let unitsAfter = Set("元块角分秒时天周月年日次个条位%号笔岁台张")
    private static let currencyBefore = Set("¥￥$")

    /// 金额、时长、编号这类“带单位的数字”不是验证码
    private static func isQuantity(_ r: NSRange, in s: NSString) -> Bool {
        let end = r.location + r.length
        if end < s.length, unitsAfter.contains(Character(s.substring(with: NSRange(location: end, length: 1)))) {
            return true
        }
        if r.location > 0, currencyBefore.contains(Character(s.substring(with: NSRange(location: r.location - 1, length: 1)))) {
            return true
        }
        return false
    }

    /// 离关键词的距离；在关键词前面的加罚分
    private static func distance(_ r: NSRange, _ anchors: [NSRange]) -> Int {
        anchors.map { a in
            let aEnd = a.location + a.length
            if r.location >= aEnd { return r.location - aEnd }
            if r.location + r.length <= a.location { return (a.location - (r.location + r.length)) * 3 + 10 }
            return 0
        }.min() ?? Int.max
    }
}
