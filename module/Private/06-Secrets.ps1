# 凭据存储与安全脱敏（含内存密钥缓存）。

function ConvertFrom-AISecureString([Security.SecureString]$Value) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Get-AISecretTarget([string]$Name) { "PSAITerminal/Model/$Name" }

function Update-AIMaskingSecretCache {
    $script:SecretMaskingCache.Clear()
    if ($script:Config -and $script:Config.models) {
        foreach ($name in @($script:Config.models.Keys)) {
            $secret = Get-AISecret ([string]$name)
            if ($secret) { [void]$script:SecretMaskingCache.Add($secret) }
        }
    }
    $script:SecretMaskingCacheInitialized = $true
}

function Save-AISecret([string]$Name, [string]$Secret, [switch]$SessionOnly) {
    if ($SessionOnly) {
        $script:SessionSecrets[$Name] = $Secret
        if ($Secret) { [void]$script:SecretMaskingCache.Add($Secret) }
        return
    }
    [PSAITerminal.PlatformCredentialStore]::Set((Get-AISecretTarget $Name), $Secret)
    [void]$script:SessionSecrets.Remove($Name)
    if ($Secret) { [void]$script:SecretMaskingCache.Add($Secret) }
    $script:LastSecretStoreError = $null
}

function Get-AISecret([string]$Name) {
    if ($script:SessionSecrets.ContainsKey($Name)) { return [string]$script:SessionSecrets[$Name] }
    try {
        $value = [PSAITerminal.PlatformCredentialStore]::Get((Get-AISecretTarget $Name))
        $script:LastSecretStoreError = $null
        $value
    } catch {
        $script:LastSecretStoreError = $_.Exception.Message
        $null
    }
}

function Remove-AISecret([string]$Name) {
    [void]$script:SessionSecrets.Remove($Name)
    [PSAITerminal.PlatformCredentialStore]::Remove((Get-AISecretTarget $Name))
    Update-AIMaskingSecretCache
}

function Protect-AIText([AllowNull()][string]$Text, [int]$MaximumCharacters = 65536) {
    if (-not $script:SecretMaskingCacheInitialized) {
        Update-AIMaskingSecretCache
    }
    [PSAITerminal.AITerminalSecurity]::ProtectText($Text, [string[]]$script:SecretMaskingCache, $MaximumCharacters)
}
