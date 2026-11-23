using System.Text.RegularExpressions;

namespace ColorLink.Core;

/// <summary>
/// 从短信里找验证码。
///
/// 规则：短信里得出现“验证码 / code / OTP”这类关键词，然后在 4～8 位的数字（其次是带数字的字母数字组合）
/// 里挑离关键词最近的那个，关键词后面的优先（验证码通常写在关键词后面）。
/// 后面紧跟“元 / 分钟 / 次 / 号”这类单位、前面有货币符号的数字直接排除，以避开“5 分钟内有效”“支付 1000 元”这类干扰。
/// </summary>
public static partial class VerificationCode
{
    static readonly string[] Keywords =
    [
        "验证码", "校验码", "动态码", "动态密码", "确认码", "安全码", "登录码", "授权码", "短信码",
        // 不加 "pin"：会误中 shopping 之类的单词
        "驗證碼", "認證碼", "code", "otp", "passcode",
    ];

    [GeneratedRegex("(?<![0-9A-Za-z])[0-9]{4,8}(?![0-9A-Za-z])")]
    private static partial Regex Digits();

    [GeneratedRegex("(?<![0-9A-Za-z])(?=[A-Za-z]*[0-9])(?=[0-9]*[A-Za-z])[A-Za-z0-9]{4,8}(?![0-9A-Za-z])")]
    private static partial Regex Alnum();

    const string UnitsAfter = "元块角分秒时天周月年日次个条位%号笔岁台张";
    const string CurrencyBefore = "¥￥$";

    public static string? Extract(string text)
    {
        var lower = text.ToLowerInvariant();
        var anchors = new List<(int Start, int End)>();
        foreach (var k in Keywords)
        {
            for (int i = lower.IndexOf(k, StringComparison.Ordinal); i >= 0; i = lower.IndexOf(k, i + k.Length, StringComparison.Ordinal))
                anchors.Add((i, i + k.Length));
        }
        if (anchors.Count == 0) return null;

        foreach (var regex in new[] { Digits(), Alnum() })
        {
            var best = regex.Matches(text)
                .Where(m => !IsQuantity(m, text))
                .MinBy(m => Distance(m, anchors));
            if (best is not null) return best.Value;
        }
        return null;
    }

    /// <summary>金额、时长、编号这类“带单位的数字”不是验证码</summary>
    static bool IsQuantity(Match m, string s)
    {
        int end = m.Index + m.Length;
        if (end < s.Length && UnitsAfter.Contains(s[end])) return true;
        if (m.Index > 0 && CurrencyBefore.Contains(s[m.Index - 1])) return true;
        return false;
    }

    /// <summary>离关键词的距离；在关键词前面的加罚分</summary>
    static int Distance(Match m, List<(int Start, int End)> anchors) =>
        anchors.Min(a =>
        {
            if (m.Index >= a.End) return m.Index - a.End;
            if (m.Index + m.Length <= a.Start) return (a.Start - (m.Index + m.Length)) * 3 + 10;
            return 0;
        });
}
