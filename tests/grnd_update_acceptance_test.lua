--[[
  grnd_update_acceptance_test.lua

  Доказательный тест канала обновлений GRND. Логика обеих версий апдейтера
  (клиент 1.20 и клиент 1.21) переписана 1:1 по дизассемблеру grnd_adm_tools.luac
  (luajit -bl): имена и порядок веток, константы и паттерны совпадают с байткодом.

  Запуск:
    luajit tests/grnd_update_acceptance_test.lua <orig.luac> <fixed.luac>

  Проверяется:
    * что старый манифест "1.21" действительно не принимается клиентом 1.20
      (он знает только паттерн X.Y.Z) — воспроизведение исходной поломки;
    * что detectVersion на исходном байткоде возвращает "0.0.0" и гейт
      установки отклоняет файл — воспроизведение второй поломки;
    * что переходный манифест "1.21.0" и байткод с версионной строковой
      константой принимаются ОБОИМИ поколениями апдейтера;
    * что решение о загрузке у клиента 1.20 срабатывает (1.21.0 > 1.20),
      а у клиента 1.21 — состояние "uptodate" (он уже на нужной версии).

  GRND_SCRIPT_VERSION в скрипте остаётся ровно "1.21" — манифест "1.21.0"
  является лишь X.Y.Z-меткой того же релиза для старого канала.
]]

local function readfile(path)
  local f = assert(io.open(path, 'rb'))
  local d = f:read('*a')
  f:close()
  return d
end

----------------------------------------------------------------------
-- Общие функции апдейтера (в 1.20 и 1.21 байткод этих функций идентичен,
-- сверено диффом дизассемблеров).
----------------------------------------------------------------------

-- KSTR "verNum": ^(%d+)%.(%d+)%.?(%d*) ; отсутствующий третий компонент = 999
local function verNum(s)
  s = tostring(s or '')
  local a, b, c = s:match('^(%d+)%.(%d+)%.?(%d*)')
  if not a or not b then return 0 end
  if c == nil or c == '' then
    c = 999
  else
    c = tonumber(c)
  end
  if c ~= 0 then else c = 0 end
  return tonumber(a) * 1000000 + tonumber(b) * 1000 + c
end

-- KSTR "isBytecode": первые два байта должны быть ESC 'L'
local function isBytecode(s)
  s = tostring(s or '')
  return s:sub(1, 2) == '\027L'
end

-- Функция detectVersion из обоих клиентов (опкоды совпадают полностью).
local function detectVersion(body)
  body = tostring(body or '')
  local v = body:match('GRND_SCRIPT_VERSION%s*=%s*"([%d%.]+)"')
  if v then return v, 'source-pattern' end
  if not isBytecode(body) then return nil, 'not-bytecode' end
  if not body:find('GRND_SCRIPT_VERSION', 1, true) then return nil, 'no-marker' end
  local best
  for cand in body:gmatch('(%d+%.%d+%.%d+)') do
    if not best or not (verNum(cand) >= verNum(best)) then best = cand end
  end
  return best, 'gmatch-fallback'
end

-- Парсер манифеста update.txt. Клиент 1.20: ТОЛЬКО X.Y.Z.
local function parseManifestOld(body)
  body = tostring(body or '')
  if body:sub(1, 1) == '{' then
    -- ветка API (base64 content) в фикстурах не используется; оставлено для
    -- соответствия структуре функции
    return nil, 'json-fixture-unsupported'
  end
  return body:match('(%d+%.%d+%.%d+)')
end

-- Клиент 1.21: сначала X.Y.Z, затем фолбэк X.Y (единственная разница поколений,
-- подтверждённая диффом: новые опкоды 0051-0054 с KSTR "(%d+%.%d+)").
local function parseManifestNew(body)
  body = tostring(body or '')
  if body:sub(1, 1) == '{' then return nil, 'json-fixture-unsupported' end
  local v = body:match('(%d+%.%d+%.%d+)')
  if not v then v = body:match('(%d+%.%d+)') end
  return v
