<#
  Windows 11 右键菜单第一级的「发送到 手机名」：编译 ColorLinkShell、打稀疏包、用自签名证书签名、注册。

  用法（在 windows 目录下，先用 dotnet publish 把 ColorLink 发布到安装目录）：
    .\tools\context-menu.ps1                 # 安装或更新
    .\tools\context-menu.ps1 -Uninstall      # 去掉右键菜单

  第一次运行会在「当前用户\个人」证书库里建一张自签名证书「CN=ColorLink Dev」，
  并导出 publish\context-menu\ColorLink-Dev.cer。Windows 只装受信任的包，
  所以需要你用管理员 PowerShell 把这张证书导入「本地计算机\受信任的人」一次（脚本会打印命令），然后再运行一次本脚本。
#>
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\ColorLink",
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$PackageName = 'ColorLink.ContextMenu'
$Subject = 'CN=ColorLink Dev'
$Root = Split-Path $PSScriptRoot -Parent
$Out = Join-Path $Root 'publish\context-menu'

function Remove-Registered {
    Get-AppxPackage -Name $PackageName | ForEach-Object {
        Write-Host "去掉已注册的 $($_.PackageFullName)"
        Remove-AppxPackage -Package $_.PackageFullName
    }
}

if ($Uninstall) {
    Remove-Registered
    Get-Process ColorLinkShell -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Host '右键菜单已去掉。'
    return
}

if (-not (Test-Path (Join-Path $InstallDir 'ColorLink.exe'))) {
    throw "安装目录里没有 ColorLink.exe：$InstallDir（先 dotnet publish src/ColorLink.App -c Release -r win-x64 -o `"$InstallDir`"）"
}

# 1. ColorLinkShell 发布到安装目录，和 ColorLink.exe 放一起
Get-Process ColorLinkShell -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Host '编译 ColorLinkShell…'
dotnet publish (Join-Path $Root 'src\ColorLink.Shell') -c Release -r win-x64 -o $InstallDir -v q -nologo
if ($LASTEXITCODE -ne 0) { throw 'ColorLinkShell 编译失败' }

# 2. 打包工具：Windows SDK BuildTools 的 NuGet 包里就有，不用装 Windows SDK
$tools = Get-ChildItem "$env:USERPROFILE\.nuget\packages\microsoft.windows.sdk.buildtools" -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -like '*\x64' } | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $tools) { throw '找不到 makeappx.exe（先 dotnet build src/ColorLink.App 还原一次 NuGet 包）' }
$makeappx = $tools.FullName
$signtool = Join-Path $tools.DirectoryName 'signtool.exe'

# 3. 包里只有清单和图标。版本号每次不同，重新注册时 Windows 才会更新
$stage = Join-Path $Out 'stage'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'context-menu\Assets') $stage -Recurse
$now = Get-Date
$version = '1.{0}.{1}.{2}' -f $now.ToString('yyMM'), $now.ToString('ddHH'), ($now.Minute * 60 + $now.Second)
$manifest = (Get-Content (Join-Path $PSScriptRoot 'context-menu\AppxManifest.xml') -Raw -Encoding UTF8).Replace('$VERSION$', $version)
[IO.File]::WriteAllText((Join-Path $stage 'AppxManifest.xml'), $manifest, (New-Object Text.UTF8Encoding $false))
$msix = Join-Path $Out 'ColorLink.ContextMenu.msix'
& $makeappx pack /o /nv /d $stage /p $msix | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'makeappx 打包失败' }

# 4. 自签名证书：有就复用，没有就建一张
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $Subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } |
    Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) {
    Write-Host "新建自签名证书 $Subject（当前用户\个人）"
    $cert = New-SelfSignedCertificate -Type Custom -Subject $Subject -KeyUsage DigitalSignature -FriendlyName 'ColorLink 右键菜单（自签名）' `
        -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(10) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
}
$cer = Join-Path $Out 'ColorLink-Dev.cer'
Export-Certificate -Cert $cert -FilePath $cer | Out-Null

& $signtool sign /q /fd SHA256 /sha1 $cert.Thumbprint /s My $msix
if ($LASTEXITCODE -ne 0) { throw 'signtool 签名失败' }

# 5. 证书要在「本地计算机\受信任的人」里，Windows 才肯装。这一步要管理员，交给用户自己做
$trusted = Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Thumbprint -eq $cert.Thumbprint
if (-not $trusted) {
    Write-Host ''
    Write-Host '还差一步：用「管理员」PowerShell 运行下面这行，信任这张证书，然后再运行一次本脚本：' -ForegroundColor Yellow
    Write-Host "Import-Certificate -FilePath `"$cer`" -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
    exit 2
}

# 6. 注册（当前用户，不用管理员）
Remove-Registered
Add-AppxPackage -Path $msix -ExternalLocation $InstallDir
Write-Host "已注册 $PackageName $version，程序目录 $InstallDir"
Write-Host '在资源管理器里右键任意文件，第一级菜单里就有「发送到 手机名」。'
