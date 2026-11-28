"""生成 Windows 端图标（需要 Pillow：pip install pillow）。

    python windows/tools/make-icons.py

- ColorLink.ico / ColorLink.png：应用图标，取 mac/Resources/AppIcon.icon/Assets/Link.png 的彩色链环
- Tray-{Light,Dark}-{On,Off}.ico：托盘单色图标，几何同 android/.../ic_link.xml（两个跑道形圆环，转 -45°）。
  Light = 浅色任务栏用的深色图形，Dark = 深色任务栏用的白色图形；Off = 断开时变淡
"""
import os
from PIL import Image, ImageDraw

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "windows", "src", "ColorLink.App", "Assets")
os.makedirs(OUT, exist_ok=True)

ICO_SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]


def square_crop(im, margin=0.06):
    box = im.getbbox()
    im = im.crop(box)
    side = int(max(im.size) * (1 + 2 * margin))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(im, ((side - im.width) // 2, (side - im.height) // 2))
    return canvas


def app_icon():
    src = Image.open(os.path.join(ROOT, "mac", "Resources", "AppIcon.icon", "Assets", "Link.png")).convert("RGBA")
    # 去掉白底（如果有）：接近白色的像素变透明
    px = src.load()
    for y in range(src.height):
        for x in range(src.width):
            r, g, b, a = px[x, y]
            if a and r > 245 and g > 245 and b > 245:
                px[x, y] = (r, g, b, 0)
    icon = square_crop(src)
    icon.resize((256, 256), Image.LANCZOS).save(os.path.join(OUT, "ColorLink.png"))
    icon.save(os.path.join(OUT, "ColorLink.ico"), sizes=[(s, s) for s in ICO_SIZES])


def mono_link(color, stroke=72):
    """1024 画布上画单色链环；托盘图标很小，线条比安卓版（64）粗一些"""
    size = 1024
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for x0 in (132, 452):
        d.rounded_rectangle([x0, 392, x0 + 440, 632], radius=120, outline=color, width=stroke)
    return square_crop(im.rotate(45, resample=Image.BICUBIC), margin=0.02)


def tray_icons():
    for theme, rgb in (("Light", (0, 0, 0)), ("Dark", (255, 255, 255))):
        for state, alpha in (("On", 255), ("Off", 110)):
            im = mono_link(rgb + (alpha,))
            im.save(os.path.join(OUT, f"Tray-{theme}-{state}.ico"), sizes=[(s, s) for s in (16, 20, 24, 32, 40, 48, 64)])


app_icon()
tray_icons()
print("icons ->", OUT)