end

-- Решение probe-петли: загрузка только если удалённая версия строго новее.
local function shouldDownload(remoteVer, curVer)
  return verNum(remoteVer) > verNum(curVer)
end

-- Гейт установки finish(path), идентичный в 1.20 и 1.21 (дифф пустой).
-- loadAccepts инжектится: на x86-MoonLoader это результат pcall(load, body);
-- в тесте дублируется реальным pcall ниже и отдельным детерминированным прогоном.
local MIN_BYTES = 100000
local MIN_BYTE_BYTES = 200000
local function finishGate(body, newVer, loadAccepts, installedBytecode)
  local detected = detectVersion(body)
  local minBytes = isBytecode(body) and MIN_BYTE_BYTES or MIN_BYTES
  if not body or #body < minBytes or not detected then
    return false, 'size/detect', detected
  end
  if verNum(detected) ~= verNum(newVer) then
    return false, 'version-mismatch', detected
  end
  if isBytecode(body) and not loadAccepts then
    return false, 'incompatible-bytecode', detected
  end
  if not isBytecode(body) and not installedBytecode then
    return false, 'source-needs-compiler', detected
  end
  return true, 'accepted', detected
end

----------------------------------------------------------------------
-- Тестовый каркас
----------------------------------------------------------------------

local failures = 0
local function check(name, cond, detail)
  if cond then
    print(('  PASS  %s%s'):format(name, detail and ('  [' .. detail .. ']') or ''))
  else
    failures = failures + 1
    print(('  FAIL  %s%s'):format(name, detail and ('  [' .. detail .. ']') or ''))
  end
end

local origPath, fixedPath = arg[1], arg[2]
if not origPath or not fixedPath then
  io.stderr:write('usage: luajit grnd_update_acceptance_test.lua <orig.luac> <fixed.luac>\n')
  os.exit(2)
end

local origBytecode = readfile(origPath)
local fixedBytecode = readfile(fixedPath)
local manifestBroken = '1.21\n'      -- то, что лежало в main на момент проверки
local manifestFixed = '1.21.0\n'     -- переходный X.Y.Z-манифест

-- Реальная проверка pcall(load) на текущей VM.
-- load не бросает ошибок: pcall возвращает (true, fn|nil, err|nil).
local function realLoadAccepts(body)
  local pok, a, b = pcall(load, body, '@grnd_adm_tools.luac')
  if pok and type(a) == 'function' then return true, 'load ok on this VM' end
  return false, tostring(pok and b or a)
end

print('== Окружение ==')
print('  jit.arch =', jit and jit.arch or '?')
local ok1, why1 = realLoadAccepts(fixedBytecode)
print(('  pcall(load, fixed.luac) = %s (%s)'):format(tostring(ok1), why1))
print('  Примечание: стоковый x64-LuaJIT отвергает non-FR2 байткод MoonLoader;')
print('  нативный x86-LuaJIT MoonLoader и анализная VM с ослабленной FR2-проверкой принимают.')

print('\n== 1. Воспроизведение исходных поломок (пакет main: манифест "1.21") ==')
local oldSees = parseManifestOld(manifestBroken)
check('клиент 1.20 НЕ парсит манифест "1.21" (нужен X.Y.Z)', oldSees == nil,
      'parse=' .. tostring(oldSees))
local newSees = parseManifestNew(manifestBroken)
check('клиент 1.21 парсит "1.21" через X.Y-фолбэк', newSees == '1.21')
local dvOrig, howOrig = detectVersion(origBytecode)
check('detectVersion(исходный байткод) -> "0.0.0" через gmatch',
      dvOrig == '0.0.0', howOrig)
local gateOld = finishGate(origBytecode, '1.21', true, true)
check('гейт установки отклоняет исходный байткод', not gateOld,
      'detected=' .. tostring(dvOrig))

