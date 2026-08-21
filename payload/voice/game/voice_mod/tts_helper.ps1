# Emergency fallback only: Windows SAPI.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Speech
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$synth.Volume = 100
$ru = @($synth.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -like "ru-*" })
if ($ru.Count -gt 0) { $synth.SelectVoice($ru[0].VoiceInfo.Name) }

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    if ($line -eq "STOP") {
        try { $synth.SpeakAsyncCancelAll() | Out-Null } catch {}
        continue
    }
    if ($line -eq "QUIT") { break }
    if ($line.StartsWith("SPEAK|")) {
        $parts = $line.Split(@("|"), 3, [System.StringSplitOptions]::None)
        if ($parts.Count -ne 3) { continue }
        try {
            $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[2]))
            try { $synth.SpeakAsyncCancelAll() | Out-Null } catch {}
            $null = $synth.SpeakAsync($text)
        } catch {}
    }
}
try { $synth.Dispose() } catch {}
