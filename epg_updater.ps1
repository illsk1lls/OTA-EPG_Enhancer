<#=====================================================================
  Tvheadend EPG Enhancer
=====================================================================#>

# ================== CONFIGURATION ==================
$TvhUrl      = "http://truenas:9981/xmltv/channels"
$TvhUser     = "streamuser"
$TvhPass     = "streampass"
$OutputFile  = "\\truenas\configs\epg_data\tvheadend-enriched.xml"
$CacheDir    = "B:\TvmazeCache"
$TMDbKey     = "8f2c5a4a41c1c8e0d9e4d3d5f8d8e7f6"
# ===================================================

if (-not (Test-Path $CacheDir)) { New-Item -Path $CacheDir -ItemType Directory -Force | Out-Null }

$pair = "$TvhUser`:$TvhPass"
$encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers = @{ Authorization = "Basic $encoded" }

$script:LastCall = (Get-Date).AddSeconds(-1)
function Wait-RateLimit {
    $elapsed = ((Get-Date) - $script:LastCall).TotalSeconds
    if ($elapsed -lt 0.3) { Start-Sleep -Milliseconds (300 - ($elapsed*1000)) }
    $script:LastCall = Get-Date
}

function Get-CachedOrFetch($url) {
    $hash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($url))) -replace '-',''
    $file = "$CacheDir\$hash.json"
    if (Test-Path $file) { return Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json }

    Wait-RateLimit
    try {
        $data = Invoke-RestMethod $url -TimeoutSec 20 -ErrorAction Stop
        $data | ConvertTo-Json -Depth 10 | Out-File $file -Encoding UTF8
        return $data
    } catch { return $null }
}

function Get-BestPoster($obj) {
    if ($obj.image -and $obj.image.original)       { return $obj.image.original }
    if ($obj.show -and $obj.show.image -and $obj.show.image.original)  { return $obj.show.image.original }
    if ($obj.show -and $obj.show.image -and $obj.show.image.medium)    { return $obj.show.image.medium }
    if ($obj.poster_path) { return "https://image.tmdb.org/t/p/original$($obj.poster_path)" }
    return $null
}

function Clean-Text($text) {
    if (-not $text) { return $text }
    $text = $text -replace '[©®™•…“”‘’]', ''
    $text = $text -replace '\s+', ' '
    return $text.Trim()
}

# Hard-coded news logos for Philadelphia area channels
$NewsLogoMap = @{
    "CBS"      = "https://play-lh.googleusercontent.com/mMFzGrtH3ZEf0AM9wgumkkAM0hKrnAjwR_Ber0JMOeKvkZhgdj4IWe3b_szT_C--lA=w600-h300-pc0xffffff-pd"      # CBS 3
    "ABC"     = "https://www.newscaststudio.com/wp-content/uploads/2024/03/NCS_WPVI_029.jpg"          # ABC 6 Action News
    "NBC"     = "https://media.nbcphiladelphia.com/2024/08/Roku_Channel_Tile_2000x3000_Philadelphia.png?resize=1200%2C675&quality=85&strip=all"       # NBC 10
    "FOX"     = "https://d10bt0812qicot.cloudfront.net/img/39/771e2724f64eb88a5fdb4b53c4e087/1130x555.png"      # FOX 29
    "PHL"     = "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/68/0f/07/680f077c-3bf9-b806-be3c-8f2a18aac57c/AppIcon-0-0-1x_U007emarketing-0-8-0-85-220.png/1200x630wa.jpg"                  # PHL17
    "Univision"     = "https://i.ytimg.com/vi/kBkD2dwLkvE/hq720.jpg?sqp=-oaymwE7CK4FEIIDSFryq4qpAy0IARUAAAAAGAElAADIQj0AgKJD8AEB-AH-CYAC0AWKAgwIABABGBQgEyh_MA8=&rs=AOn4CLDyiCFkxtMHkcuHfmeKJ965KazGXg"    # Univision 65
    "PBS"     = "https://is1-ssl.mzstatic.com/image/thumb/Purple116/v4/f6/d5/c3/f6d5c31c-ec39-bbc3-99a0-b3740bd8b2a9/AppIcon-0-0-1x_U007epad-0-0-0-0-0-0-sRGB-0-0-0-GLES2_U002c0-512MB-85-220-0-0.jpeg/1200x630wa.png"               # NJ PBS
    "Telemundo"     = "https://yt3.googleusercontent.com/ytc/AIdro_lrAFsc7C4t12A8gv6_XmQkv3vn30y-N4nmFVoP1h9tT9M=s176-c-k-c0x00ffffff-no-rj-mo"    # Telemundo 62
}

