$ErrorActionPreference = 'Stop'
$manifest = Join-Path $PSScriptRoot '..\flutter_app\android\app\src\main\AndroidManifest.xml'
$manifest = [System.IO.Path]::GetFullPath($manifest)
if (-not (Test-Path $manifest)) {
    Write-Host "AndroidManifest.xml পাওয়া যায়নি। আগে flutter create চালাও।" -ForegroundColor Yellow
    exit 1
}
$content = Get-Content -Raw -Encoding UTF8 $manifest
if ($content -notmatch 'android:usesCleartextTraffic=') {
    $content = [regex]::Replace($content, '<application\b', '<application android:usesCleartextTraffic="true"', 1)
}
if ($content -match 'android:label="[^"]*"') {
    $content = [regex]::Replace($content, 'android:label="[^"]*"', 'android:label="AI Auto Subtitle Generator"', 1)
} else {
    $content = [regex]::Replace($content, '<application\b', '<application android:label="AI Auto Subtitle Generator"', 1)
}
if ($content -notmatch 'android.permission.INTERNET') {
    $content = [regex]::Replace($content, '(<manifest\b[^>]*>)', '$1' + "`r`n    <uses-permission android:name=`"android.permission.INTERNET`" />", 1)
}
Set-Content -Path $manifest -Value $content -Encoding UTF8
Write-Host "Android manifest patch করা হয়েছে (local HTTP API access + Internet permission)." -ForegroundColor Green
$windowsMain = Join-Path $PSScriptRoot '..\flutter_app\windows\runner\main.cpp'
$windowsMain = [System.IO.Path]::GetFullPath($windowsMain)
if (Test-Path $windowsMain) {
    $windowsContent = Get-Content -Raw -Encoding UTF8 $windowsMain
    $windowsContent = $windowsContent.Replace('L"ai_auto_subtitle_generator"', 'L"AI Auto Subtitle Generator"')
    Set-Content -Path $windowsMain -Value $windowsContent -Encoding UTF8
}