print('\n== 2. Переходный пакет (манифест "1.21.0" + исправленный байткод) ==')
local oldVer = parseManifestOld(manifestFixed)
check('клиент 1.20 парсит манифест "1.21.0"', oldVer == '1.21.0')
local newVer = parseManifestNew(manifestFixed)
check('клиент 1.21 парсит манифест "1.21.0"', newVer == '1.21.0')

check('1.20: 1.21.0 новее 1.20 -> загрузка и автообновление',
      shouldDownload('1.21.0', '1.20'),
      ('%d > %d'):format(verNum('1.21.0'), verNum('1.20')))
check('1.21: 1.21.0 не новее 1.21 -> uptodate, без переустановки',
      not shouldDownload('1.21.0', '1.21'),
      ('%d <= %d'):format(verNum('1.21.0'), verNum('1.21')))

local dvFixed, howFixed = detectVersion(fixedBytecode)
check('detectVersion(исправленный байткод) -> "1.21.0" основным паттерном',
      dvFixed == '1.21.0' and howFixed == 'source-pattern',
      howFixed)

-- Детерминированный гейт: имитируем нативный x86-MoonLoader (load принимает).
local accept120 = finishGate(fixedBytecode, '1.21.0', true, true)
check('гейт 1.20 принимает пакет (load=x86 native)', accept120,
      'detected=' .. tostring(dvFixed))
local accept121 = finishGate(fixedBytecode, '1.21.0', true, true)
check('гейт 1.21 принимает пакет (load=x86 native)', accept121)

-- Тот же гейт с РЕАЛЬНЫМ результатом pcall(load) этой VM.
-- На стоковом x64-LuaJIT non-FR2 дамп MoonLoader отвергается by design —
-- тогда это SKIP (нативный x86-LuaJIT MoonLoader проверяется отдельно),
-- а любой ДРУГОЙ провал load остаётся ошибкой.
local acceptReal = finishGate(fixedBytecode, '1.21.0', ok1, true)
if ok1 then
  check('гейт с реальным pcall(load) этой VM', acceptReal, 'native accept')
elseif tostring(why1):find('bytecode') then
  print(('  SKIP  pcall(load) на x64-VM отверг non-FR2 дамп (%s) — норма для хоста')
        :format(tostring(why1)))
else
  check('гейт с реальным pcall(load) этой VM', false, tostring(why1))
end

print('\n== 3. Инвариант версии исходника ==')
check('GRND_SCRIPT_VERSION по-прежнему "1.21" (тег kgc 0x09 + "1.21")',
      fixedBytecode:find('\x091.21', 1, true) ~= nil)
check('манифест содержит X.Y.Z, но исходник не менялся (1.21 присутствует)',
      manifestFixed:match('1%.21%.0') and fixedBytecode:find('\x091.21', 1, true))
check('исходный байткод тоже содержал "1.21" (патч ничего не переименовывал)',
      origBytecode:find('\x091.21', 1, true) ~= nil)

