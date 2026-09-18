param(
    [string]$Shaderc = $env:LABELLE_SHADERC,
    [string]$Include = $env:LABELLE_SHADER_INCLUDE
)
$ErrorActionPreference = 'Stop'
if (-not $Shaderc -or -not $Include) { throw 'Supply -Shaderc and -Include (directory containing bgfx_shader.sh).' }
$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root '.test-output/shaders'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$varying = Join-Path $PSScriptRoot 'sprite_varying.def.sc'
$profiles = @{
    spv = @('linux', 'spirv'); glsl = @('linux', '120')
    essl = @('android', '300_es'); mtl = @('osx', 'metal')
    dx11 = @('windows', 's_5_0')
}
foreach ($effect in @('water', 'fog', 'lamp', 'mist')) {
    $dir = Join-Path $root "materials/$effect"
    $descriptor = Get-Content -Raw -LiteralPath (Join-Path $dir 'material.json') | ConvertFrom-Json
    foreach ($target in $descriptor.targets) {
        $profile = $profiles[$target]
        $output = Join-Path $outDir "$effect.$target.bin"
        & $Shaderc -f (Join-Path $dir $descriptor.fragment) -o $output --type fragment --platform $profile[0] -p $profile[1] -O 3 --varyingdef $varying -i $Include -i (Join-Path $root 'materials')
        if ($LASTEXITCODE -ne 0) { throw "Shader compile failed: $effect/$target" }
        Write-Host "$effect/$target compiled"
    }
}
