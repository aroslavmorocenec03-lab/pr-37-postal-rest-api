param([string]$BaseUrl = 'http://localhost:5050')

# PowerShell 7. Запускати з новим екземпляром навчального сервера.
$ErrorActionPreference = 'Stop'
$report = [Collections.Generic.List[string]]::new()
$report.Add("Час: $([DateTimeOffset]::Now.ToString('O'))")
$report.Add('Перевірка реальних HTTP-запитів до PostService.')
$script:passed = 0

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message. Очікується: $Expected; отримано: $Actual" }
}
function Mark([string]$Message) {
    $script:passed++
    $report.Add("PASS $script:passed`: $Message")
}
function Send([string]$Method, [string]$Path, $Body = $null) {
    $parameters = @{ Uri = $BaseUrl.TrimEnd('/') + $Path; Method = $Method; SkipHttpErrorCheck = $true }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress))
    }
    $response = Invoke-WebRequest @parameters
    $responseText = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
    $report.Add("`n$Method $Path -> HTTP $([int]$response.StatusCode)")
    if ($responseText.Length -gt 0) { $report.Add($responseText) }
    [pscustomobject]@{ Status = [int]$response.StatusCode; Text = $responseText; Headers = $response.Headers }
}

$root = Send GET '/'
Assert-Equal 200 $root.Status 'GET /'
Assert-Equal 'Це API поштового клієнта.' $root.Text 'Коренева відповідь'
Mark 'Кореневий маршрут із попередньої роботи збережено.'

$all = Send GET '/postings'
Assert-Equal 200 $all.Status 'GET /postings'
if ([string]$all.Headers['Content-Type'] -notmatch '^application/json') { throw 'Очікується JSON.' }
$initial = @($all.Text | ConvertFrom-Json)
Assert-Equal 3 $initial.Count 'Початкові записи'
foreach ($field in @('id','from','to','content','deliveryType','weight','width','height','depth','value','price','createdAt')) {
    if ($null -eq $initial[0].PSObject.Properties[$field]) { throw "У моделі відсутнє поле $field" }
}
Mark 'Список із трьох тестових записів, усі 12 полів і JSON.'

$body = @{ id = 777; from = 'Grace'; to = 'Henry'; content = 'Documents'; deliveryType = 0; weight = 1.5; width = 20; height = 10; depth = 5; value = 200; price = 30; createdAt = '1900-01-01T00:00:00Z' }
$createdResponse = Send POST '/postings' $body
Assert-Equal 201 $createdResponse.Status 'POST'
$created = $createdResponse.Text | ConvertFrom-Json
$newId = [int]$created.id
Assert-Equal 4 $newId 'Новий Id'
Assert-Equal "/postings/$newId" ([string]$createdResponse.Headers['Location']) 'Location'
if ($createdResponse.Text -notmatch '"createdAt"\s*:\s*"[^"\r\n]+Z"') { throw 'CreatedAt має бути UTC.' }
if ([datetime]$created.createdAt -lt [datetime]'2020-01-01') { throw 'CreatedAt взято з клієнтського запиту.' }
Mark 'POST повертає 201, Location, серверний Id та час UTC.'

$read = Send GET "/postings/$newId"
Assert-Equal 200 $read.Status 'GET нового запису'
$readBody = $read.Text | ConvertFrom-Json
Assert-Equal 'Grace' $readBody.from 'Відправник'
Assert-Equal 1.5 $readBody.weight 'Вага'
Mark 'Створений запис доступний через GET за Id.'

$changed = @{ id = 999; from = 'Grace Updated'; to = 'Henry Updated'; content = 'Updated documents'; deliveryType = 2; weight = 3.5; width = 40; height = 25; depth = 15; value = 300; price = 45; createdAt = '1900-01-01T00:00:00Z' }
$put = Send PUT "/postings/$newId" $changed
Assert-Equal 200 $put.Status 'PUT'
$updated = $put.Text | ConvertFrom-Json
foreach ($field in @('from','to','content','deliveryType','weight','width','height','depth','value','price')) {
    Assert-Equal $changed[$field] $updated.$field "Оновлення $field"
}
Assert-Equal $newId ([int]$updated.id) 'Id після PUT'
Assert-Equal $created.createdAt $updated.createdAt 'Час створення після PUT'
Mark 'PUT змінює всі 10 редагованих полів, зберігає Id і CreatedAt.'

$afterPut = Send GET "/postings/$newId"
Assert-Equal $put.Text $afterPut.Text 'Збережені зміни'
$unchanged = Send GET '/postings/1'
$other = $unchanged.Text | ConvertFrom-Json
Assert-Equal $initial[0].from $other.from 'Інший відправник'
Assert-Equal $initial[0].content $other.content 'Вміст іншого запису'
Mark 'Зміни збережені, інший запис не змінено.'

$deleted = Send DELETE "/postings/$newId"
Assert-Equal 204 $deleted.Status 'DELETE'
Assert-Equal '' $deleted.Text 'Тіло відповіді DELETE'
Mark 'DELETE повертає 204 без тіла.'

Assert-Equal 404 (Send GET "/postings/$newId").Status 'Пошук видаленого запису'
Mark 'GET видаленого запису повертає 404.'
Assert-Equal 404 (Send PUT "/postings/$newId" $changed).Status 'Оновлення відсутнього запису'
Mark 'PUT відсутнього запису повертає 404.'
Assert-Equal 404 (Send DELETE "/postings/$newId").Status 'Повторне видалення'
Mark 'DELETE відсутнього запису повертає 404.'

# Порожній список перевіряється на власних початкових навчальних записах.
foreach ($item in $initial) { Assert-Equal 204 (Send DELETE "/postings/$($item.id)").Status 'Очищення навчального списку' }
$empty = Send GET '/postings'
Assert-Equal 200 $empty.Status 'Порожній список'
Assert-Equal '[]' $empty.Text 'JSON порожнього списку'
Mark 'GET порожнього списку повертає 200 та [].'

$afterEmpty = Send POST '/postings' $body
Assert-Equal 201 $afterEmpty.Status 'POST у порожній список'
$afterEmptyBody = $afterEmpty.Text | ConvertFrom-Json
Assert-Equal 5 ([int]$afterEmptyBody.id) 'Id не перевикористано після видалення'
Mark 'Додавання після видалення всіх записів працює, Id не повторюється.'
$oneMore = Send POST '/postings' $body
$oneMoreBody = $oneMore.Text | ConvertFrom-Json
Assert-Equal 6 ([int]$oneMoreBody.id) 'Наступний унікальний Id'
$final = Send GET '/postings'
Assert-Equal 2 @($final.Text | ConvertFrom-Json).Count 'Підсумковий список'
Mark 'Наступний POST отримує унікальний Id, обидва записи збережені.'

$report.Add("`nУспішно: $script:passed/13 перевірок.")
$reportFolder = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../reports'))
New-Item -ItemType Directory -Path $reportFolder -Force | Out-Null
$report | Set-Content -LiteralPath (Join-Path $reportFolder 'http-checks.txt') -Encoding utf8
$report | Where-Object { $_ -match '^PASS|^Успішно' }