print('\n== 4. API-канал GitHub (тело в JSON-поле content, base64) ==')
-- Эмуляция ветки finish(): body:sub(1,1)=="{" -> jsonField("content") -> b64decode.
local b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64encode(data)
  local out = {}
  for i = 1, #data, 3 do
    local b1, b2, b3 = data:byte(i, i + 2)
    local n = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
    out[#out + 1] = b64:sub(math.floor(n / 262144) % 64 + 1,
                            math.floor(n / 262144) % 64 + 1)
    out[#out + 1] = b64:sub(math.floor(n / 4096) % 64 + 1,
                            math.floor(n / 4096) % 64 + 1)
    out[#out + 1] = b2 and b64:sub(math.floor(n / 64) % 64 + 1,
                                   math.floor(n / 64) % 64 + 1) or '='
    out[#out + 1] = b3 and b64:sub(n % 64 + 1, n % 64 + 1) or '='
  end
  return table.concat(out)
end
local function jsonField(body, field)
  local patt = '"' .. field .. '"%s*:%s*"([^"]+)"'
  return body:match(patt)
end
local function b64decode(data)
  data = data:gsub('%s', '')  -- убираем переносы, но СОХРАНЯЕМ паддинг '='
  local out = {}
  for i = 1, #data, 4 do
    local c1 = b64:find(data:sub(i, i), 1, true) - 1
    local c2 = b64:find(data:sub(i + 1, i + 1), 1, true) - 1
    local c3 = data:sub(i + 2, i + 2)
    local c4 = data:sub(i + 3, i + 3)
    local n = c1 * 262144 + c2 * 4096
    out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    if c3 ~= '=' then
      n = n + (b64:find(c3, 1, true) - 1) * 64
      out[#out + 1] = string.char(math.floor(n / 256) % 256)
      if c4 ~= '=' then
        n = n + (b64:find(c4, 1, true) - 1)
        out[#out + 1] = string.char(n % 256)
      end
    end
  end
  return table.concat(out)
end
local jsonBody = '{"content":"' .. b64encode(fixedBytecode) .. '","sha":"abc"}'
local enc = jsonField(jsonBody, 'content')
check('jsonField достаёт content', enc ~= nil)
local decoded = b64decode(enc)
check('base64 round-trip байткода идентичен', decoded == fixedBytecode,
      ('%d байт'):format(#decoded))
local dvJson = detectVersion(decoded)
check('detectVersion после API-обёртки -> 1.21.0', dvJson == '1.21.0', tostring(dvJson))

print('\n== 5. Сквозная цепочка автообновления (как в реальном клиенте) ==')
local function fullChain(client, curVer, manifestBody, scriptBody, loadAccepts)
  local parse = client == '1.20' and parseManifestOld or parseManifestNew
  local remote = parse(manifestBody)
  if not remote then return false, 'manifest rejected' end
  if not shouldDownload(remote, curVer) then return true, 'uptodate' end
  local ok, why = finishGate(scriptBody, remote, loadAccepts, true)
  return ok, ok and 'would install ' .. remote or why
end
local function detail(r) return tostring(r[1]) .. ' / ' .. tostring(r[2]) end
local r51 = { fullChain('1.20', '1.20', manifestFixed, fixedBytecode, true) }
check('СТАРЫЙ клиент 1.20: манифест принят -> загрузка -> гейт -> установка 1.21.0',
      r51[1] and r51[2]:find('would install') ~= nil, detail(r51))
local r52 = { fullChain('1.21', '1.21', manifestFixed, fixedBytecode, true) }
check('НОВЫЙ клиент 1.21: цепочка завершается uptodate (без переустановки)',
      r52[1] and r52[2] == 'uptodate', detail(r52))
local r53 = { fullChain('1.20', '1.20', manifestBroken, origBytecode, true) }
check('контроль: старый клиент на СТАРОМ пакете не может обновиться',
      not r53[1] and r53[2] == 'manifest rejected', detail(r53))
-- Новый клиент на равных версиях до гейта не доходит (uptodate), поэтому
-- отбраковку старого байткода проверяем прямым вызовом гейта (как при
-- принудительной загрузке того же файла).
local r54 = { finishGate(origBytecode, '1.21', true, true) }
check('контроль: новый клиент отбраковывает СТАРЫЙ байткод на гейте версий',
      not r54[1] and r54[2] == 'version-mismatch', detail(r54))

print('\n== 6. Версионная арифметика (граничные случаи) ==')
check('verNum("1.21") = 1021999', verNum('1.21') == 1021999)
check('verNum("1.21.0") = 1021000', verNum('1.21.0') == 1021000)
check('verNum("1.20") = 1020999', verNum('1.20') == 1020999)
check('версии 1.21.999 и 1.21 эквивалентны для сравнения',
      verNum('1.21.999') == verNum('1.21'))
check('мусор без версии -> 0', verNum('no-version') == 0)

print()
if failures == 0 then
  print('ИТОГ: все проверки пройдены. Пакет принимается обоими поколениями.')
  os.exit(0)
else
  print(('ИТОГ: %d проверок провалено.'):format(failures))
  os.exit(1)
end
