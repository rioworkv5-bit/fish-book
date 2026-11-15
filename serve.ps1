# سيرفر محلي بسيط لتجربة فيش بوك على http://localhost:8765
# التشغيل: powershell -ExecutionPolicy Bypass -File serve.ps1
$root = $PSScriptRoot
$types = @{ '.html'='text/html; charset=utf-8'; '.js'='text/javascript; charset=utf-8'; '.svg'='image/svg+xml';
            '.webmanifest'='application/manifest+json'; '.json'='application/json'; '.png'='image/png'; '.css'='text/css' }
$port = if ($env:PORT) { $env:PORT } else { 8765 }
$l = New-Object System.Net.HttpListener
$l.Prefixes.Add("http://localhost:$port/")
$l.Start()
Write-Host "Fish Book: http://localhost:$port/"
while ($l.IsListening) {
  $c = $l.GetContext()
  try {
    $rel = [Uri]::UnescapeDataString($c.Request.Url.AbsolutePath).TrimStart('/')
    if ($rel -eq '') { $rel = 'index.html' }
    $full = [IO.Path]::GetFullPath((Join-Path $root $rel))
    if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path $full -PathType Leaf)) {
      $bytes = [IO.File]::ReadAllBytes($full)
      $ext = [IO.Path]::GetExtension($full).ToLower()
      if ($types.ContainsKey($ext)) { $c.Response.ContentType = $types[$ext] }
      $c.Response.Headers.Add('Cache-Control', 'no-cache')
      $c.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } else { $c.Response.StatusCode = 404 }
  } catch { $c.Response.StatusCode = 500 }
  $c.Response.Close()
}
