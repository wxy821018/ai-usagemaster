# 编译 Windows 版 AI UsageMaster 并安装到 %LOCALAPPDATA%\Programs\AI UsageMaster（目前是命令行版，还没有托盘界面）。
#
# 需要：Swift 工具链（winget install Swift.Toolchain）、Visual Studio Build Tools 的 C++ 工具和 Windows SDK。
# 用法：powershell -ExecutionPolicy Bypass -File build.ps1               只编译安装
#       powershell -ExecutionPolicy Bypass -File build.ps1 -AddToPath    另外把安装目录加进用户 PATH，任何终端里都能直接运行 AIUsageMaster
#       powershell -ExecutionPolicy Bypass -File build.ps1 -SelfTest     装完跑一遍自检
param([switch]$AddToPath, [switch]$SelfTest)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# winget 装完 Swift 后，当前窗口的 PATH / SDKROOT 可能还是旧的：从注册表重新读一次
$env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine")
if (-not $env:SDKROOT) {
    $env:SDKROOT = [Environment]::GetEnvironmentVariable("SDKROOT", "User")
    if (-not $env:SDKROOT) { $env:SDKROOT = [Environment]::GetEnvironmentVariable("SDKROOT", "Machine") }
}
$swift = Get-Command swift -ErrorAction SilentlyContinue
if (-not $swift) { throw "找不到 swift：先运行 winget install Swift.Toolchain，装完重开窗口" }

swift build -c release
if ($LASTEXITCODE -ne 0) { throw "编译失败" }
$bin = (swift build -c release --show-bin-path).Trim()
$exe = Join-Path $bin "AIUsageMaster.exe"
if (-not (Test-Path $exe)) { throw "没找到编译结果：$exe" }

$dest = Join-Path $env:LOCALAPPDATA "Programs\AI UsageMaster"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item $exe $dest -Force
# 编译产物旁边的 DLL（依赖包编成的动态库，如果有）
Get-ChildItem $bin -Filter *.dll -ErrorAction SilentlyContinue | Copy-Item -Destination $dest -Force
# Swift 运行库：拷到 exe 旁边，这样没装 Swift 的电脑也能运行。运行库目录就是 swiftCore.dll 所在的那个
$core = Get-ChildItem ($env:Path -split ";" | Where-Object { $_ -and (Test-Path (Join-Path $_ "swiftCore.dll")) } | Select-Object -First 1) -Filter *.dll
if (-not $core) { throw "没找到 Swift 运行库（swiftCore.dll）" }
$core | Copy-Item -Destination $dest -Force
Write-Host "已安装：$dest\AIUsageMaster.exe"

if ($AddToPath) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (($userPath -split ";") -notcontains $dest) {
        [Environment]::SetEnvironmentVariable("Path", ($userPath.TrimEnd(";") + ";" + $dest), "User")
        Write-Host "已加进用户 PATH（新开的终端窗口生效）：$dest"
    } else {
        Write-Host "用户 PATH 里已经有：$dest"
    }
}

if ($SelfTest) {
    & (Join-Path $dest "AIUsageMaster.exe") --selftest
}
