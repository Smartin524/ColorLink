using System.Text;
using ColorLink.Core;

namespace ColorLink.Core.Tests;

public class VerificationCodeTests
{
    [Theory]
    [InlineData("【招商银行】您的验证码为 482913，5分钟内有效，请勿泄露。", "482913")]
    [InlineData("【淘宝】验证码：7731，用于身份验证，10分钟内有效。", "7731")]
    [InlineData("您正在支付1000元，动态码 835120，切勿告知他人。", "835120")]
    [InlineData("G-583201 is your Google verification code.", "583201")]
    [InlineData("Your Uber code is 4821. Never share this code.", "4821")]
    [InlineData("【京东】校验码 Ab3k9Q，请于5分钟内输入。", "Ab3k9Q")]
    [InlineData("您尾号6789的卡于10月22日消费128.00元。", null)]
    [InlineData("明天下午3点开会，会议室 2048。", null)]
    [InlineData("您的 OTP 是 ¥5000 以外的 902211。", "902211")]
    public void Extracts(string text, string? expected) => Assert.Equal(expected, VerificationCode.Extract(text));
}

public class KnockTests
{
    const string Token = "secret-token";
    static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_729_500_000);

    static byte[] Packet(string id, int port, long ts, string? sig = null) =>
        Encoding.UTF8.GetBytes($"{{\"v\":1,\"id\":\"{id}\",\"port\":{port},\"ts\":{ts},\"sig\":\"{sig ?? KnockListener.Sign(Token, $"{id}|{port}|{ts}")}\"}}");

    static string? TokenFor(string id) => id == "phone-1" ? Token : null;

    [Fact]
    public void AcceptsSignedFreshPacketAndUsesSourceAddress()
    {
        var k = KnockListener.Verify(Packet("phone-1", 9000, Now.ToUnixTimeSeconds()), "::ffff:192.168.1.7", TokenFor, Now);
        Assert.NotNull(k);
        Assert.Equal(new PhoneEndpoint("192.168.1.7", 9000), k.Endpoint);
    }

    [Fact]
    public void RejectsBadSignature() =>
        Assert.Null(KnockListener.Verify(Packet("phone-1", 9000, Now.ToUnixTimeSeconds(), new string('a', 64)), "1.2.3.4", TokenFor, Now));

    [Fact]
    public void RejectsStaleTimestamp() =>
        Assert.Null(KnockListener.Verify(Packet("phone-1", 9000, Now.ToUnixTimeSeconds() - 301), "1.2.3.4", TokenFor, Now));

    [Fact]
    public void RejectsUnknownDevice() =>
        Assert.Null(KnockListener.Verify(Packet("phone-2", 9000, Now.ToUnixTimeSeconds()), "1.2.3.4", TokenFor, Now));

    [Fact]
    public void RejectsGarbage() =>
        Assert.Null(KnockListener.Verify("not json"u8.ToArray(), "1.2.3.4", TokenFor, Now));

    [Fact]
    public void SignatureMatchesPythonHmac() =>
        // HMAC-SHA256(key=token, msg="id|port|ts")，小写十六进制；期望值由 Python 的 hmac 模块算出，和模拟手机一致
        Assert.Equal("fba391ebd079d196f720539577c31b45fbf7006f9ee42c6ea660b6333b0c7436",
            KnockListener.Sign("secret-token", "mock-oppo-0001|8765|1729500000"));
}

public class EndpointTests
{
    [Theory]
    [InlineData("192.168.1.5", "192.168.1.5", 8765)]
    [InlineData("192.168.1.5:9000", "192.168.1.5", 9000)]
    [InlineData(" localhost:8765 ", "localhost", 8765)]
    [InlineData("fe80::1", "fe80::1", 8765)]
    public void Parses(string text, string host, int port) => Assert.Equal(new PhoneEndpoint(host, port), PhoneEndpoint.Parse(text));

    [Theory]
    [InlineData("")]
    [InlineData("1.2.3.4:abc")]
    public void RejectsBad(string text) => Assert.Throws<PhoneException>(() => PhoneEndpoint.Parse(text));

    [Fact]
    public void BracketsIpv6InUri() => Assert.Equal("https://[fe80::1]:8765/", new PhoneEndpoint("fe80::1", 8765).BaseUri.ToString());
}

public class EventDecodeTests
{
    [Fact]
    public void DecodesAllEvents()
    {
        Assert.IsType<PhoneEvent.Hello>(PhoneClient.Decode("hello", """{"deviceId":"x","name":"n","model":"m","android":"15","battery":50,"charging":false,"dnd":"all"}"""));
        var shot = Assert.IsType<PhoneEvent.Screenshot>(PhoneClient.Decode("screenshot",
            """{"id":3,"kind":"image","name":"a.png","mime":"image/png","size":10,"modified":5,"added":5,"width":null,"height":null,"duration":null,"path":"DCIM/"}"""));
        Assert.Equal("image_3_5", shot.Item.CacheKey);
        var n = Assert.IsType<PhoneEvent.Notification>(PhoneClient.Decode("notification", """{"key":"k","pkg":"p","app":"信息","sms":true,"title":"t","text":"x","time":1}"""));
        Assert.True(n.Value.Sms);
        Assert.Equal("你好", Assert.IsType<PhoneEvent.Clipboard>(PhoneClient.Decode("clipboard", """{"text":"你好"}""")).Text);
        Assert.Single(Assert.IsType<PhoneEvent.Shared>(PhoneClient.Decode("shared", """{"items":[{"id":"1","name":"a","mime":"b","size":2}]}""")).Files);
        Assert.Equal(new PhoneEvent.Power(true, null), PhoneClient.Decode("power", """{"charging":true}"""));
        Assert.Equal(new PhoneEvent.Dnd(DndMode.Silent), PhoneClient.Decode("dnd", """{"mode":"none"}"""));
        Assert.IsType<PhoneEvent.Unknown>(PhoneClient.Decode("dnd", """{"mode":"weird"}"""));
        Assert.IsType<PhoneEvent.Unknown>(PhoneClient.Decode("future", "{}"));
        Assert.IsType<PhoneEvent.Unknown>(PhoneClient.Decode("hello", "not json"));
    }
}

public class FileNameTests
{
    [Theory]
    [InlineData("IMG_1.jpg", "IMG_1.jpg")]
    [InlineData("../../evil.exe", "evil.exe")]
    [InlineData("a:b?.txt", "a_b_.txt")]
    [InlineData("...", "file")]
    public void Sanitizes(string input, string expected) => Assert.Equal(expected, PhoneClient.SafeFileName(input));

    [Fact]
    public void UniquePathAddsNumber()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        File.WriteAllText(Path.Combine(dir, "a.jpg"), "");
        Assert.Equal(Path.Combine(dir, "a 2.jpg"), PhoneClient.UniquePath(dir, "a.jpg"));
    }
}