Write-Host "Downloading EPG from Tvheadend..." -ForegroundColor Cyan
$raw = Invoke-WebRequest -Uri $TvhUrl -Headers $headers -UseBasicParsing -TimeoutSec 300
$content = [regex]::Replace($raw.Content, '<!DOCTYPE[^>]*>', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
$xml = New-Object System.Xml.XmlDocument
$xml.PreserveWhitespace = $true
$xml.LoadXml($content)

$total = $xml.tv.programme.Count
$current = 0

foreach ($prog in $xml.tv.programme) {
    $current++
    $title = Clean-Text ($prog.title.Trim())
    $desc  = if ($prog.desc) { Clean-Text ($prog.desc.Trim()) } else { "" }
    $startDt = [datetime]::ParseExact($prog.start.Substring(0,14), 'yyyyMMddHHmmss', $null)
    $stopDt  = [datetime]::ParseExact($prog.stop.Substring(0,14),  'yyyyMMddHHmmss', $null)
    $runtimeMin = [math]::Round(($stopDt - $startDt).TotalMinutes)
    $yearHint = if ($prog.date) { $prog.date.Trim() } else { $null }

    Write-Progress -Activity "Enriching EPG" -Status "$title ($runtimeMin min)" -PercentComplete ($current/$total*100)

    $poster = $null; $rating = $null; $year = $null; $cats = @(); $subtitle = $null; $season = $null; $episode = $null
    $isLong = $runtimeMin -ge 60

    # === 1. Long programs - TMDb (movies) ===
    if ($isLong) {
        $tmdbUrl = "https://api.themoviedb.org/3/search/movie?api_key=$TMDbKey&query=" + [Uri]::EscapeDataString($title)
        if ($yearHint) { $tmdbUrl += "&year=$yearHint" }
        $tmdb = Get-CachedOrFetch $tmdbUrl
        if ($tmdb -and $tmdb.results -and $tmdb.results.Count -gt 0) {
            $movie = $tmdb.results[0]
            $poster = Get-BestPoster $movie
            $rating = $movie.vote_average
            if ($movie.release_date) { $year = $movie.release_date.Substring(0,4) }
            $cats += "Movie"
        }
    }

    # === 2. Everything else - TVmaze ===
    if (-not $isLong -or -not $poster) {
        $searchUrl = "https://api.tvmaze.com/search/shows?q=" + [Uri]::EscapeDataString($title)
        $results = Get-CachedOrFetch $searchUrl
        $match = $null
        if ($results) {
            foreach ($r in $results) { if ($r.show.name -eq $title) { $match = $r; break } }
            if (-not $match -and $yearHint) {
                foreach ($r in $results) { if ($r.show.premiered -and $r.show.premiered.StartsWith($yearHint)) { $match = $r; break } }
            }
            if (-not $match -and $results.Count -gt 0) { $match = $results[0] }
        }

        if ($match) {
            $show = $match.show
            if (-not $poster) { $poster = Get-BestPoster $match }
            if (-not $rating) { $rating = $show.rating.average }
            if (-not $year -and $show.premiered) { $year = $show.premiered.Substring(0,4) }
            if ($show.genres) { $cats += $show.genres }

            # Rich description + episode info
            $ep = $null
            if ($desc) {
                $all = Get-CachedOrFetch "https://api.tvmaze.com/shows/$($show.id)/episodes"
                if ($all) {
                    $short = $desc.Substring(0,[Math]::Min(120,$desc.Length))
                    foreach ($e in $all) {
                        if ($e.summary -and ($e.summary -replace '<[^>]+>','') -like "*$short*") { $ep = $e; break }
                    }
                }
            }
            if (-not $ep) {
                $date = $startDt.ToString('yyyy-MM-dd')
                $ep = Get-CachedOrFetch "https://api.tvmaze.com/shows/$($show.id)/episodebynumber?airdate=$date"
            }
            if ($ep) {
                $subtitle = $ep.name
                $season = $ep.season
                $episode = $ep.number
                if ($ep.summary) {
                    $full = ($ep.summary -replace '<[^>]+>','').Trim()
                    if ($full.Length -gt 20) { $prog.desc = Clean-Text $full }
                }
            }
        }
    }

    # === 3. News logo fallback ===
    if (-not $poster -and $title -match "news|action news|eyewitness|noticias|telemundo|univision") {
        foreach ($key in $NewsLogoMap.Keys) {
            if ($prog.channel.id -match $key -or $title -match $key) {
                $poster = $NewsLogoMap[$key]
                break
            }
        }
    }

    # === Apply enrichments ===
    foreach ($c in ($cats | Select-Object -Unique)) {
        if (-not ($prog.category | Where-Object { $_.'#text' -eq $c })) {
            $cat = $xml.CreateElement("category"); $cat.InnerText = $c; $prog.AppendChild($cat) | Out-Null
        }
    }
    if ($poster -and -not $prog.icon) {
        $i = $xml.CreateElement("icon"); $i.SetAttribute("src",$poster); $prog.AppendChild($i) | Out-Null
    }
    if ($rating) {
        if (-not $prog.rating) {
            $r = $xml.CreateElement("rating"); $r.SetAttribute("value",[math]::Round($rating,1)); $prog.AppendChild($r) | Out-Null
        }
    }
    if ($year -and -not $prog.date) {
        $y = $xml.CreateElement("date"); $y.InnerText = $year; $prog.AppendChild($y) | Out-Null
    }
    if ($subtitle -and -not $prog.'sub-title') {
        $sub = $xml.CreateElement("sub-title"); $sub.InnerText = Clean-Text $subtitle; $prog.AppendChild($sub) | Out-Null
    }
    if ($season -and $episode) {
        $on = $xml.CreateElement("episode-num"); $on.SetAttribute("system","onscreen")
        $on.InnerText = "S{0:D2}E{1:D2}" -f [int]$season, [int]$episode
        $prog.AppendChild($on) | Out-Null
        $ns = $xml.CreateElement("episode-num"); $ns.SetAttribute("system","xmltv_ns")
        $ns.InnerText = "{0}.{1}." -f ([int]$season-1), ([int]$episode-1)
        $prog.AppendChild($ns) | Out-Null
    }
}

Write-Progress -Activity "Enriching EPG" -Completed

# Save with proper UTF-8 + BOM
$utf8 = New-Object System.Text.UTF8Encoding $true
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = $utf8
$settings.Indent = $true
$writer = [System.Xml.XmlWriter]::Create($OutputFile, $settings)
$xml.Save($writer)
$writer.Close()