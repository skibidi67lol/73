-- killaura v14.0 | nearest-target | melee-mods | viz-equip-guard | cleanup
--[[
    killaura v14.0 — CHANGELOG от v13.0:

    КРИТИЧЕСКОЕ:
    1) [reach runaway] applyMeleeMods прибавлял MeleeReachBoost к УЖЕ раздутому
       _distance на каждый ensureMeleeSvc (каждый тик + каждый свинг) — клиентский
       reach рос ~25 studs/с бесконечно. Теперь идемпотентно: оригинал хранится в
       weak-таблице State.kaDistOrig, всегда пишем orig+boost, один раз на экип
       (kaModsAppliedEq == kaBootEq); stop() возвращает оригинал; слайдеры
       AnimSpeed/ReachBoost переприменяют моды (0 = вернуть норму).
    2) [Slash-спам] PacketAuto слал Slash ДО валидации цели: при нерезолвящемся
       uid/hitPos уходил голый Slash без Impact на каждый тик (~5/с) — палевный
       паттерн для сервера. Теперь: сначала part/uid/hitPos/bone, фейл = ноль
       пакетов; Impact уходит через реальный svc._delay (как в дампе _use), а не
       мгновенно после Slash. Фейл-ретраи гейтятся бэкоффом kaLastAttempt (cd*0.5).

    ОСТАЛЬНОЕ:
    3) Выключение через UI снимает Impact-стиринг сразу (heartbeat-гейт + UI-сеттер
       + tick) — раньше ручные удары после off шли в последнюю (мёртвую) цель.
    4) swingOnce: гейт isLocalAlive — мёртвый игрок не шлёт пакеты.
    5) scanNetworkModule/start: type-check networkModule — не-таблица из
       shared.import роняла rawget, pcall(tick) молча глотал, PacketAuto умирал.
    6) stop(): уничтожаем все Drawing-пулы (кольцо 48 + PacketViz 64+96 Line);
       снимаем hookfunction-хуки (Impact/_use) с восстановлением оригиналов —
       раньше реинжект наслаивал хук на хук и держал старый State; возвращаем
       svc._distance/_timer/_delay и скорость анимаций (AdjustSpeed 1).
    7) clearMeleeBoot: чистим kaMeleeRep — handler-таблица жила после анэквипа.
    8) Перф: hideViz/hidePacketViz по dirty-флагу (0 Drawing-записей в кадре при
       выкл); updateViz один раз в кадр (убран дубль из kaTickCombat); форс-резолв
       ctx не чаще 1с; бэкофф 3с на фейл-сканы resolveInvSvc/scanMeleeSvc/
       scanNetworkModule (+ warn'ы не спамят); pickTarget больше не форсит
       refreshTeamAndRep (форс остался только у dumpDebug); spin-угол по модулю.
    9) Bridge.isActorDead патчится один раз (guard _kaIsActorDeadPatched) —
       раньше каждый реинжект наслаивал обёртку поверх обёртки.
    10) UI-флаги: Distance→KADistance, FOV→KAFOV, Mode→KAMode — коллизии с
        esp.lua (Distance) и silentaim.lua (FOV/Mode) в MacLib.Options затирали
        друг друга. Эти три значения в сохранённых конфигах сбросятся один раз.
]]
--[[
    BRM5KillAura — v8 (PacketAuto rewrite by dump analysis)

    DUMP: BRM5_DUMP/1781658267 (Flux executor, Potassium decompiler)
    Анализ MeleeInventory._use → MeleeInventoryReplicator.Impact:

    Реальная последовательность пакетов при ударе (из дампа):
      1. FireServer("InventoryAction", "Slash", N)          ← немедленно
      2. task.delay(svc._delay, ...)
         FireServer("InventoryAction", "Impact", v3, uid, bone)  ← через _delay

    Fixes vs v7:
    1) [PacketAuto FIX #1] Slash-пакет теперь ОТПРАВЛЯЕТСЯ в PacketAuto
       (ранее пропускался через noSwing=true — сервер не знал о замахе).
    2) [PacketAuto FIX #2] Impact теперь отправляется через svc._delay сек
       (ранее — мгновенно; сервер мог отклонять Impact без предшествующего Slash).
    3) [PacketAuto FIX #3] kaUseThreadActive освобождается через weaponDelay+buf
       вместо cd — устранена блокировка следующего удара.
    4) triggerGameMeleeUse возвращает weaponDelay (а не cd) в PacketAuto —
       performSwing корректно вычисляет cooldown.
    5) LegitAuto логика не изменена.
]]
return function(Lib)
local Bridge = Lib.Bridge
local CONFIG  = Lib.CONFIG
local State   = Lib.State

-- ══════════════════════════════════════════════════════════════
-- [FLUX FIX #1] Bridge.isActorDead: library проверяет data.alive (lower),
-- Flux ActorClass хранит data.Alive (upper) → всё инвертировано.
-- Патчим сразу после получения Bridge, до любого использования.
-- v14: guard — патчим ОДИН раз. Раньше каждый (ре)лоад модуля наслаивал
-- новую обёртку поверх старой (isEnemyActor зовёт это per-actor per-frame
-- в ESP/SilentAim/killaura), и каждый слой пинил предыдущий инстанс модуля.
-- ══════════════════════════════════════════════════════════════
if not Bridge._kaIsActorDeadPatched then
    Bridge._kaIsActorDeadPatched = true
    local _origDead = Bridge.isActorDead
    Bridge.isActorDead = function(data)
        if type(data) ~= "table" then
            return _origDead and _origDead(data) or false
        end
        -- Flux ActorClass: прямые поля (заглавные)
        local fluxAlive  = rawget(data, "Alive")
        local fluxHealth = rawget(data, "Health")
        if fluxAlive == false then return true end
        if type(fluxHealth) == "number" and fluxHealth <= 0 then return true end
        -- actorData вложенный (library-трекер)
        local ad = rawget(data, "actorData") or rawget(data, "_actorData")
        if type(ad) == "table" then
            if rawget(ad, "Alive") == false    then return true end
            if rawget(ad, "Dead")  == true     then return true end
            local hp = rawget(ad, "Health")
            if type(hp) == "number" and hp <= 0 then return true end
        end
        -- фолбэк на оригинал (проверит data.alive строчную, model, etc.)
        return _origDead and _origDead(data) or false
    end
end

local UIS       = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Players   = game:GetService("Players")
local RunService  = Bridge._RunService
local getCamera   = Bridge._getCamera
local log         = Bridge._log

local newcclosure = newcclosure
local hookfunction = hookfunction
local _kaEnsureUseSpeedHook  -- forward ref: хук скорости ручных ударов (ниже)
local _kaSpawnPacketShock    -- forward ref: спавн shockwave-волны PacketAuto viz
local getgc = getgc

-- ═══════════════════════════════════════════════════════════════════════
-- Luraph PRELUDE (только строковые ключи). Голый `function LPH_*` рушит Luraph.
-- killaura НЕ имел макросов → под Luraph виртуализировался целиком, включая
-- scanNetworkModule (filtergc + getnilinstances→getupvalue×512) и per-frame
-- Heartbeat-тики. Когда рядом загружен obfuscated-silentaim, его VM-замыкания
-- раздувают GC → один синхронный проход скана в VM = мгновенный тотальный фриз.
-- Обёртки ниже держат сканеры и тики нативными.
-- ═══════════════════════════════════════════════════════════════════════
do
    local _E = (getgenv and getgenv()) or _G
    if not _E["LPH_NO_VIRTUALIZE"] then
        local id, nop = function(f) return f end, function() end
        _E["LPH_NO_VIRTUALIZE"] = id
        _E["LPH_JIT_MAX"] = id
        _E["LPH_JIT"] = id
        _E["LPH_ENCFUNC"] = id
        _E["LPH_NO_UPVALUES"] = id
        _E["LPH_ENCSTR"] = id
        _E["LPH_ENCNUM"] = id
        _E["LPH_SKIP"] = id
        _E["LPH_CRASH"] = nop
    end
end

local KA_CONFIG = {
    -- ── Основные ────────────────────────────────────────────────────────────
    KillAura            = false,
    KillAuraDistance    = 25,      -- максимальная дистанция до цели (studs)
    KillAuraFOV         = 360,     -- угол обзора при выборе цели (градусы)
    KillAuraPredictMs   = 290,     -- упреждение velocity цели (0 = выкл)
    -- reach вектора Impact (studs). Раздутое значение = client force-hit:
    -- ДЛЯ КЛИЕНТА мы попали (raycast/spherecast проходит на большую дистанцию).
    -- Цель всё равно выбирается в пределах KillAuraDistance — это лишь длина
    -- вектора Impact, а не радиус выбора.
    KillAuraReach       = 999,
    KillAuraSwingCd     = 0.35,    -- cooldown между ударами (сек)
    KillAuraNoWallCheck = true,    -- отправлять Impact без raycast
    KillAuraForceBone   = "Head",  -- "Head"/"UpperTorso"/"LowerTorso"/nil (nil = авто по raycast)
    KillAuraTickInterval  = 0.2,
    KillAuraPickInterval  = 0.25,
    KillAuraCtxCacheSec   = 1.5,
    -- v13.1: насколько ближе (studs) должен быть новый враг, чтобы KA
    -- переключилась с текущей цели. Гистерезис против дёрганья.
    KillAuraSwitchMargin  = 2.0,
    -- ── Режим ───────────────────────────────────────────────────────────────
    --   "PacketAuto" — авто: Slash+Impact напрямую через net (не требует svc)
    --   "LegitAuto"  — авто: через _use+Impact (с анимацией замаха)
    --   "Hook"       — ручной удар, скрипт перенаправляет Impact на цель
    KillAuraMode     = "Hook",
    -- FIX: было Enum.KeyCode.H — дебаг-дамп висел на H ВСЕГДА, без всякого
    -- UI-контрола. Игрок жал H в игре и получал непонятный вывод в консоль,
    -- выглядело как «захардкоженный кейбинд». Теперь по умолча��ию бинда нет,
    -- клавишу можно назначить в Debug-табе.
    KillAuraDebugKey = nil,
    -- ── Модификации ближнего боя (только клиент — пакеты не меняются) ───────
    -- Применяются к AnimationTrack и клиентскому _distance оружия после экипировки.
    -- Сервер получает стандартные пакеты без учёта этих значений.
    -- v14.1 [BUG#3]: было 2 — ускоряло в т.ч. трек _slashTP (slash-with-
    -- displacement, у него root-motion/лунж): персонажа рывком тащило вперёд на
    -- каждом свинге, а с автосвингом каждые 0.35s это читалось как «толкает».
    -- Теперь 1.0 по умолчанию, а _slashTP исключён из мода скорости совсем.
    MeleeAnimSpeed  = 1,   -- множитель скорости анимации удара (1.0 = норма)
    -- v14.1 [BUG#3]: было 5.0 — +5 studs к РЕАЛЬНОМУ клиентскому _distance
    -- удлиняло луч, которым игра кастует удар, за серверный допуск и добавляло
    -- к reposition-ам. Клампится в getKaReach, но по умолчанию выключаем.
    MeleeReachBoost = 0,   -- +studs к клиентскому _distance (client force-hit; 0 = выкл)
    -- ── Скорость удара (Modify) — ТОЛЬКО для РУЧНЫХ ударов игрока ────────────
    -- Раньше «Modify» менял лишь скорость анимации (визуал), а не темп свингов.
    -- Теперь модифицируется _timer оружия (интервал между свингами в _use-цикле)
    -- через хук _use с флагом self-swing: killaura свингует в СВОЁМ темпе, а
    -- ручные удары (зажал ЛКМ) — ускоренные. Сервер не трогаем (клиентский _timer).
    MeleeSwingSpeed     = false, -- вкл. модификацию темпа ручных ударов
    MeleeSwingSpeedMult = 2.0,   -- 2.0 = вдвое быстрее ручные свинги (_timer/mult)
    MeleeSwingScaleDelay = false,-- также ускорять _delay (slash→impact). Осторожно!
    -- ── Визуализация кольца ──────────���───────────────────────���──────────────
    KillAuraViz          = true,
    KillAuraVizSegments  = 24,    -- число сегментов (24 = баланс плавности/FPS)
    KillAuraVizRadius    = 1.8,   -- базовый радиус кольца
    KillAuraVizThickMin  = 1.3,   -- мин. толщина линии
    KillAuraVizThickMax  = 1.8,   -- макс. толщина линии
    KillAuraVizTiltAmp   = 0.3,   -- амплитуда 3D-наклона
    KillAuraVizWarpAmp   = 0.16,  -- амплитуда органического искривления
    KillAuraVizBreathAmp = 0.10,  -- амплитуда пульсации радиуса
    KillAuraVizBreathFq  = 0.9,   -- частота пульсации (Гц)
    KillAuraVizSpin      = true,  -- плавное вращение искривления
    KillAuraVizSpinSpeed = 1.2,   -- скорость вращения Spin (rad/s)
    KillAuraVizTransparency = 0,  -- 0 = полностью видимое кольцо
    KillAuraVizColorA    = Color3.fromRGB(200, 140, 255),  -- фиолетовый
    KillAuraVizColorB    = Color3.fromRGB(90,  205, 255),  -- голубой
    -- ── Визу����лизация PacketAuto (НЕ кольцо) ──────────────────────────────────
    -- Тактический "corner-bracket" прицел: 4 угла вокруг цели, которые
    -- v13.2 РЕДИЗАЙН: чит-стиль lock-on HUD (Nursultan/CS): плавное вращающееся
    -- кольцо-прицел из сегментов-тиков + аккуратные угловые скобки бокса +
    -- расходящиеся shockwave-кольца на каждый пакет-удар. Всё пулится (0 GC).
    KillAuraPacketViz        = true,
    KillAuraPacketVizColor   = Color3.fromRGB(120, 210, 255), -- базовый (циан-лок)
    KillAuraPacketVizFlash   = Color3.fromRGB(255, 255, 255), -- вспышка удара (белый)
    KillAuraPacketVizThick   = 2.0,   -- толщина линий
    KillAuraPacketVizSegments= 32,    -- сегментов в круге-прицеле (плавность)
    KillAuraPacketVizShock   = true,  -- shockwave-кольца на удар
    KillAuraPacketVizShockN  = 3,     -- сколько одновременных волн
}
for k, v in pairs(KA_CONFIG) do CONFIG[k] = v end

local KA_CHAR_GRACE = 0.3
local kaConn, kaVizConn, kaInputConn, kaCharConn
local kaCharGraceUntil = 0
local kaLastPickT, kaLastDiagT, kaLastPrepT, kaLastFullCtxT = 0, 0, 0, 0
local kaActionTypeInv

-- ══════════════════════════════════════════════════════════════
-- [VIZ] 3D "jello" ring — орбитит вокруг цели с головы до ног,
-- плавно отскакивая от границ (голова/ноги) с эффектом сжатия/растяжения.
-- ══════════════════════════════════════════════════════════════
local kaVizLines  = {}
local kaVizActive = false
-- v14: dirty-флаги «пул реально показан» — hide-циклы гоняются только на
-- переходе shown→hidden, а не 50-210 Drawing-записей КАЖДЫЙ кадр при выкл.
local kaVizShown  = false
local kaPvShown   = false
-- v13.1: время последнего PacketAuto-удара — для вспышки прицела-скобок
local kaPacketPulse = -999
-- Smooth warp
local kaVizWarpAmpCur = 0.0
local kaVizBreathCur  = 0.0
-- v13.1: сглаженная «вспышка» кольца на успешный удар (impact flash)
local kaVizFlash      = 0.0
-- Spin
local kaVizSpinAngle  = 0.0
-- Оптимизация: кэш предвычисленных cos/sin для текущего segN
local kaVizAngleCacheN   = 0    -- segN для которого кэш актуален
local kaVizCosCache      = {}   -- cos[(i/segN)*2pi], i=0..segN-1
local kaVizSinCache      = {}   -- sin[(i/segN)*2pi]
-- Переиспользуемые таблицы (без аллокации в горячем цикле)
local kaVizScrX  = {}   -- screen X
local kaVizScrY  = {}   -- screen Y
local kaVizVis   = {}   -- visible flag
local kaVizColR  = {}   -- color R
local kaVizColG  = {}   -- color G
local kaVizColB  = {}   -- color B


-- кэш LocalActor для getFluxLocalActor
local _fluxActorCache      = nil
local _fluxActorCacheTime  = 0
local FLUX_ACTOR_CACHE_TTL = 0.5  -- секунд

local function now() return os.clock() end

local function setPhase(phase, skip)
    State.kaLastPhase = phase
    if skip ~= nil then State.kaLastSkip = skip end
end

local function clearKaTarget()
    State.kaTarget     = nil
    State.kaTargetUid  = nil
    State.kaAimPart    = nil
    State.kaAimPoint   = nil
    State.kaTargetTime = 0
end

local function releaseSwingState()
    State.kaSwingBusy   = false
    State.kaImpactSteer = false
    State.kaImpactPart  = nil
    State.kaImpactUid   = nil
end

local function clearMeleeBoot()
    State.kaCtx            = nil
    State.kaCtxEq          = nil
    State.kaCtxTime        = 0
    State.kaMeleeSvc       = nil
    State.kaBootEq         = nil
    State.kaUseEnv         = nil
    State.kaSvcSrc         = nil
    State.kaWarmupDone     = false
    State.kaWarmupEq       = nil
    State.kaWarmupBusy     = false
    State.kaModsAppliedEq  = nil
    -- v14: раньше kaMeleeRep НЕ чистился — последняя handler-таблица жила
    -- после анэквипа/смерти до конца сессии.
    State.kaMeleeRep       = nil
    -- v17: RaycastParams мили-репликатора — тоже отпускаем, иначе держим ссылку
    -- на объект прошлого оружия/жизни (и теряем строгость опознания удара).
    State.kaMeleeRayParams = nil
    State.kaGcScanEq       = nil
    State.kaUseThreadActive = false
    State.kaUseThreadSince  = 0
    -- сбрасываем кэш LocalActor при смене оружия / рестарте
    _fluxActorCache     = nil
    _fluxActorCacheTime = 0
end

local function getHandlerMethod(handler, name)
    if type(handler) ~= "table" or type(name) ~= "string" then return nil end
    local direct = rawget(handler, name)
    if type(direct) == "function" then return direct end
    local mt = getmetatable(handler)
    if type(mt) == "table" then
        local fn = rawget(mt, name)
        if type(fn) == "function" then return fn end
        local idx = rawget(mt, "__index")
        if type(idx) == "table" then
            local fn2 = rawget(idx, name)
            if type(fn2) == "function" then return fn2 end
        end
    end
    local ok, fn = pcall(function() return handler[name] end)
    if ok and type(fn) == "function" then return fn end
    return nil
end

local function normalizeEqUid(eq)
    if eq == nil then return nil end
    return tostring(eq)
end

-- ══════════════════════════════════════════════════════════════
-- [FLUX FIX #2] getFluxLocalActor — резолвит LocalActor из
-- ReplicatorService. Именно здесь хранятся Alive и Health.
-- Humanoid в Flux-играх НЕ является источником истины.
-- ══════════════════════════════════════════════════════════════
local function getFluxLocalActor()
    local t = now()
    if _fluxActorCache ~= nil and t - _fluxActorCacheTime < FLUX_ACTOR_CACHE_TTL then
        return _fluxActorCache
    end

    local found = nil

    -- Вариант 1: через Bridge.resolveLocalActor (самый надёжный)
    if Bridge.resolveLocalActor then
        local ok, _, a = pcall(Bridge.resolveLocalActor, false)
        if ok and type(a) == "table" and rawget(a, "Alive") ~= nil then
            found = a
        end
    end

    -- Вариант 2: через State.localClient -> getActorTable
    if not found then
        local client = State.localClient
        if client and Bridge.getActorTable then
            local a = Bridge.getActorTable(client)
            if type(a) == "table" and rawget(a, "Alive") ~= nil then
                found = a
            end
        end
    end

    -- Вариант 3: getgc УДАЛЁН — вызывал lag spike при экипировке оружия (итерация всего gc heap)

    _fluxActorCache     = found
    _fluxActorCacheTime = t
    return found
end

-- ═══════════════════════════════���══════════════════════════════
-- [FLUX FIX #3] isLocalAlive: читаем Actor.Alive / Actor.Health
-- вместо Humanoid.Health
-- ════════��═════════════════════════════════════════════════════
local function isLocalAlive()
    if now() < kaCharGraceUntil then return true end

    -- Приоритет 1: Flux ActorClass
    local fluxActor = getFluxLocalActor()
    if fluxActor ~= nil then
        local alive  = rawget(fluxActor, "Alive")
        local health = rawget(fluxActor, "Health")
        -- alive == false → точно мёртв
        if alive == false then return false end
        -- health <= 0 → мёртв (ActorClass.Update ставит Alive=false при health<=0,
        -- но между репликациями может быть рассинхрон)
        if type(health) == "number" and health <= 0 then return false end
        -- alive == true → живой (не трогаем Humanoid)
        if alive == true then return true end
        -- alive == nil: ещё не реплицировалось — продолжаем на фолбэк
    end

    -- Фолбэк: Humanoid (для игр без Flux, или до первой репликации)
    local lp   = Players.LocalPlayer
    local char = lp and lp.Character
    if not char or not char.Parent then return false end
    local hum  = char:FindFirstChildOfClass("Humanoid")
    if hum then return hum.Health > 0 end
    return true
end

local function onLifeState()
    if not isLocalAlive() then
        if not State.kaWasDead then
            State.kaWasDead = true
            clearKaTarget()
            releaseSwingState()
            clearMeleeBoot()
        end
        return false
    end
    if State.kaWasDead then
        State.kaWasDead = false
        clearMeleeBoot()
        releaseSwingState()
        pcall(function()
            if Bridge.resolveLocalActor then Bridge.resolveLocalActor(true) end
        end)
    end
    return true
end

local function kaLosOrigin(actor)
    if type(actor) == "table" then
        local cf = rawget(actor, "CFrame")
        if typeof(cf) == "CFrame" then return cf.Position end
    end
    local cam = getCamera()
    if cam then return cam.CFrame.Position end
    if Bridge.getAimLosOrigin then return Bridge.getAimLosOrigin() end
    return Vector3.zero
end

local function kaDist()
    local d = CONFIG.KillAuraDistance
    return (type(d) == "number" and d > 0) and d or 30
end

-- v13.3: строгий детектор ХОЛОДНОГО оружия.
-- По дампу: MeleeInventoryReplicator имеет Slash+Breach+Impact; огнестрел
-- (Firearm) имеет Discharge/ADS/Reload и НЕ имеет Slash/Breach. Раньше проверка
-- шла только по Impact, а fallback-цикл возвращал ЛЮБОЙ melee из инвентаря даже
-- когда экипирован ствол → KillAura «работала с любым оружием». Теперь:
--   • melee = есть Slash И Breach, и НЕТ Discharge/ADS (не ствол);
--   • берём ТОЛЬКО реально экипированный слот (inv[_equipped]), без fallback.
local function isMeleeRep(v)
    if type(v) ~= "table" then return false end
    if getHandlerMethod(v, "Slash")  == nil then return false end
    if getHandlerMethod(v, "Breach") == nil then return false end
    -- явный отсев огнестрела/прочих
    if getHandlerMethod(v, "Discharge") ~= nil then return false end
    if getHandlerMethod(v, "ADS")       ~= nil then return false end
    return true
end

local function getEquippedRep(actor)
    if type(actor) ~= "table" then return nil end
    local eq  = rawget(actor, "_equipped")
    local inv = rawget(actor, "_inventory")
    if not eq or type(inv) ~= "table" then return nil end
    -- Т��ЛЬКО экипированный предмет. Если это не melee → nil (KillAura спит).
    local h = inv[eq] or inv[tonumber(eq)]
    if isMeleeRep(h) then return h end
    return nil
end

local function peekLocalActorLight()
    if not isLocalAlive() then return nil, nil end
    local client = State.localClient
    if client and Bridge.getActorTable then
        local actor = Bridge.getActorTable(client)
        if type(actor) == "table" then return client, actor end
    end
    if Bridge.resolveLocalActor then return Bridge.resolveLocalActor(false) end
    return nil, nil
end

local function resolveActor(ctx)
    if ctx and type(ctx.actor) == "table" and getEquippedRep(ctx.actor) then
        return ctx.actor
    end
    local _, a = peekLocalActorLight()
    if a and getEquippedRep(a) then return a end
    if Bridge.resolveLocalActor then
        local _, a2 = Bridge.resolveLocalActor(false)
        if a2 then return a2 end
    end
    return ctx and ctx.actor or nil
end

local function refreshTeamAndRep(force)
    local t = now()
    if not force and t - kaLastPrepT < 0.35 then return end
    kaLastPrepT = t
    if Bridge.refreshLocalTeamKey then pcall(Bridge.refreshLocalTeamKey) end
    if Bridge.tickRepSyncBatch then pcall(Bridge.tickRepSyncBatch, force and 18 or 10) end
end

local function kaRefPos(data)
    if not data then return nil end
    if data.inInactiveWorld and typeof(data.adPos) == "Vector3" then return data.adPos end
    local ad = data.actorData
    if type(ad) == "table" then
        local p = rawget(ad, "SimulatedPosition") or rawget(ad, "ServerPosition") or rawget(ad, "Position")
        if typeof(p) == "Vector3" then return p end
    end
    -- Flux ActorClass прямые поля позиции
    local sp = rawget(data, "SimulatedPosition") or rawget(data, "ServerPosition") or rawget(data, "Position")
    if typeof(sp) == "Vector3" then return sp end
    local root = data.root
    if root and root.Parent and root:IsA("BasePart") then return root.Position end
    if data.model and data.model.Parent then
        local p = data.model:FindFirstChild("HumanoidRootPart")
            or data.model:FindFirstChild("UpperTorso")
            or data.model:FindFirstChild("Head")
        if p and p:IsA("BasePart") then return p.Position end
    end
    return nil
end

local function resolveAim(data)
    if not data then return nil, nil end
    local point = kaRefPos(data)
    local part  = (Bridge.getSilentAimPart and Bridge.getSilentAimPart(data)) or data.root
    if part and part:IsA("BasePart") and part.Parent and typeof(point) == "Vector3" then
        return part, point
    end
    if typeof(point) == "Vector3" and data.model and data.model.Parent then
        local p = data.model:FindFirstChild("Head")
            or data.model:FindFirstChild("UpperTorso")
            or data.model:FindFirstChild("HumanoidRootPart")
            or data.root
        if p and p:IsA("BasePart") then return p, point end
    end
    if typeof(point) == "Vector3" then return part, point end
    return nil, nil
end

-- v13.3 FIX ложные цели: враг может присутствова���ь в State.actors только как
-- данные позиции (actorData) БЕЗ физической модели/частей — бить его нечем, но
-- раньше он проходил как валидная цель (viz + пакеты в пустоту). Требуем наличие
-- хотя бы одной РЕАЛЬНОЙ R15-части (или валидного root) в workspace.
-- OPT: прове��яем через FindFirstChild по списку ключевых частей (0 аллокаций),
-- вместо GetChildren() (таблица на каждый вызов) — вызывается на каждого актора
-- каждый тик, так что аллокации тут дорогие.
local KA_HIT_PARTS = { "HumanoidRootPart", "Head", "UpperTorso", "LowerTorso" }
local function hasHittablePart(data)
    if type(data) ~= "table" then return false end
    local root = data.root
    if root and typeof(root) == "Instance" and root:IsA("BasePart") and root.Parent then
        return true
    end
    local model = data.model
    if model and typeof(model) == "Instance" and model.Parent then
        for i = 1, #KA_HIT_PARTS do
            local ch = model:FindFirstChild(KA_HIT_PARTS[i])
            if ch and ch:IsA("BasePart") then return true end
        end
    end
    return false
end

local function buildTargetPool(actor)
    local losOrigin = kaLosOrigin(actor)
    local maxDist   = kaDist()
    local pool = {}
    if Bridge.collectAimActorCandidates and getCamera() then
        local ok, result = pcall(Bridge.collectAimActorCandidates, getCamera(), losOrigin, maxDist,
            math.min((CONFIG.KillAuraFOV or 360) * 0.5, 179))
        if ok and type(result) == "table" and #result > 0 then
            -- отсеиваем кандидатов без физического тела (ложные цели)
            local filtered = {}
            for _, d in ipairs(result) do
                if hasHittablePart(d) then filtered[#filtered + 1] = d end
            end
            if #filtered > 0 then return filtered, "ka.aim" end
        end
    end
    for _, data in pairs(State.actors or {}) do
        if Bridge.isEnemyActor and not Bridge.isEnemyActor(data) then continue end
        if Bridge.isActorDead   and Bridge.isActorDead(data)     then continue end
        if not hasHittablePart(data) then continue end   -- нет тела → пропускаем
        local pos = kaRefPos(data)
        if typeof(pos) ~= "Vector3" then continue end
        if (pos - losOrigin).Magnitude <= maxDist then
            pool[#pool + 1] = data
        end
    end
    return pool, (#pool > 0 and "ka.state" or "ka.empty")
end

local function commitPick(best, part, point, source)
    State.kaTarget       = best
    State.kaTargetUid    = best and best.uid or nil
    State.kaAimPart      = part
    State.kaAimPoint     = point
    State.kaTargetTime   = now()
    State.kaLastPickSource = source
    kaLastPickT = now()
    return best, part, point
end

local function pickTarget(force, actor)
    local iv = CONFIG.KillAuraPickInterval or 0.25
    if not force and State.kaTarget and typeof(State.kaAimPoint) == "Vector3"
        and now() - kaLastPickT < iv then
        return State.kaTarget, State.kaAimPart, State.kaAimPoint
    end
    -- v13.1: запоминаем текущую цель ДО очистки, чтобы применить гистерезис
    -- (не дёргаться между двумя почти равноудалёнными врагами).
    local prevUid = State.kaTargetUid
    -- v14: НЕ форсим — форс-пик из тика (каждые 0.2-0.25с) пробивал 0.35с
    -- троттл refreshLocalTeamKey+tickRepSyncBatch. Форс-вариант остался
    -- только у dumpDebug (он зовёт refreshTeamAndRep(true) напрямую).
    refreshTeamAndRep(false)
    clearKaTarget()
    local pool, source = buildTargetPool(actor)
    if #pool == 0 then
        State.kaLastPickSource = source
        return nil, nil, nil
    end
    local losOrigin = kaLosOrigin(actor)
    local best, bestPart, bestPoint, bestDist
    local prevData, prevPart, prevPoint, prevD
    for _, data in ipairs(pool) do
        local part, point = resolveAim(data)
        if typeof(point) ~= "Vector3" then continue end
        local d = (point - losOrigin).Magnitude
        -- Выбираем ближайшего по Magnitude (дистанция от глаз до hitpoint)
        local inRange = d <= kaDist()
        if inRange and (best == nil or d < bestDist) then
            best, bestPart, bestPoint, bestDist = data, part, point, d
        end
        -- фиксируем прошлую цель, если она всё ещё в пуле
        if inRange and prevUid ~= nil and data.uid == prevUid then
            prevData, prevPart, prevPoint, prevD = data, part, point, d
        end
    end
    if not best then
        State.kaLastPickSource = source .. ":filtered"
        return nil, nil, nil
    end
    -- Гистерезис: переключаемся на нового ближайшего, только если он ощутимо
    -- ближе текущей цели (по умолчанию на 2 studs). Иначе держим прежнюю —
    -- убирает дёрганье, но при этом ВСЕГДА берёт реально ближайшего.
    if prevData and best ~= prevData then
        local margin = CONFIG.KillAuraSwitchMargin or 2.0
        if prevD - bestDist < margin then
            best, bestPart, bestPoint = prevData, prevPart, prevPoint
        end
    end
    return commitPick(best, bestPart, bestPoint, source)
end

local function validateTarget(actor)
    local target = State.kaTarget
    if not target then return false end
    if Bridge.isEnemyActor and not Bridge.isEnemyActor(target) then clearKaTarget() return false end
    if Bridge.isActorDead   and Bridge.isActorDead(target)     then clearKaTarget() return false end
    if not hasHittablePart(target) then clearKaTarget() return false end  -- тело исчезло
    local pos = kaRefPos(target) or (State.kaAimPart and State.kaAimPart.Position) or State.kaAimPoint
    if typeof(pos) ~= "Vector3" then clearKaTarget() return false end
    if (pos - kaLosOrigin(actor)).Magnitude > kaDist() + 1 then
        clearKaTarget() return false
    end
    local part, point = resolveAim(target)
    State.kaAimPart  = part  or State.kaAimPart
    State.kaAimPoint = point or pos
    return true
end

local function resolveMeleeContext(force)
    if not isLocalAlive() and force ~= true then return nil end
    local _, actor
    if force and Bridge.resolveLocalActor then
        _, actor = Bridge.resolveLocalActor(true)
    else
        _, actor = peekLocalActorLight()
    end
    if not actor then
        clearMeleeBoot()
        return nil
    end
    local eqStr = normalizeEqUid(rawget(actor, "_equipped")) or ""
    if not force and State.kaCtx and State.kaCtxEq == eqStr
        and now() - (State.kaCtxTime or 0) < (CONFIG.KillAuraCtxCacheSec or 1.5) then
        return State.kaCtx
    end
    local rep = getEquippedRep(actor)
    if not rep then
        if State.kaCtxEq ~= eqStr then clearMeleeBoot() end
        -- v13.3: экипировано НЕ холодное оружие → сбрасываем melee-контекст,
        -- иначе viz/пакеты продолжат работать на устаревшем isMelee=true.
        State.kaCtx     = nil
        State.kaTarget  = nil
        State.kaCtxEq   = eqStr
        State.kaCtxTime = now()
        return nil
    end
    local item = (Bridge.itemFromActorInventory
        and Bridge.itemFromActorInventory(actor, rawget(actor, "_equipped")))
        or rawget(rep, "_item")
    local ctx = {
        actor   = actor,
        handler = rep,
        item    = item,
        isMelee = true,
        info = {
            caliber = "melee",
            name    = rawget(rep, "_build") or "melee",
            slot    = "Melee",
        },
    }
    if force and Bridge.loadSharedModules and Bridge.buildWeaponContext and item then
        local ok, mods = pcall(Bridge.loadSharedModules)
        if ok then
            local ok2, built = pcall(Bridge.buildWeaponContext, actor, item, "Melee", mods)
            if ok2 and type(built) == "table" then
                built.isMelee = true
                built.handler = rep
                ctx = built
            end
        end
    end
    State.kaCtx    = ctx
    State.kaCtxEq  = eqStr
    State.kaCtxTime = now()
    State.kaMeleeRep = rep
    -- ═══════════════════════════════════════════════════════════════════
    -- v17 [КРИТИЧНО: хук ломал ШАГИ игры и морозил CFrame актора]
    --
    -- Публикуем RaycastParams САМОГО мили-репликатора. По дампу
    -- MeleeInventoryReplicator (строки 30 и 128) удар кастуется ровно так:
    --     _params = v13                                   -- свой объект
    --     workspace:Raycast(v26, p25, p24._params)
    --     or workspace:Spherecast(v26, 1, p25, p24._params)
    -- Значит мили-рейкаст однозначно опознаётся по идентичности _params.
    --
    -- Зачем: перехват в namecall срабатывал на ЛЮБОЙ workspace:Raycast, пока
    -- идёт замах. В том числе на ActorClass._getMaterial (строка 465) — это
    -- рейкаст ВНИЗ (0,-3.5,0) для материала под ногами. Он получал подделанный
    -- хит с частью тела врага, дальше _doFootstep падал, а он вызывается из
    -- ActorClass.Update ДО записи p294.CFrame = v418 (строка 3005). Итог:
    -- CFrame актора перестаёт обновляться прямо во время удара — игрока
    -- «косоебит туда-сюда». Ошибка из скриншота ровно про этот стек.
    -- ═══════════════════════════════════════════════════════════════════
    if type(rep) == "table" then
        local prm = rawget(rep, "_params")
        if typeof(prm) == "RaycastParams" then
            State.kaMeleeRayParams = prm
        end
    end
    return ctx
end

local function isMeleeSvcTable(obj)
    if type(obj) ~= "table" then return false end
    if getHandlerMethod(obj, "_use")    == nil then return false end
    if getHandlerMethod(obj, "Impact") ~= nil  then return false end
    return true
end

-- Ищет MeleeInventory handler в таблице _inventories InventoryService
local function searchInvSvcHandlers(invSvc, eqUid)
    local inventories = rawget(invSvc, "_inventories")
    if type(inventories) ~= "table" then return nil end
    -- Первый проход: совпадение по UID
    for _, group in pairs(inventories) do
        if type(group) ~= "table" then continue end
        for _, slot in ipairs(group) do
            if type(slot) ~= "table" then continue end
            local h = rawget(slot, "Handler")
            if isMeleeSvcTable(h) then
                local uid = normalizeEqUid(rawget(slot, "UID"))
                if eqUid == nil or uid == eqUid then
                    return h, "uid"
                end
            end
        end
    end
    -- Второй проход: любой MeleeInventory (экипирован — Equipped.UID)
    local equipped = rawget(invSvc, "Equipped")
    local equippedUid = equipped and normalizeEqUid(rawget(equipped, "UID"))
    for _, group in pairs(inventories) do
        if type(group) ~= "table" then continue end
        for _, slot in ipairs(group) do
            local h = type(slot) == "table" and rawget(slot, "Handler") or nil
            if isMeleeSvcTable(h) then
                local slotUid = normalizeEqUid(rawget(slot, "UID"))
                -- Предпочитаем экипированный
                if equippedUid and slotUid == equippedUid then
                    return h, "equipped"
                end
            end
        end
    end
    -- Третий проход: первый попавшийся
    for _, group in pairs(inventories) do
        if type(group) ~= "table" then continue end
        for _, slot in ipairs(group) do
            local h = type(slot) == "table" and rawget(slot, "Handler") or nil
            if isMeleeSvcTable(h) then return h, "any" end
        end
    end
    return nil
end

-- Получить InventoryService синглтон через getnilinstances + require (кэш Roblox)
-- v14: бэкофф 3с после фейла — раньше полный проход по nil-инстансам (+ warn)
-- повторялся на каждый свинг/тик, пока svc не находился.
local kaInvSvcFailT = 0
local function resolveInvSvc()
    if now() - kaInvSvcFailT < 3 then return nil, nil end
    -- Единственный метод: getnilinstances() → require()
    -- Flux уничтожает свои ModuleScript'ы (script:Destroy) после загрузки,
    -- они живут в nil-parent, но require()-кэш Roblox держит результат в памяти.
    -- require(уничтоженный ModuleScript) → мгновенно возвращает синглтон из кэша.
    if type(getnilinstances) == "function" then
        local ok0, nils = pcall(getnilinstances)
        if ok0 and type(nils) == "table" then
            for _, inst in ipairs(nils) do
                local okC, cls = pcall(function() return inst.ClassName end)
                if not okC or cls ~= "ModuleScript" then continue end
                local okN, nm  = pcall(function() return inst.Name end)
                if not okN or nm ~= "InventoryService" then continue end
                local okR, svc = pcall(require, inst)
                if okR and type(svc) == "table" and rawget(svc, "_inventories") ~= nil then
                    return svc, "getnilinstances.require"
                end
            end
        end
        warn("[KA] resolveInvSvc: getnilinstances не нашёл InventoryService ModuleScript.")
    else
        warn("[KA] resolveInvSvc: getnilinstances недоступен в этом экзекуторе.")
    end
    kaInvSvcFailT = now()
    return nil, nil
end

-- v14: бэкофф 3с на фейл всего скана (гейтит и warn-спам ниже)
local kaSvcScanFailT = 0
local function scanMeleeSvc(actor, rep, eqUid)
    if now() - kaSvcScanFailT < 3 then return nil end
    -- Получаем InventoryService любым доступным способом
    local invSvc, invSrc = resolveInvSvc()
    if type(invSvc) == "table" then
        local h, hSrc = searchInvSvcHandlers(invSvc, eqUid)
        if h then
            State.kaSvcSrc = "invSvc." .. (hSrc or "?") .. "/" .. (invSrc or "?")
            return h
        end
        warn("[KA] scanMeleeSvc: InventoryService найден (", invSrc, ") но MeleeInventory handler не найден.",
             "eqUid=", tostring(eqUid), "_inventories keys=",
             (function() local s=""; for k,_ in pairs(rawget(invSvc,"_inventories") or {}) do s=s..tostring(k).."," end return s end)())
    else
        warn("[KA] scanMeleeSvc: InventoryService не найден ни одним из 6 путей.")
    end
    -- Запасной вариант: ищем _use прямо в rep и его полях
    if type(rep) == "table" then
        for _, key in ipairs({"_inventoryService", "_service", "_svc", "_parent", "_handler"}) do
            local v = rawget(rep, key)
            if isMeleeSvcTable(v) then
                State.kaSvcSrc = "rep." .. key
                return v
            end
        end
        -- rep._actor может держать ссылку на InventoryService через actor
        local repActor = rawget(rep, "_actor")
        if type(repActor) == "table" then
            for _, key in ipairs({"_inventoryService", "InventoryService", "_invSvc"}) do
                local v = rawget(repActor, key)
                if type(v) == "table" then
                    local h2 = searchInvSvcHandlers(v, eqUid)
                    if h2 then
                        State.kaSvcSrc = "rep._actor." .. key
                        return h2
                    end
                end
            end
        end
    end
    warn("[KA] scanMeleeSvc: svc не найден. rep=", tostring(rep), "actor=", tostring(actor))
    kaSvcScanFailT = now()
    return nil
end

-- getupvalue-скан (×32) по _use. Под Luraph нативно (LPH_NO_VIRTUALIZE).
local extractUseEnv = LPH_NO_VIRTUALIZE(function(svc)
    if not svc then return nil end
    if State.kaUseEnv and State.kaUseEnv.svc == svc then return State.kaUseEnv end
    local env = {
        svc      = svc,
        delay    = rawget(svc, "_delay"),
        distance = rawget(svc, "_distance"),
        v3       = Bridge.vector3ToTable,
    }
    local useFn = getHandlerMethod(svc, "_use")
    if type(useFn) == "function" and type(debug) == "table" and type(debug.getupvalue) == "function" then
        for i = 1, 32 do
            local ok, _, val = pcall(debug.getupvalue, useFn, i)
            if not ok then break end
            if not env.net and type(val) == "table"
                and type(rawget(val, "FireServer")) == "function" then
                env.net = val
            elseif type(val) == "table" and rawget(val, "ActionType") then
                env.enum = val
            end
        end
    end
    if type(shared) == "table" and type(shared.import) == "function" then
        local ok, v3 = pcall(shared.import, "vector3toTable")
        if ok and type(v3) == "function" then env.v3 = v3 end
    end
    State.kaUseEnv = env
    return env
end)

local function getActionTypeInv()
    if kaActionTypeInv then return kaActionTypeInv end
    if State.kaUseEnv and State.kaUseEnv.enum and State.kaUseEnv.enum.ActionType then
        kaActionTypeInv = State.kaUseEnv.enum.ActionType.Inventory
        return kaActionTypeInv
    end
    if type(shared) == "table" and type(shared.import) == "function" then
        local ok, e = pcall(shared.import, "Enum")
        if ok and type(e) == "table" and e.ActionType then
            kaActionTypeInv = e.ActionType.Inventory
            return kaActionTypeInv
        end
    end
    return nil
end

-- v5: weapon-cfg независимые тайминги — всё из CONFIG.
-- reach: если KillAuraReach не задан — берём НАСТОЯЩИЙ weapon._distance
-- (без искусственного обхода), fallback 8.
-- v14.1 [BUG#3] КЛАМП REACH — причина «меня что-то отталкивает при ноже».
-- Сырой KillAuraReach=999 давал вектор Impact длиной 999 studs. Сервер
-- валидирует мили-удар по позиции/фейсингу атакующего: попадание в голову за
-- 999 studs геометрически невозможно → античит отклонял удар и ОТКАТЫВАЛ
-- позицию игрока к последней валидной (rubberband). Тот же механизм описан в
-- movement.lua:142 для спуфа прицела — на мили он срабатывает так же.
-- Клампим к реальному _distance оружия × коэффициент: force-hit сохраняется,
-- но геометрия остаётся правдоподобной и сервер её принимает.
local KA_REACH_MULT = 1.6   -- запас над честным reach (наклон/предикт), не «телепорт»
local function getKaReach()
    local svc = State.kaMeleeSvc
    -- честный reach: оригинал из kaDistOrig (до MeleeReachBoost), иначе текущее поле
    local base
    if svc and State.kaDistOrig and type(State.kaDistOrig[svc]) == "number" then
        base = State.kaDistOrig[svc]
    else
        base = svc and rawget(svc, "_distance")
    end
    if type(base) ~= "number" or base <= 0 then base = 8 end
    local cap = base * KA_REACH_MULT
    local r = CONFIG.KillAuraReach
    if type(r) == "number" and r > 0 then
        return math.min(r, cap)
    end
    return cap
end

-- v15 [BUG «отталкивает»]: ОТДЕЛЬНЫЙ, жёсткий reach для ПАКЕТНОГО пути.
--
-- getKaReach() выше даёт запас ×1.6 — он для клиентского рейкаста (LegitAuto),
-- где перебор не виден серверу. Но в PacketAuto Vector3 уходит на сервер
-- НАПРЯМУЮ, и сервер валидирует его как хит луча длиной weapon.Reach из груди
-- атакующего. Реальные значения Reach в дампе игры: 5 (20 оружий), 6 (4), 7 (2).
-- Поэтому здесь запас минимальный — только на латентность/предикт, +1 stud.
-- Фолбэк 5, а не 8: это модальное значение по дампу (20 из 26 оружий).
local KA_PACKET_REACH_MARGIN = 1.0
local function packetImpactReach()
    local svc = State.kaMeleeSvc
    local base
    -- честный оригинал ДО MeleeReachBoost (boost клиентский, сервер о нём не знает)
    if svc and State.kaDistOrig and type(State.kaDistOrig[svc]) == "number" then
        base = State.kaDistOrig[svc]
    elseif svc then
        base = rawget(svc, "_distance")
    end
    if type(base) ~= "number" or base <= 0 then base = 5 end
    -- v16: страховка. kaDistOrig — weak-таблица: после респавна запись про
    -- оригинал может исчезнуть, пока kaMeleeSvc ещё указывает на svc с уже
    -- раздутым _distance. По дампу максимальный Reach мили-оружия = 7 —
    -- всё выше означает «поле уже промодифицировано», такому не верим.
    if base > 7 then base = 7 end
    return base + KA_PACKET_REACH_MARGIN
end

local function getKaTimings()
    local cd = CONFIG.KillAuraSwingCd or 0.35
    return getKaReach(), cd
end


-- Проверяет что MeleeSvc уже найден и сбутстраплен для данного eqUid
local function meleeSvcReady(eqUid)
    return State.kaMeleeSvc ~= nil
        and State.kaBootEq == eqUid
        and State.kaWarmupDone == true
end

-- Финализирует инициализацию svc: извлекает useEnv и помечает warmup=done
-- Применяет клиентские модификации к melee handler (только визуал/анимация).
-- Сервер не затронут: _delay / _distance меняются только в памяти клиента.
local function applyMeleeMods(svc)
    if not svc then return end
    -- v14 [CRITICAL]: идемпотентность. Вызывается на КАЖДЫЙ ensureMeleeSvc
    -- (каждый тик + каждый свинг), а base перечитывался из УЖЕ раздутого
    -- _distance → клиентский reach рос ~25 studs/с бесконечно. Теперь:
    -- один раз на экип (kaBootEq выставлен ДО вызова в ensureMeleeSvc),
    -- слайдеры сбрасывают kaModsAppliedEq для переприменения.
    if State.kaModsAppliedEq == State.kaBootEq then return end
    State.kaModsAppliedEq = State.kaBootEq
    local animSpeed  = CONFIG.MeleeAnimSpeed  or 1.0
    local reachBoost = CONFIG.MeleeReachBoost or 0

    -- Скорость анимации удара (применяем всегда: 1.0 = вернуть норму после слайдера)
    -- v14.1 [BUG#3]: _slashTP ИСКЛЮЧЁН из списка. Это slash-with-displacement
    -- трек (TP = teleport/step), у него есть root-motion: AdjustSpeed(2) вдвое
    -- ускоряло лунж и персонажа рывком тащило вперёд на каждом свинге. С
    -- автосвингом раз в 0.35s это ощущалось как постоянный толчок при ноже.
    -- Трек всё равно возвращаем к 1.0 на случай, что его уже разогнали ранее.
    if type(animSpeed) == "number" and animSpeed > 0 then
        for _, field in ipairs({"_slash", "_equip", "_idle"}) do
            local track = rawget(svc, field)
            if track and type(track.AdjustSpeed) == "function" then
                pcall(track.AdjustSpeed, track, animSpeed)
            end
        end
        local tp = rawget(svc, "_slashTP")
        if tp and type(tp.AdjustSpeed) == "function" then
            pcall(tp.AdjustSpeed, tp, 1)
        end
    end

    -- Клиентский reach (используется MeleeInventoryReplicator для raycast-эффектов).
    -- v14 [CRITICAL]: ОРИГИНАЛ храним в weak-таблице kaDistOrig и всегда пишем
    -- orig + boost (не base + boost от текущего значения). stop() возвращает orig.
    State.kaDistOrig = State.kaDistOrig or setmetatable({}, { __mode = "k" })
    local base = State.kaDistOrig[svc]
    if base == nil then base = rawget(svc, "_distance") end
    if type(base) == "number" then
        if reachBoost ~= 0 then
            State.kaDistOrig[svc] = base
            rawset(svc, "_distance", base + reachBoost)
        elseif State.kaDistOrig[svc] ~= nil then
            -- boost выключен слайдером → возвращаем норму
            rawset(svc, "_distance", base)
        end
    end
end

local function finishSvcBootstrap(actor, rep, eqUid, ctx)
    local env = extractUseEnv(State.kaMeleeSvc)
    State.kaUseEnv     = env
    State.kaWarmupDone = true
    State.kaWarmupEq   = eqUid
    -- Применяем клиентские мод после того как svc найден
    pcall(applyMeleeMods, State.kaMeleeSvc)
    -- Хук скорости РУЧНЫХ ударов (ensureUseSpeedHook объявлен ниже — forward ref)
    if _kaEnsureUseSpeedHook then pcall(_kaEnsureUseSpeedHook, State.kaMeleeSvc) end
end

local function ensureMeleeSvc(actor, ctx)
    if not actor or not ctx then return nil, nil end
    local rep   = ctx.handler or getEquippedRep(actor)
    local eqUid = normalizeEqUid(rawget(actor, "_equipped"))
    if rep == nil or eqUid == nil then return nil, nil end
    if meleeSvcReady(eqUid) then
        finishSvcBootstrap(actor, rep, eqUid, ctx)
        return State.kaMeleeSvc, State.kaUseEnv
    end
    local svc = scanMeleeSvc(actor, rep, eqUid)
    if svc then
        State.kaMeleeSvc = svc
        State.kaBootEq   = eqUid
        finishSvcBootstrap(actor, rep, eqUid, ctx)
        return svc, State.kaUseEnv
    end
    State.kaWarmupDone = false
    State.kaWarmupEq   = nil
    return nil, nil
end

local function getRepHandler(actor, ctx)
    return getEquippedRep(actor) or (ctx and ctx.handler) or nil
end



-- origin атакующего = actor.CFrame:PointToWorldSpace(0,2.5,0) (как считает игра),
-- fallback — позиция камеры.
-- ══════════════════════════════════════════════════════════════════
-- v16 [ПОСЛЕ СМЕРТИ КИДАЕТ ТУДА-СЮДА] — origin больше не берётся на веру.
--
-- Разбор дампа. ActorClass.Update (строка 1996) при смерти выходит РАНЬШЕ
-- записи CFrame:
--     if not p294.Alive then ... return end        -- каждый кадр
--     ...
--     p294.CFrame = v418                          -- строка 3005, только живым
-- То есть у мёртвого актора CFrame ЗАМОРОЖЕН на позиции трупа. А Died()
-- (строка 1886) сносит RootPart и обнуляет _equipped. Респавн создаёт НОВЫЙ
-- объект актора (ReplicatorService.RegisterActor, строка 114) с
-- CFrame = CFrame.new(spawnPos).
--
-- Фолбэк на камеру тоже врал: на экране смерти активна DeadCamera, а она
-- припаркована на трупе (DeadCamera строка 44).
--
-- Итог: кламп Impact (v15) добросовестно проецировал точку удара на сферу
-- вокруг НЕВЕРНОГО origin — то есть сам изготавливал невалидный пакет, но
-- только после смерти. Сервер откатывал позицию, а CharacterController.Update
-- (строка 1165) лерпит к _forceCFrame со скоростью dt*5 — то есть плавно.
-- Следующий тик KillAura (0.2с) считал origin от УЖЕ СДВИНУТОГО актора и слал
-- снова → петля: коррекция → пересчёт → снова пакет → коррекция. Именно
-- «туда-сюда», а не одиночный толчок.
--
-- Теперь: origin отдаём только если актор ЖИВ и его CFrame согласован с
-- SimulatedPosition. Иначе nil — и вызывающий ОБЯЗАН не слать пакет.
-- ══════════════════════════════════════════════════════════════════
local KA_ORIGIN_MAX_DRIFT = 8   -- studs расхождения CFrame vs SimulatedPosition
local function kaImpactOrigin(actor)
    if type(actor) ~= "table" then return nil end
    if rawget(actor, "Alive") ~= true then return nil end
    local cf = rawget(actor, "CFrame")
    if typeof(cf) ~= "CFrame" then return nil end
    -- CFrame должен совпадать с живой позицией: иначе он застыл на трупе либо
    -- ещё лерпит к серверной коррекции.
    local sp = rawget(actor, "SimulatedPosition") or rawget(actor, "Position")
    if typeof(sp) == "Vector3" and (cf.Position - sp).Magnitude >= KA_ORIGIN_MAX_DRIFT then
        return nil
    end
    return cf:PointToWorldSpace(Vector3.new(0, 2.5, 0))
end

-- Вектор направления для actor:Action-пути (LegitAuto+WallCheck). В этом пути
-- клиент сам делает raycast; целим точно в кость цели длиной weapon.Reach.
local function impactDir(actor, aimPart, reach)
    local aimPoint = State.kaAimPoint
    if typeof(aimPoint) ~= "Vector3" and aimPart and aimPart.Parent then
        aimPoint = aimPart.Position
    end
    local cam  = Workspace.CurrentCamera
    local look = (cam and cam.CFrame.LookVector) or Vector3.new(0, 0, -1)
    if typeof(aimPoint) ~= "Vector3" then return look * reach end
    -- v16: origin теперь может быть nil (мёртвый/несогласованный актор) —
    -- без этой проверки была бы арифметика с nil. Падаем на взгляд камеры.
    local origin = kaImpactOrigin(actor)
    if typeof(origin) ~= "Vector3" then return look * reach end
    local to  = aimPoint - origin
    local dir = (to.Magnitude > 0.05) and to.Unit or look
    return dir * reach
end

local function resolveHitUid(targetUid, aimPart)
    if targetUid ~= nil then
        return Bridge.normalizeActorUid and Bridge.normalizeActorUid(targetUid) or tostring(targetUid)
    end
    if aimPart and aimPart.GetAttribute then
        local a = aimPart:GetAttribute("ActorUID")
        if a ~= nil then return tostring(a) end
    end
    return nil
end

local function resolveHitPart(aimPart, targetData)
    local forceBone = CONFIG.KillAuraForceBone
    if forceBone and type(targetData) == "table" and targetData.model and targetData.model.Parent then
        local forced = targetData.model:FindFirstChild(forceBone)
        if forced and forced:IsA("BasePart") then return forced end
    end
    -- v6: если ForceBone не нашёл кость — это ошибка модели цели, сообщаем
    if aimPart and aimPart:IsA("BasePart") and aimPart.Parent then return aimPart end
    local fb = CONFIG.KillAuraForceBone or "Head"
    warn("[KA] resolveHitPart: кость '", tostring(fb), "' не найдена в model. aimPart=", tostring(aimPart),
         "model=", type(targetData) == "table" and tostring(targetData.model) or "nil")
    return nil
end

local function syntheticImpact(aimPart, targetUid, targetData)
    local hitPos = State.kaAimPoint
    if typeof(hitPos) ~= "Vector3" then hitPos = aimPart and aimPart.Position end
    if typeof(hitPos) ~= "Vector3" then return nil end
    local part = resolveHitPart(aimPart, targetData)
    local uid  = resolveHitUid(targetUid, part or aimPart)
    if uid == nil then return nil end
    -- [v5] форсируем bone name по конфигу
    local boneName = (CONFIG.KillAuraForceBone)
        or (part and part.Name)
        or "Head"
    return hitPos, uid, boneName
end

local function findImpactFn(actor, ctx)
    local rep = getRepHandler(actor, ctx)
    return rep and getHandlerMethod(rep, "Impact") or nil
end

local function steeredImpact(self, dir, origImpact)
    if type(origImpact) ~= "function" then return nil end
    local aimPart   = State.kaImpactPart
    local targetUid = State.kaImpactUid
    local targetData = State.kaTarget
    if not aimPart and typeof(State.kaAimPoint) ~= "Vector3" then
        return origImpact(self, dir)
    end
    local reach = typeof(dir) == "Vector3" and dir.Magnitude or rawget(self, "_distance") or 5
    if type(reach) ~= "number" or reach <= 0 then reach = 5 end
    local actor = type(self) == "table" and rawget(self, "_actor")
    local steerDir = impactDir(actor, aimPart, reach)
    local ok, hitPos, uid, bone = pcall(function() return origImpact(self, steerDir) end)
    if ok and typeof(hitPos) == "Vector3" and uid ~= nil and bone then
        local fb = CONFIG.KillAuraForceBone
        return hitPos, uid, fb or bone
    end
    -- v6: no fallback — если origImpact не попал и synthetic не дал uid, это ошибка
    local sPos, sUid, sBone = syntheticImpact(aimPart, targetUid, targetData)
    if sPos then return sPos, sUid, sBone end
    warn("[KA] steeredImpact: origImpact промахнулся и synthetic не разрешил uid. aimPart=",
        tostring(aimPart), "targetUid=", tostring(targetUid))
    return nil
end

local function ensureRepImpactHook(actor, ctx)
    if type(hookfunction) ~= "function" then return false end
    local impactFn = findImpactFn(actor, ctx)
    if type(impactFn) ~= "function" then return false end
    State.kaImpactHookedFns = State.kaImpactHookedFns or {}
    if State.kaImpactHookedFns[impactFn] then return true end
    local origImpact
    local wrap = (type(newcclosure) == "function" and newcclosure or function(f) return f end)
    -- Impact-хук срабатывает на каждый удар. Тело — нативным (LPH_NO_VIRTUALIZE).
    origImpact = hookfunction(impactFn, wrap(LPH_NO_VIRTUALIZE(function(self, dir, ...)
        if State.kaImpactSteer and (State.kaImpactPart or typeof(State.kaAimPoint) == "Vector3") then
            return steeredImpact(self, dir, origImpact)
        end
        return origImpact(self, dir, ...)
    end)))
    State.kaImpactHookedFns[impactFn] = origImpact
    State.kaImpactFnHooked = true
    return true
end

-- ── Swing-speed Modify (ТОЛЬКО ручные удары) ────────────────────────────────
-- Хук MeleeInventory._use. В игре _use(self, swinging) крутит цикл, читая
-- self._timer (интервал между свингами) каждую итерацию. Мы масштабируем
-- _timer вниз ТОЛЬКО когда свинг инициирован игроком (зажал ЛКМ → InputService),
-- и оставляем норму для свингов killaura (State.kaUseThreadActive == true).
-- Так ускоряются лишь мои удары, а не аура. Клиентский _timer — сервер не трогаем.
local function ensureUseSpeedHook(svc)
    if not CONFIG.MeleeSwingSpeed then return false end
    if type(hookfunction) ~= "function" then return false end
    if type(svc) ~= "table" then return false end
    local useFn = getHandlerMethod(svc, "_use")
    if type(useFn) ~= "function" then return false end
    State.kaUseHookedFns = State.kaUseHookedFns or {}
    if State.kaUseHookedFns[useFn] then return true end

    local wrap = (type(newcclosure) == "function" and newcclosure or function(f) return f end)
    local origUse
    -- _use зовётся на каждый свинг + крутит внутренний цикл. Тело — нативным.
    origUse = hookfunction(useFn, wrap(LPH_NO_VIRTUALIZE(function(self, swinging, ...)
        -- Захватываем оригинальные тайминги оружия (per-svc) один раз.
        if type(self) == "table" then
            State.kaTimerOrig = State.kaTimerOrig or setmetatable({}, {__mode = "k"})
            local orig = State.kaTimerOrig[self]
            if not orig then
                orig = { t = rawget(self, "_timer"), d = rawget(self, "_delay") }
                State.kaTimerOrig[self] = orig
            end
            if swinging and CONFIG.MeleeSwingSpeed then
                local mult = CONFIG.MeleeSwingSpeedMult or 1.0
                -- self-swing (killaura) → норма; ручной удар → ускоряем
                local isSelf = State.kaUseThreadActive == true
                if (not isSelf) and mult > 0 and type(orig.t) == "number" then
                    rawset(self, "_timer", orig.t / mult)
                    if CONFIG.MeleeSwingScaleDelay and type(orig.d) == "number" then
                        rawset(self, "_delay", orig.d / mult)
                    end
                else
                    -- восстанавливаем норму для killaura-свингов
                    if type(orig.t) == "number" then rawset(self, "_timer", orig.t) end
                    if type(orig.d) == "number" then rawset(self, "_delay", orig.d) end
                end
            end
        end
        return origUse(self, swinging, ...)
    end)))
    State.kaUseHookedFns[useFn] = origUse
    State.kaUseSpeedHooked = true
    return true
end
_kaEnsureUseSpeedHook = ensureUseSpeedHook  -- связываем forward ref

local function triggerGameMeleeUse(svc, actor, ctx, aimPart, targetData)
    -- [v8 PacketAuto FIX] Корректная последовательность по дампу MeleeInventory._use:
    --   1. FireServer("InventoryAction", "Slash", N)    ← немедленно
    --   2. task.delay(svc._delay, ...)
    --      FireServer("InventoryAction", "Impact", ...) ← через weaponDelay
    -- PacketAuto: _use НЕ вызывается, Slash и Impact шлются вручн��ю.
    -- LegitAuto:  _use вызывается — он сам обрабатывает Slash+Impact внутри.
    local useFn = getHandlerMethod(svc, "_use")
    if type(useFn) ~= "function" then
        warn("[KA] triggerGameMeleeUse: нет _use в svc —", tostring(svc))
        return false, "no_use"
    end
    if State.kaUseThreadActive then
        local since = State.kaUseThreadSince or 0
        if since > 0 and now() - since < 0.5 then return false, "use_busy" end
        State.kaUseThreadActive = false
    end
    local _, cd  = getKaTimings()
    local kaMode = CONFIG.KillAuraMode or "LegitAuto"
    local isPA   = (kaMode == "PacketAuto")
    -- [FIX #2] Реальный _delay из оружия (MeleeInventory хранит svc._delay).
    -- Игра: task.delay(u10._delay, function() ... FireServer("Impact") ... end)
    local weaponDelay = isPA and (rawget(svc, "_delay") or 0.2) or 0

    State.kaUseThreadActive = true
    State.kaUseThreadSince  = now()

    -- LegitAuto: _use запускает цикл (Slash→delay→Impact) изнутри.
    -- PacketAuto: _use НЕ вызываем — строим пакеты вручную.
    if not isPA then
        task.spawn(function()
            local ok, err = pcall(useFn, svc, true)
            if not ok then
                State.kaUseThreadActive = false
                warn("[KA] _use(true) error:", tostring(err))
            end
        end)
    end

    local net    = State.kaUseEnv and State.kaUseEnv.net
    local v3fn   = Bridge.vector3ToTable
    local at     = getActionTypeInv()
    local actFn  = actor and getHandlerMethod(actor, "Action")
    local slashN = math.random(1, 3)

    local netFire = (net and net.FireServer and function(...) pcall(net.FireServer, net, ...) end)
        or Bridge.networkFireServer

    -- ── Slash ──────────────────────────────────────────────────────────────
    -- LegitAuto: Slash шлёт _use изнутри — не дублируем.
    -- PacketAuto [FIX #1]: отправляем Slash явно.
    --   Сервер ожидает Slash перед Impact для валидации состояния замаха.
    if isPA then
        if netFire then
            netFire("InventoryAction", "Slash", slashN)
        else
            warn("[KA] PacketAuto: нет netFire для Slash")
        end
    end

    -- ── Impact ─────────────────────────────────────────────────────────────
    -- PacketAuto [FIX #2]: через weaponDelay (реальный _delay оружия).
    -- LegitAuto: Impact отправляет _use, мы не дублируем.
    local function sendImpact()
        local reach     = getKaReach()
        local dir       = impactDir(actor, aimPart, reach)
        local predictMs = CONFIG.KillAuraPredictMs or 0
        local aimPt     = State.kaAimPoint
        if predictMs > 0 and type(targetData) == "table" and targetData.model then
            local root = targetData.model:FindFirstChild("HumanoidRootPart") or targetData.root
            if root and root:IsA("BasePart") then
                local vel = root.AssemblyLinearVelocity
                if vel.Magnitude > 0.5 then
                    local dt = predictMs / 1000
                    aimPt = (typeof(aimPt) == "Vector3" and aimPt or root.Position) + vel * dt
                end
            end
        end
        local hitPos, uid, bone
        -- PacketAuto в��егда идёт через synthetic path (без raycast).
        -- LegitAuto+NoWallCheck: тот же путь.
        -- LegitAuto+WallCheck:   через actor:Action (с raycast на клиенте).
        if isPA or CONFIG.KillAuraNoWallCheck then
            local part = resolveHitPart(aimPart, targetData)
            uid    = resolveHitUid(targetData and targetData.uid, part or aimPart)
            bone   = (CONFIG.KillAuraForceBone) or
                     (part and part.Name) or "Head"
            hitPos = typeof(aimPt) == "Vector3" and aimPt or (part and part.Position)
            if not hitPos or uid == nil then
                warn("[KA] synthetic impact: нет hitPos или uid — part:", tostring(part), "uid:", tostring(uid))
                return
            end
            -- v15 [ТОТ ЖЕ БАГ, ЧТО В PacketAuto — и он ШИРЕ]:
            -- сюда попадает не только PacketAuto (isPA), но и ЛЮБОЙ режим при
            -- CONFIG.KillAuraNoWallCheck, а он по умолчанию TRUE. То есть
            -- LegitAuto из коробки тоже слал абсолютную позицию врага вместо
            -- хита луча длиной weapon.Reach — отсюда «отталкивает и в других
            -- режимах». Безопасен только LegitAuto+WallCheck (ветка else ниже):
            -- там hitPos возвращает сама игра из своего рейкаста.
            -- Клампим на сферу reach вокруг груди — как MeleeInventoryReplicator.
            do
                local origin = kaImpactOrigin(actor)
                -- v16: origin неизвестен = актор мёртв либо его CFrame застыл на
                -- трупе / лерпит к серверной коррекции. Слать пакет НЕЛЬЗЯ: он
                -- будет невалиден, сервер откатит позицию, и получится петля
                -- «коррекция → пересчёт origin → снова пакет» (кидает туда-сюда).
                if typeof(origin) ~= "Vector3" then
                    return
                end
                do
                    local pReach = packetImpactReach()
                    local to     = hitPos - origin
                    local along  = to.Magnitude
                    if along > pReach and along > 0.01 then
                        hitPos = origin + to.Unit * pReach
                    end
                end
            end
        else
            if at and actFn then
                State.kaImpactSteer = true
                State.kaImpactPart  = aimPart
                State.kaImpactUid   = targetData and targetData.uid or nil
                local ok2, hp, u, b = pcall(actFn, actor, at, "Impact", dir)
                State.kaImpactSteer = false
                State.kaImpactPart  = nil
                State.kaImpactUid   = nil
                if ok2 then hitPos, uid, bone = hp, u, b end
                local fb = CONFIG.KillAuraForceBone
                if fb then bone = fb end
            end
        end
        if typeof(hitPos) == "Vector3" and uid ~= nil and bone and v3fn then
            local t = v3fn(hitPos)
            if t then
                if netFire then
                    netFire("InventoryAction", "Impact", t, uid, bone)
                else
                    warn("[KA] Impact: нет netFire — Bridge.networkFireServer=", tostring(Bridge.networkFireServer))
                end
            else
                warn("[KA] Impact: vector3ToTable вернул nil для", tostring(hitPos))
            end
        else
            warn("[KA] Impact пакет не отправлен: hitPos=", tostring(hitPos),
                "uid=", tostring(uid), "bone=", tostring(bone), "v3fn=", tostring(v3fn))
        end
    end

    if isPA then
        -- [FIX #2] Impact строго через weaponDelay (как в оригинале)
        if weaponDelay > 0.01 then
            task.delay(weaponDelay, sendImpact)
        else
            sendImpact()
        end
        -- [FIX #3] Освобождаем поток через weaponDelay+buf, а не через cd
        task.delay(weaponDelay + 0.06, function()
            State.kaUseThreadActive = false
            State.kaUseThreadSince  = 0
        end)
    else
        -- LegitAuto: Impact отправляет _use изнутри; мы останавливаем цикл через cd
        task.delay(math.max(0.05, cd - 0.05), function()
            pcall(useFn, svc, false)
            State.kaUseThreadActive = false
            State.kaUseThreadSince  = 0
        end)
    end
    return true, isPA and weaponDelay or cd
end

-- fallbackMeleeSwing удалён полностью (v6)

local function kaHasValidAim(aimPart, aimPoint, targetData)
    if typeof(aimPoint) == "Vector3" then return true end
    if aimPart and aimPart.Parent then return true end
    if type(targetData) == "table" and targetData.inInactiveWorld then return true end
    return false
end

local function beginSwingState(aimPart, aimPoint, targetData)
    State.kaImpactSteer = true
    State.kaImpactPart  = aimPart
    State.kaImpactUid   = targetData and targetData.uid or nil
    State.kaSwingBusy   = true
end

local function endSwingState(cd)
    task.delay(cd or 0.55, function()
        State.kaSwingBusy   = false
        State.kaImpactSteer = false
        State.kaImpactPart  = nil
        State.kaImpactUid   = nil
    end)
end

local function markSwingSuccess()
    State.kaLastSwing  = now()
    State.kaSwingCount = (State.kaSwingCount or 0) + 1
end

local function clearSwingBusyIfStale()
    if not State.kaSwingBusy then return end
    if (State.kaLastSwing or 0) > 0 and now() - (State.kaLastSwing or 0) > 1.25 then
        releaseSwingState()
    end
end

-- ════════════════════════════════════════════════��═════════════
-- scanNetworkModule — находит u17 instance (network) через
-- getnilinstances + getscriptclosure + upvalue-scan.
--
-- Flux/client (LocalScript) уничтожает себя через script:Destroy()
-- на строке 150, но getnilinstances находит его в nil-parent состоянии.
-- Сетевой объект u41 = u17.new() хранится как upvalue главного closure.
-- FireServer определён в метатаблице u17 — rawget не найдёт его,
-- поэтому идентификация по rawget полям: _code (string), _key (table),
-- _events (table), _functions (table).
-- ══════════════════════════════════════════════════════════════
-- ХОТ-СКАН: filtergc + getnilinstances→getupvalue×512. Под Luraph обязан быть
-- нативным (LPH_NO_VIRTUALIZE), иначе один проход по раздутому GC = фриз.
-- v14: type-check networkModule (start() мог записать функцию/userdata из
-- shared.import → rawget кидал, pcall(tick) глотал, PacketAuto молча умирал)
-- + бэкофф 3с после фейла: раньше кэшировался только успех, и полный скан
-- кучи повторялся на каждый PacketAuto-свинг.
local kaNetScanFailT = 0
local scanNetworkModule = LPH_NO_VIRTUALIZE(function()
    if type(State.networkModule) == "table" and rawget(State.networkModule, "_code") ~= nil then
        return State.networkModule   -- уже найден и закэширован
    end
    if now() - kaNetScanFailT < 3 then return nil end

    -- filtergc — самый быстрый путь (ищет по всей куче GC)
    if type(filtergc) == "function" then
        local ok0, gc = pcall(filtergc, "table", {
            Keys = {"_code", "_key", "_events", "_functions"}
        })
        if ok0 and type(gc) == "table" then
            for _, v in ipairs(gc) do
                if type(rawget(v, "_code")) == "string"
                   and type(rawget(v, "_key")) == "table"
                   and type(rawget(v, "_events")) == "table" then
                    State.networkModule = v
                    return v
                end
            end
        end
    end

    -- getnilinstances → LocalScript "client" → getscriptclosure → upvalue scan
    -- Flux/client уничтожен (script:Destroy) но живёт в getnilinstances
    if type(getnilinstances) ~= "function" then kaNetScanFailT = now() return nil end
    local ok1, nils = pcall(getnilinstances)
    if not ok1 or type(nils) ~= "table" then kaNetScanFailT = now() return nil end

    for _, inst in ipairs(nils) do
        local okC, cls = pcall(function() return inst.ClassName end)
        if not okC or cls ~= "LocalScript" then continue end
        local okN, nm  = pcall(function() return inst.Name end)
        if not okN or nm ~= "client" then continue end

        -- getscriptclosure → главный closure Flux/client
        if type(getscriptclosure) ~= "function" then continue end
        local okF, fn = pcall(getscriptclosure, inst)
        if not okF or type(fn) ~= "function" then continue end

        -- Сканируем upvalue главного closure
        -- u41 = u17.new() хранится как upvalue в main chunk
        for i = 1, 512 do
            local okU, uname, uval = pcall(debug.getupvalue, fn, i)
            if not okU or uname == nil then break end
            if type(uval) ~= "table" then continue end

            -- Проверяем поля (метатаблица u17 не мешает rawget-проверке instance-полей)
            local code  = rawget(uval, "_code")
            local key   = rawget(uval, "_key")
            local evts  = rawget(uval, "_events")
            local funcs = rawget(uval, "_functions")
            if type(code) == "string" and #code > 4
               and type(key) == "table" and #key == 5
               and type(evts) == "table"
               and type(funcs) == "table" then
                -- Убеждаемся что FireServer доступен через метатаблицу u17
                local okFs, fs = pcall(function() return uval.FireServer end)
                if okFs and type(fs) == "function" then
                    State.networkModule = uval
                    return uval
                end
            end
        end
    end
    kaNetScanFailT = now()
    return nil
end)

-- ══════════════════════════════════════════════════════════════
-- triggerPacketAutoFire — PacketAuto без svc.
-- Отправляет Slash + Impact напрямую через network module.
-- Net resolve priority:
--   1. kaUseEnv.net (из upvalue-scan _use, самый надёжный)
--   2. State.networkModule (из start(), если shared.import был жив)
--   3. getgc-скан таблиц с FireServer (fallback)
--   4. Bridge.networkFireServer
-- ══════════════════════════════════════════════════════════════
local function triggerPacketAutoFire(actor, aimPart, targetData)
    -- Net resolve: kaUseEnv.net (upvalue-scan _use) →
    --              scanNetworkModule (getnilinstances Flux/client) →
    --              Bridge.networkFireServer
    -- FireServer находится в метатаблице u17, не в самой таблице — net.FireServer ok.
    local net = (State.kaUseEnv and State.kaUseEnv.net)
             or scanNetworkModule()

    local netFire
    if type(net) == "table" then
        local okFs, fs = pcall(function() return net.FireServer end)
        if okFs and type(fs) == "function" then
            netFire = function(...) pcall(net.FireServer, net, ...) end
        end
    end
    if not netFire and Bridge.networkFireServer then
        netFire = Bridge.networkFireServer
    end
    if not netFire then
        warn("[KA] PacketAuto: netFire не найден (net=", tostring(net),
             " Bridge.networkFireServer=", tostring(Bridge.networkFireServer), ")")
        return false, "no_net"
    end

    local v3fn = Bridge.vector3ToTable
    if not v3fn then
        warn("[KA] PacketAuto: vector3ToTable недоступен")
        return false, "no_v3fn"
    end

    -- v14 [CRITICAL]: СНАЧАЛА полная валидация цели, ПОТОМ пакеты.
    -- Раньше Slash уходил ДО резолва uid/hitPos: при фейле сервер получал
    -- голый Slash без Impact на каждый ретрай (~5/с) — палевный паттерн.
    local part   = resolveHitPart(aimPart, targetData)
    local uid    = resolveHitUid(targetData and targetData.uid, part or aimPart)
    local bone   = (CONFIG.KillAuraForceBone)
               or (part and part.Name)
               or "Head"
    local hitPos = State.kaAimPoint
    if typeof(hitPos) ~= "Vector3" then
        hitPos = part and part.Parent and part.Position
    end
    -- predict
    local predictMs = CONFIG.KillAuraPredictMs or 0
    if predictMs > 0 and type(targetData) == "table" and targetData.model then
        local root = targetData.model:FindFirstChild("HumanoidRootPart") or targetData.root
        if root and root:IsA("BasePart") then
            local vel = root.AssemblyLinearVelocity
            if vel.Magnitude > 0.5 then
                local dt = predictMs / 1000
                hitPos = (typeof(hitPos) == "Vector3" and hitPos or root.Position) + vel * dt
            end
        end
    end
    if typeof(hitPos) ~= "Vector3" then
        warn("[KA] PacketAuto: hitPos не разрешён. aimPart=", tostring(aimPart))
        return false, "no_hitpos"
    end
    -- ═══════════════════════════════════════════════════════════════════
    -- v15 [ГЛАВНАЯ ПРИЧИНА «отталкивает при подходе к врагу»]
    --
    -- Разбор дампа игры (MeleeInventoryReplicator.Impact, строки 125-143):
    --   local v26 = p24._actor.CFrame:PointToWorldSpace(Vector3.new(0, 2.5, 0))
    --   local v27 = workspace:Raycast(v26, p25, p24._params)
    --             or workspace:Spherecast(v26, 1, p25, p24._params)
    --   return v27.Position, v28, v27.Instance.Name
    -- То есть Vector3, который уходит на сервер, — это позиция хита ЛУЧА длиной
    -- weapon.Reach из груди атакующего. По построению она НИКОГДА не дальше
    -- Reach от игрока. Реальные Reach из дампа: 5 (20 оружий), 6 (4), 7 (2).
    --
    -- А PacketAuto слал ЧИСТЫЙ State.kaAimPoint — центр тела врага. Единственный
    -- гейт перед выстрелом (performSwing) сравнивал с kaDist()+1, где kaDist() =
    -- KillAuraDistance = 25, но это радиус ВЫБОРА цели, а не reach оружия. Итог:
    -- Impact с |hitPos - грудь| до ~26 studs при реальном reach 5 — сервер видит
    -- невозможный удар ~3 раза в секунду и откатывает позицию клиента
    -- (CharacterController:Teleport пишет ForceNextPosition+SimulatedPosition —
    -- мгновенный рывок; SetCFrame ставит _forceCFrame и Update лерпит к нему
    -- dt*5 — плавное «тянет/отталкивает»). Ровно то, что чувствует игрок при
    -- подходе к врагу: KillAura захватывает цель → начинается откат.
    --
    -- ПОЧЕМУ ПРЕДЫДУЩИЕ ФИКСЫ НЕ ПОМОГЛИ: getKaReach() здесь не вызывается
    -- вообще, а interceptMeleeKaRaycast к этому пути не относится — PacketAuto
    -- не делает рейкаст, он формирует вектор сам. Оба фикса лечили LegitAuto.
    --
    -- РЕШЕНИЕ: проецируем точку хита на сферу reach вокруг груди — получаем
    -- ровно то, что вернул бы честный рейкаст игры. Направление на цель
    -- сохраняется, force-hit продолжает работать.
    -- ═══════════════════════════════════════════════════════════════════
    do
        local origin = kaImpactOrigin(actor)
        -- v16: origin неизвестен = актор мёртв либо CFrame застыл на трупе /
        -- лерпит к серверной коррекции. Пакет не шлём — иначе петля отката.
        if typeof(origin) ~= "Vector3" then
            return false, "no_origin"
        end
        do
            local reach = packetImpactReach()
            local to    = hitPos - origin
            local along = to.Magnitude
            if along > reach and along > 0.01 then
                hitPos = origin + to.Unit * reach
            end
        end
    end
    if uid == nil then
        warn("[KA] PacketAuto: uid не разрешён. targetData=", tostring(targetData))
        return false, "no_uid"
    end
    local t = v3fn(hitPos)
    if not t then
        warn("[KA] PacketAuto: vector3ToTable вернул nil")
        return false, "v3fn_nil"
    end

    -- Slash — только после успешной валидации (фейл выше = ноль пакетов)
    netFire("InventoryAction", "Slash", math.random(1, 3))

    -- v14 [CRITICAL]: Impact через реальный _delay оружия — дамп _use: игра
    -- шлёт его через task.delay(svc._delay), а не мгновенно после Slash.
    -- Пару Slash→Impact НЕ рвём, даже если ауру выключили/умерли за эти ~0.2с:
    -- сама игра шлёт Impact безусловно, а одиночный Slash без Impact — ровно
    -- та сигнатура, которую этот фикс убирает.
    local svc = State.kaMeleeSvc
    local d = (type(svc) == "table" and rawget(svc, "_delay")) or 0.2
    if type(d) ~= "number" or d < 0 then d = 0.2 end
    if d > 0.01 then
        task.delay(d, function()
            netFire("InventoryAction", "Impact", t, uid, bone)
        end)
    else
        netFire("InventoryAction", "Impact", t, uid, bone)
    end
    return true
end

local function performSwing(actor, ctx, aimPart, aimPoint, targetData, resetCd)
    if State.kaSwingBusy then return false, "busy" end
    if type(actor) ~= "table" then return false, "no_actor" end
    -- ═══════════════════════════════════════════════════════════════════
    -- v16 [ПОСЛЕ СМЕРТИ КИДАЕТ ТУДА-СЮДА]: строгий гейт по САМОМУ актору.
    --
    -- Раньше единственной проверкой живости был onLifeState() в тике, а он
    -- использует killaura-оракул isLocalAlive(). Библиотечный оракул
    -- Bridge.isLocalPlayerAlive устроен иначе (Humanoid-приоритет), и эти два
    -- расходятся на окне смерть→респавн: один уже говорит «жив», второй ещё
    -- «мёртв». В этом окне свинг проходил, а актор был мёртвый/новый со
    -- спавн-CFrame — и пакет уходил с неверным origin.
    -- Проверяем то, что реально важно, прямо на объекте: жив и есть что в руках
    -- (Died() обнуляет _equipped — дамп ActorClass строка 1886).
    -- ═══════════════════════════════════════════════════════════════════
    if rawget(actor, "Alive") ~= true then return false, "actor_not_alive" end
    if rawget(actor, "_equipped") == nil then return false, "no_equip" end
    if not kaHasValidAim(aimPart, aimPoint, targetData) then return false, "no_aim" end
    local _, cd = getKaTimings()
    if not resetCd and now() - (State.kaLastSwing or 0) < cd then return false, "cooldown" end
    -- v14 [CRITICAL #2b]: бэкофф фейл-ретраев. Фейл не двигает kaLastSwing
    -- (только markSwingSuccess), поэтому раньше ретрай шёл на КАЖДЫЙ тик.
    -- kaLastSwing не трогаем — на нём висит impact-flash кольца.
    if not resetCd and now() - (State.kaLastAttempt or 0) < cd * 0.5 then return false, "backoff" end
    State.kaLastAttempt = now()
    local tpos = kaRefPos(targetData) or (aimPart and aimPart.Position) or aimPoint
    if typeof(tpos) == "Vector3"
        and (tpos - kaLosOrigin(actor)).Magnitude > kaDist() + 1 then
        return false, "out_of_reach"
    end

    local kaMode = CONFIG.KillAuraMode or "LegitAuto"

    -- ── PacketAuto ────────────────────────────────────────────────────────────
    -- [FIX] Вызываем ensureMeleeSvc чтобы заполнит�� kaUseEnv.net через
    -- upvalue-scan _use. Без этого kaUseEnv = nil и net не р��золвится.
    if kaMode == "PacketAuto" then
        -- v15 [BUG «отталкивает»]: гейт по РЕАЛЬНОМУ reach, а не по kaDist().
        --
        -- Общий гейт выше сравнивает с kaDist()+1 = KillAuraDistance+1 = 26 —
        -- но это радиус ВЫБОРА цели, а не досягаемость оружия. Для пакетного
        -- пути это означало ~3 невозможных Impact в секунду на дистанции до 26
        -- studs при реальном reach 5 → сервер откатывал позицию. Кламп точки
        -- хита (см. triggerPacketAutoFire) делает пакет валидным геометрически,
        -- но бить по врагу в 20 studs ножом всё равно бессмысленно: сервер
        -- отклонит удар по несоответствию цели. Не шлём вообще — заодно снимаем
        -- палевный паттерн «Slash+Impact 3/с в пустоту».
        do
            local origin = kaImpactOrigin(actor)
            local tp = kaRefPos(targetData) or (aimPart and aimPart.Position) or aimPoint
            if typeof(tp) == "Vector3" and typeof(origin) == "Vector3"
                and (tp - origin).Magnitude > packetImpactReach() then
                return false, "packet_out_of_reach"
            end
        end
        pcall(ensureMeleeSvc, actor, ctx)   -- заполняет State.kaUseEnv.net
        beginSwingState(aimPart, aimPoint, targetData)
        local ok, reason = triggerPacketAutoFire(actor, aimPart, targetData)
        if ok then
            markSwingSuccess()
            kaPacketPulse = now()   -- вспышка прицела на удар
            if _kaSpawnPacketShock then _kaSpawnPacketShock() end  -- shockwave-волна
            State.kaLastImpactMode = "packet_auto"
            State.kaLastImpactNet  = "packet_auto"
            endSwingState(cd)
            return true, "packet_auto"
        end
        releaseSwingState()
        return false, reason or "pa_fail"
    end

    -- ── LegitAuto: через svc ────────────────────────────────────────────────
    local eqUid = normalizeEqUid(rawget(actor, "_equipped"))
    local svc   = select(1, ensureMeleeSvc(actor, ctx))
    pcall(ensureRepImpactHook, actor, ctx)
    beginSwingState(aimPart, aimPoint, targetData)
    if svc and meleeSvcReady(eqUid) then
        local act = rawget(svc, "_actor")
        if type(act) == "table" and rawget(act, "Locked") then
            releaseSwingState()
            return false, "actor_locked"
        end
        local okUse, useInfo = triggerGameMeleeUse(svc, actor, ctx, aimPart, targetData)
        if okUse then
            markSwingSuccess()
            State.kaLastSlashNet   = "game._use"
            State.kaLastImpactMode = "game._use"
            State.kaLastImpactNet  = "game._use"
            endSwingState(type(useInfo) == "number" and useInfo or cd)
            return true, "game._use"
        end
        releaseSwingState()
    end
    warn("[KA] performSwing: svc=nil после ensureMeleeSvc. equipped=",
        tostring(rawget(actor, "_equipped")), "actor=", tostring(actor))
    releaseSwingState()
    return false, "no_svc"
end

local function countEnemies()
    local n, e = 0, 0
    for _, d in pairs(State.actors or {}) do
        n = n + 1
        if not Bridge.isEnemyActor or Bridge.isEnemyActor(d) then e = e + 1 end
    end
    return n, e
end

-- FIX: раньше пул полностью пересоздавался на КАЖДОЕ изменение Ring Segments,
-- а удаление шло через seg:Remove() в pcall — по докам Potassium деструктор
-- :Destroy(), поэтому ошибка молча глоталась и сегменты текли. Теперь растём
-- инкрементально, лишнее корректно уничтожаем через общий деструктор.
local function ensureViz()
    if type(Drawing) ~= "table" or type(Drawing.new) ~= "function" then return end
    local segN = CONFIG.KillAuraVizSegments or 24
    local have = #kaVizLines
    if have == segN then return end
    if have < segN then
        for i = have + 1, segN do
            local seg = Drawing.new("Line")
            -- В Potassium Transparency=1 значит НЕПРОЗРАЧНО. Свежий Drawing
            -- приходит с 0 (= полностью прозрачный), а код отрисовки кольца
            -- это поле не трогал вообще — поэтому кольцо не появлялось.
            seg.Transparency = 1
            seg.Visible = false
            kaVizLines[i] = seg
        end
    else
        for i = have, segN + 1, -1 do
            Bridge.destroyDrawing(kaVizLines[i])
            kaVizLines[i] = nil
        end
    end
    -- Пересобираем кэш углов при смене segN
    kaVizAngleCacheN = 0
end

local function ensureAngleCache(segN)
    if kaVizAngleCacheN == segN then return end
    local pi2 = math.pi * 2
    for i = 0, segN - 1 do
        local a = (i / segN) * pi2
        kaVizCosCache[i] = math.cos(a)
        kaVizSinCache[i] = math.sin(a)
        -- Инициализируем переиспользуемые слоты в этом же проходе
        kaVizScrX[i] = 0; kaVizScrY[i] = 0
        kaVizVis[i]  = false
        kaVizColR[i] = 0; kaVizColG[i] = 0; kaVizColB[i] = 0
    end
    -- FIX: раньше хвост кэшей не подрезался при уменьшении segN — старые
    -- индексы оставались жить в таблицах навсегда.
    local i = segN
    while kaVizCosCache[i] ~= nil do
        kaVizCosCache[i] = nil; kaVizSinCache[i] = nil
        kaVizScrX[i] = nil; kaVizScrY[i] = nil; kaVizVis[i] = nil
        kaVizColR[i] = nil; kaVizColG[i] = nil; kaVizColB[i] = nil
        i = i + 1
    end
    kaVizAngleCacheN = segN
end

local function hideViz()
    kaVizActive = false
    if not kaVizShown then return end   -- v14: уже спрятано — 0 записей
    kaVizShown = false
    for i = 1, #kaVizLines do
        kaVizLines[i].Visible = false
    end
end

-- ══════════════════════════════════════════════════════════════
-- Плавная "jello"-пружина: кольцо едет от головы к ногам и обратно,
-- у каждой границы слегка проскакивает цель (overshoot) и мягко
-- возвращается — визуально пружинистый отскок, а не жёсткая смен��
-- направления.
-- ══════════════════════════════════════════════════════════════
-- Пружина кольца (позиция)
local kaVizSpringY      = nil
local kaVizSpringVel    = 0
local kaVizGoingToHead  = true
local kaVizLastFrameT   = 0
local kaVizTargetKey    = nil
local KA_VIZ_SPRING_K    = 48
local KA_VIZ_SPRING_DAMP = 6
local KA_VIZ_EDGE_EPS    = 0.1

local function lerpColor(a, b, t)
    t = math.clamp(t, 0, 1)
    return Color3.new(
        a.R + (b.R - a.R) * t,
        a.G + (b.G - a.G) * t,
        a.B + (b.B - a.B) * t
    )
end

local function getLiveTargetPos(target)
    -- Берём максимально свежую позицию цели каждый кадр (не привязано
    -- к интервалу pickTarget) — так кольцо не "залипает" на устаревшей точке.
    if type(target) ~= "table" then return nil end
    local model = target.model
    if model and model.Parent then
        local hrp = model:FindFirstChild("HumanoidRootPart")
        if hrp and hrp:IsA("BasePart") then return hrp.Position end
    end
    local root = target.root
    if root and root.Parent and root:IsA("BasePart") then return root.Position end
    return kaRefPos(target)
end

-- ══════════════════════════════════════════════════════════════
-- [VIZ 2] PacketAuto — чит-стиль LOCK-ON HUD (Nursultan/CS):
--   • сплошной чистый круг-прицел из сегментов (+ тусклый базовый круг)
--   • расходящиеся shockwave-кольца на каждый пакет-удар
-- Всё пулится один раз (0 а��локаций в кадре) → без FPS-дропов.
-- ══════════════════════════════════════════════════════════════
local KA_PV_SEG   = tonumber(CONFIG.KillAuraPacketVizSegments) or 32
local KA_PV_SHOCK = tonumber(CONFIG.KillAuraPacketVizShockN) or 3
local kaPvRing    = {}   -- сегменты основного круга (Line)
local kaPvBase    = {}   -- сегменты статичного тусклого базового круга (Line)
local kaPvShock   = {}   -- shockwave: массив колец, каждое = сегменты (Line)
local kaPvShockT  = {}   -- время старта каждой волны
local kaPvShockHead = 1  -- индекс следующей волны (ring buffer)
local kaPvBuilt   = false
-- предвычисленные sin/cos для сегментов (без trig в кадре на статичную часть)
local kaPvCos, kaPvSin = {}, {}

local function ensurePacketViz()
    if kaPvBuilt then return end
    if type(Drawing) ~= "table" or type(Drawing.new) ~= "function" then return end
    local function mkLine(z)
        local l = Drawing.new("Line"); l.Visible = false; l.Thickness = 2
        l.ZIndex = z or 20; return l
    end
    for i = 1, KA_PV_SEG do
        kaPvRing[i] = mkLine(21)
        kaPvBase[i] = mkLine(19)   -- базовый круг под основным
        local ang = (i - 1) / KA_PV_SEG * math.pi * 2
        kaPvCos[i] = math.cos(ang); kaPvSin[i] = math.sin(ang)
    end
    for w = 1, KA_PV_SHOCK do
        local ring = {}
        for i = 1, KA_PV_SEG do ring[i] = mkLine(20) end
        kaPvShock[w]  = ring
        kaPvShockT[w] = -999
    end
    kaPvBuilt = true
end

local function hidePacketViz()
    if not kaPvBuilt or not kaPvShown then return end   -- v14: dirty-флаг
    kaPvShown = false
    for i = 1, KA_PV_SEG do kaPvRing[i].Visible = false; kaPvBase[i].Visible = false end
    for w = 1, KA_PV_SHOCK do
        local ring = kaPvShock[w]
        for i = 1, KA_PV_SEG do ring[i].Visible = false end
    end
end

-- v14: полное уничтожение Drawing-пулов на stop()/реинжект — раньше пулы
-- только прятались и жили до конца сессии (48 ring + 64 PacketViz + 96 shock Line).
local function kaDestroyVizPools()
    for i = #kaVizLines, 1, -1 do
        Bridge.destroyDrawing(kaVizLines[i])
        kaVizLines[i] = nil
    end
    kaVizAngleCacheN = 0
    kaVizShown  = false
    kaVizActive = false
    if kaPvBuilt then
        for i = 1, KA_PV_SEG do
            Bridge.destroyDrawing(kaPvRing[i]); kaPvRing[i] = nil
            Bridge.destroyDrawing(kaPvBase[i]); kaPvBase[i] = nil
        end
        for w = 1, KA_PV_SHOCK do
            local ring = kaPvShock[w]
            if ring then
                for i = 1, KA_PV_SEG do Bridge.destroyDrawing(ring[i]); ring[i] = nil end
            end
            kaPvShock[w]  = nil
            kaPvShockT[w] = -999
        end
        kaPvShockHead = 1
        kaPvBuilt = false
        kaPvShown = false
    end
end

-- вызывается на КАЖДЫЙ пакет-удар (из места, где ставится kaPacketPulse)
local function spawnPacketShock()
    if not kaPvBuilt or CONFIG.KillAuraPacketVizShock == false then return end
    kaPvShockT[kaPvShockHead] = now()
    kaPvShockHead = (kaPvShockHead % KA_PV_SHOCK) + 1
end
_kaSpawnPacketShock = spawnPacketShock  -- связываем forward ref

-- рисует замкнутое кольцо из сегментов по центру (cx,cy) радиусом r
local function drawRing(pool, cx, cy, r, col, thick, alpha)
    for i = 1, KA_PV_SEG do
        local j  = (i % KA_PV_SEG) + 1
        local ln = pool[i]
        ln.From = Vector2.new(cx + kaPvCos[i] * r, cy + kaPvSin[i] * r)
        ln.To   = Vector2.new(cx + kaPvCos[j] * r, cy + kaPvSin[j] * r)
        ln.Color = col; ln.Thickness = thick
        ln.Transparency = alpha or 1
        ln.Visible = true
    end
end

local function updatePacketViz(target, cam)
    if CONFIG.KillAuraPacketViz == false then hidePacketViz() return end
    ensurePacketViz()
    if not kaPvBuilt then return end

    local model = target.model
    local headPos, feetPos
    if model and model.Parent then
        local head = model:FindFirstChild("Head")
        local hrp  = model:FindFirstChild("HumanoidRootPart") or target.root
        if head and head:IsA("BasePart") then headPos = head.Position + Vector3.new(0, head.Size.Y * 0.5, 0) end
        if hrp  and hrp:IsA("BasePart")  then feetPos = hrp.Position - Vector3.new(0, 3.0, 0) end
    end
    local live = getLiveTargetPos(target) or State.kaAimPoint
    if not headPos or not feetPos then
        if typeof(live) ~= "Vector3" then hidePacketViz() return end
        headPos = live + Vector3.new(0, 1.6, 0)
        feetPos = live - Vector3.new(0, 3.0, 0)
    end

    local topS, onT = cam:WorldToViewportPoint(headPos)
    local botS, onB = cam:WorldToViewportPoint(feetPos)
    if not (onT and onB) or topS.Z <= 0.01 or botS.Z <= 0.01 then hidePacketViz() return end
    kaPvShown = true   -- v14: дальше точно рисуем — взводим dirty-флаг

    local minY  = math.min(topS.Y, botS.Y)
    local maxY  = math.max(topS.Y, botS.Y)
    local cX    = (topS.X + botS.X) * 0.5
    local cY    = (minY + maxY) * 0.5
    local boxH  = maxY - minY
    local ringR = math.max(boxH * 0.34, 10)

    local t     = now()
    local pulse = math.clamp(1 - (t - kaPacketPulse) / 0.28, 0, 1)
    local thick = (CONFIG.KillAuraPacketVizThick or 2.0)
    local baseC = CONFIG.KillAuraPacketVizColor or Color3.fromRGB(120, 210, 255)
    local flashC= CONFIG.KillAuraPacketVizFlash or Color3.fromRGB(255, 255, 255)
    local col   = lerpColor(baseC, flashC, pulse)

    -- ── 0) Базовое тусклое кольцо (полный статичный круг под штриховым) ──
    local baseR   = ringR * (1 + pulse * 0.10)
    local baseA   = CONFIG.KillAuraPacketVizBaseAlpha or 0.45   -- Drawing: меньше = прозрачнее
    for i = 1, KA_PV_SEG do
        local j  = (i % KA_PV_SEG) + 1
        local ln = kaPvBase[i]
        ln.From = Vector2.new(cX + kaPvCos[i] * baseR, cY + kaPvSin[i] * baseR)
        ln.To   = Vector2.new(cX + kaPvCos[j] * baseR, cY + kaPvSin[j] * baseR)
        ln.Color = col; ln.Thickness = math.max(thick - 0.6, 1)
        ln.Transparency = baseA
        ln.Visible = true
    end

    -- ── 1) Основное кольцо-прицел: сплошной чистый круг (без пропусков/тиков) ──
    local rr = ringR * (1 + pulse * 0.12)              -- лёгкий «поп» на удар
    for i = 1, KA_PV_SEG do
        local ln = kaPvRing[i]
        local j  = (i % KA_PV_SEG) + 1
        ln.From = Vector2.new(cX + kaPvCos[i] * rr, cY + kaPvSin[i] * rr)
        ln.To   = Vector2.new(cX + kaPvCos[j] * rr, cY + kaPvSin[j] * rr)
        ln.Color = col; ln.Thickness = thick + pulse * 1.2
        ln.Transparency = 1
        ln.Visible = true
    end

    -- (Box-корнеры убраны — оставляем только круг.)

    -- ── 2) Shockwave-кольца: расходятся и тают за 0.45с ──
    if CONFIG.KillAuraPacketVizShock ~= false then
        for w = 1, KA_PV_SHOCK do
            local age = t - kaPvShockT[w]
            local ring = kaPvShock[w]
            if age >= 0 and age < 0.45 then
                local k = age / 0.45
                local r = ringR * (0.5 + k * 1.6)
                local a = 1 - k                    -- Drawing: 1 непрозрач → 0 прозрач
                drawRing(ring, cX, cY, r, col, math.max(thick * (1 - k), 0.5), a)
            else
                for i = 1, KA_PV_SEG do ring[i].Visible = false end
            end
        end
    end
end

local function updateViz(actor)
    local target = State.kaTarget
    if not CONFIG.KillAura or CONFIG.KillAuraViz == false
       or not (State.kaCtx and State.kaCtx.isMelee)
       or not target then
        hideViz()
        hidePacketViz()
            return
    end
    local cam = getCamera()
    if not cam then hideViz(); hidePacketViz() return end

    -- PacketAuto использует собственную визуализацию (скобки), а не кольцо.
    if (CONFIG.KillAuraMode or "LegitAuto") == "PacketAuto" then
        hideViz()
        updatePacketViz(target, cam)
        return
    else
        hidePacketViz()
    end


    local livePos = getLiveTargetPos(target) or State.kaAimPoint
    if typeof(livePos) ~= "Vector3" then hideViz() return end

    -- Границы модели
    local model  = target.model
    local headY, feetY
    if model and model.Parent then
        local head = model:FindFirstChild("Head")
        local hrp  = model:FindFirstChild("HumanoidRootPart") or target.root
        if head and head:IsA("BasePart") then headY = head.Position.Y + 0.25 end
        if hrp  and hrp:IsA("BasePart")  then feetY = hrp.Position.Y - 3.0  end
    end
    if not headY or not feetY then
        headY = livePos.Y + 1.4
        feetY = livePos.Y - 2.4
    end
    if headY < feetY then headY, feetY = feetY, headY end

    local segN = CONFIG.KillAuraVizSegments or 24
    ensureViz()
    if #kaVizLines == 0 then return end
    ensureAngleCache(segN)

    -- Сброс пружины при смене цели (плавно, без прыжка)
    local key = target.uid or target
    if kaVizTargetKey ~= key then
        kaVizTargetKey = key
        if kaVizSpringY == nil then
            kaVizSpringY = headY; kaVizSpringVel = 0; kaVizGoingToHead = false
        end
    end
    if kaVizSpringY == nil then
        kaVizSpringY = headY; kaVizSpringVel = 0
        kaVizGoingToHead = false
    end

    local t  = now()
    local dt = math.clamp(t - kaVizLastFrameT, 0, 0.1)
    kaVizLastFrameT = t

    -- Пружина bounce
    local goal  = kaVizGoingToHead and headY or feetY
    local accel = (goal - kaVizSpringY) * KA_VIZ_SPRING_K - kaVizSpringVel * KA_VIZ_SPRING_DAMP
    kaVizSpringVel = kaVizSpringVel + accel * dt
    kaVizSpringY   = kaVizSpringY   + kaVizSpringVel * dt
    if math.abs(kaVizSpringY - goal) < KA_VIZ_EDGE_EPS and math.abs(kaVizSpringVel) < 2.0 then
        kaVizGoingToHead = not kaVizGoingToHead
    end

    -- Squish
    local span  = math.max(headY - feetY, 0.01)
    local edgeP = 1 - math.clamp(
        math.min(math.abs(kaVizSpringY-headY), math.abs(kaVizSpringY-feetY)) / (span*0.5), 0, 1)
    local velSoft = kaVizSpringVel / (math.abs(kaVizSpringVel) + 0.8)
    local squish  = edgeP * 0.13 * velSoft

    -- Параметры из конфига
    local baseRadius = CONFIG.KillAuraVizRadius    or 1.8
    local warpAmpTgt = CONFIG.KillAuraVizWarpAmp   or 0.16
    local breathAmpT = CONFIG.KillAuraVizBreathAmp or 0.10
    local breathFq   = CONFIG.KillAuraVizBreathFq  or 0.9
    local thickMin   = CONFIG.KillAuraVizThickMin  or 1.3
    local thickMax   = CONFIG.KillAuraVizThickMax  or 1.8
    local tiltAmp    = CONFIG.KillAuraVizTiltAmp   or 0.3
    local spinSpeed  = CONFIG.KillAuraVizSpinSpeed or 1.2
    local doSpin     = CONFIG.KillAuraVizSpin ~= false
    local colA       = CONFIG.KillAuraVizColorA or Color3.fromRGB(200, 140, 255)
    local colB       = CONFIG.KillAuraVizColorB or Color3.fromRGB(90,  205, 255)

    -- Smooth lerp амплитуд
    local lerpK = math.clamp(dt * 8, 0, 1)
    kaVizWarpAmpCur = kaVizWarpAmpCur + (warpAmpTgt - kaVizWarpAmpCur) * lerpK
    kaVizBreathCur  = kaVizBreathCur  + (breathAmpT - kaVizBreathCur)  * lerpK

    -- Spin
    if doSpin then
        -- v14: ограничиваем угол — рос бесконечно (потеря float-точности за
        -- долгую сессию). Период 20π: общий для гармоник spin/0.7/0.4 ниже,
        -- поэтому wrap без визуального скачка (2π ломал бы фазы 0.7/0.4).
        kaVizSpinAngle = (kaVizSpinAngle + spinSpeed * dt) % (math.pi * 20)
    end

    local radiusX  = baseRadius * (1 + squish)
    local radiusZ  = baseRadius * (1 - squish * 0.6)
    local center   = Vector3.new(livePos.X, kaVizSpringY, livePos.Z)
    local breathPh = t * breathFq * math.pi * 2
    local breath   = 1 + math.sin(breathPh) * kaVizBreathCur
    local gradPh   = t * 0.50
    local rotPh    = t * 0.80
    local tiltY    = tiltAmp * math.sin(t * 0.23)
    local tiltRot  = t * 0.17

    -- ── Impact flash: на каждый успешный удар кольцо вспыхивает и толстеет ──
    -- Переиспользуем State.kaLastSwing (ставится в markSwingSuccess). Даёт
    -- «сочную» реакцию без лишних Drawing-объектов.
    local sinceSwing = t - (State.kaLastSwing or -999)
    local flashRaw   = math.clamp(1 - sinceSwing / 0.35, 0, 1)
    local flash      = flashRaw * flashRaw          -- ease-out «поп»
    kaVizFlash       = kaVizFlash + (flash - kaVizFlash) * math.clamp(dt * 22, 0, 1)

    local thickness = (thickMin + (thickMax - thickMin) * (0.5 + 0.5 * math.sin(breathPh)))
                      * (1 + kaVizFlash * 1.05)
    -- Прозрачность кольца (Potassium: 1 = непрозрачно). Настраивается конфигом.
    local ringAlpha = 1 - math.clamp(CONFIG.KillAuraVizTransparency or 0, 0, 0.95)

    -- ── Предвычисление вершин (без аллокации таблиц) ─────────────────────
    -- Используем кэш cos/sin — без вызова math.cos/sin в горячем цикле
    local spin     = kaVizSpinAngle
    local wA       = kaVizWarpAmpCur
    local rX, rZ   = radiusX * breath, radiusZ * breath
    local colAR, colAG, colAB = colA.R, colA.G, colA.B
    local colBR, colBG, colBB = colB.R, colB.G, colB.B
    local cx, cy, cz = center.X, center.Y, center.Z

    for i = 0, segN - 1 do
        -- Угол с вращением кольца: используем кэш + rotPh-сдвиг
        local baseAng = (i / segN) * math.pi * 2
        local ang     = baseAng + rotPh

        -- Warp через spin (sin аргументы включают spinAngle)
        local warp = 1
            + math.sin(ang * 4 + spin)         * wA
            + math.sin(ang * 2 - spin * 0.7)   * (wA * 0.55)
            + math.sin(ang     + spin * 0.4)   * (wA * 0.30)

        local rx   = rX * warp
        local rz   = rZ * warp
        local cosA = math.cos(ang)
        local sinA = math.sin(ang)
        -- 3D наклон
        local sinB = math.sin(ang + tiltRot)
        local wx = cx + cosA * rx
        local wy = cy + sinB * tiltY
        local wz = cz + sinA * rz

        local scr, vis = cam:WorldToViewportPoint(Vector3.new(wx, wy, wz))
        kaVizScrX[i] = scr.X
        kaVizScrY[i] = scr.Y
        kaVizVis[i]  = vis

        -- Бегущий градиент: lerp компонент без Color3.new в цикле
        local g = 0.5 + 0.5 * math.sin(baseAng + gradPh)
        local r = colAR + (colBR - colAR) * g
        local gg = colAG + (colBG - colAG) * g
        local b = colAB + (colBB - colAB) * g
        -- Impact flash: подмешиваем белый → кольцо ярко вспыхивает на удар
        if kaVizFlash > 0.001 then
            local fb = kaVizFlash * 0.85
            r  = r  + (1 - r)  * fb
            gg = gg + (1 - gg) * fb
            b  = b  + (1 - b)  * fb
        end
        kaVizColR[i] = r
        kaVizColG[i] = gg
        kaVizColB[i] = b
    end

    -- ── Рисуем segN рёбер ────────────────────────────────────────────────
    local anyVis = false
    for i = 0, segN - 1 do
        local j   = (i + 1) % segN
        local seg = kaVizLines[i + 1]
        seg.Thickness = thickness
        if kaVizVis[i] and kaVizVis[j] then
            seg.From    = Vector2.new(kaVizScrX[i], kaVizScrY[i])
            seg.To      = Vector2.new(kaVizScrX[j], kaVizScrY[j])
            seg.Color   = Color3.new(kaVizColR[i], kaVizColG[i], kaVizColB[i])
            seg.Transparency = ringAlpha   -- иначе сегмент остаётся невидимым
            seg.Visible = true
            anyVis      = true
        else
            seg.Visible = false
        end
    end

    -- v14: draw-цикл выше уже выставил Visible всем сегментам — флаг отражает итог
    kaVizShown  = anyVis
    kaVizActive = anyVis
    if not anyVis then hideViz() end
end
local function kaTickCombat(actor, ctx, autoSwing)
    clearSwingBusyIfStale()
    -- v13.1: и авто, и ручной (Hook) режим переоценивают ближайшего врага
    -- каждый PickInterval — раньше Hook держал первую цель до выхода за радиус.
    if not validateTarget(actor) or now() - kaLastPickT >= (CONFIG.KillAuraPickInterval or 0.25) then
        pickTarget(true, actor)
    end
    local target, aimPart, aimPoint = State.kaTarget, State.kaAimPart, State.kaAimPoint
    -- v14: updateViz отсюда убран — его уже зовёт per-frame viz-коннект,
    -- дубль давал 24-48 лишних WorldToViewportPoint на каждый боевой тик.
    if not target or typeof(aimPoint) ~= "Vector3" then
        setPhase("no_target")
        -- Hook: снимаем стиринг при потере цели (не перенаправлять удар в пустоту)
        if (CONFIG.KillAuraMode or "LegitAuto") == "Hook" then
            State.kaImpactSteer = false
            State.kaImpactPart  = nil
            State.kaImpactUid   = nil
        end
        return
    end
    local kaMode = CONFIG.KillAuraMode or "LegitAuto"
    setPhase(autoSwing and "active" or "manual", target.label or target.uid)
    if autoSwing and now() - kaLastDiagT >= 4 then
        kaLastDiagT = now()
        local _, en = countEnemies()
        log("KA", "auto [" .. kaMode .. "]", State.kaLastPhase, State.kaLastPickSource or "-",
            State.kaLastSkip or "-", "actors", State.trackedActorCount or 0,
            "enemies", en, "svc", State.kaMeleeSvc ~= nil, "tgt", target.label or target.uid)
    end

    if kaMode == "Hook" then
        -- Hook: нет авто-замаха. Поддерживаем активный стиринг Impact,
        -- чтобы при ручном ударе игрока хук перенаправил Impact на цель KA.
        --
        -- v16 [ПОСЛЕ СМЕРТИ КИДАЕТ ТУДА-СЮДА — путь Hook-режима]: стиринг
        -- взводился безусловно, пока есть цель. Поэтому ручной удар на окне
        -- смерть→респавн уходил через steeredImpact → impactDir →
        -- kaImpactOrigin, то есть с origin на трупе. Именно так «любой режим»
        -- попадал в ту же петлю, хотя Hook сам ничего не автострелит.
        -- Снимаем стиринг, пока актор не жив.
        if rawget(actor, "Alive") ~= true or rawget(actor, "_equipped") == nil then
            State.kaImpactSteer = false
            State.kaImpactPart  = nil
            State.kaImpactUid   = nil
            return
        end
        pcall(ensureRepImpactHook, actor, ctx)
        State.kaImpactSteer = true
        State.kaImpactPart  = aimPart
        State.kaImpactUid   = target and target.uid or nil
        return
    end

    -- LegitAuto / PacketAuto: авто-удар
    if autoSwing and not State.kaSwingBusy then
        local ok, reason = performSwing(actor, ctx, aimPart, aimPoint, target, false)
        if not ok then setPhase("skip", reason) end
    end
end

local function tickManualAssist()
    if not onLifeState() then setPhase("dead") return end
    local ctx = resolveMeleeContext(false)
    if not ctx then setPhase("no_melee") return end
    local actor = resolveActor(ctx)
    if not actor then setPhase("no_actor") return end
    ctx.actor = actor
    ensureMeleeSvc(actor, ctx)
    kaTickCombat(actor, ctx, false)
end

local function tick()
    -- v14 [FIX 3]: releaseSwingState — иначе Impact-хук продолжал стирить
    -- ручные удары в последнюю (возможно мёртвую) цель после выключения.
    if not CONFIG.KillAura then clearKaTarget() releaseSwingState() return end
    if not onLifeState() then setPhase("dead") return end
    -- Автоудар: PacketAuto и LegitAuto; Hook — только ручной ассист
    if (CONFIG.KillAuraMode or "LegitAuto") == "Hook" then return tickManualAssist() end
    local ctx
    if now() - kaLastFullCtxT >= 0.8 then
        kaLastFullCtxT = now()
        ctx = resolveMeleeContext(true)
    else
        ctx = resolveMeleeContext(false)
    end
    -- v14: форс-ретрай не чаще 1с — безусловный форс пробивал негатив-кэш
    -- (kaCtxEq) и дёргал Bridge.resolveLocalActor(true) каждый тик, пока в
    -- руках огнестрел.
    if not ctx and now() - (State.kaCtxTime or 0) > 1.0 then
        ctx = resolveMeleeContext(true)
    end
    if not ctx then
        clearKaTarget()
        setPhase("no_melee")
        return
    end
    local actor = resolveActor(ctx)
    if not actor then setPhase("no_actor") return end
    ctx.actor = actor
    ensureMeleeSvc(actor, ctx)
    kaTickCombat(actor, ctx, true)
end

-- v14: тело per-frame viz-кадра. Именованная функция (без аллокации замыкания
-- в кадре); зовётся из Heartbeat под pcall — throw больше не молчит.
local kaVizErrWarnT = 0
local kaTickErrWarnT = 0   -- v14.1 [M1]: троттл warn'а для главного тика
local function kaVizFrame()
    -- [FIX] Валидируем что equipped не изменился с момента последнего ctx.
    -- resolveMeleeContext кэшируется по kaCtxEq — если _equipped сменился,
    -- ctx немедленно становится nil (не ждём 1.5s cache expiry).
    -- Работа гейтится по State.kaCtx: без melee-контекста ни resolveActor,
    -- ни normalizeEqUid (tostring-аллокация) в кадре не выполняются.
    local ctx = State.kaCtx
    local actor = ctx and resolveActor(ctx) or nil   -- резолвим 1 раз за кадр
    if ctx and actor then
        local curEq = normalizeEqUid(rawget(actor, "_equipped")) or ""
        if curEq ~= (State.kaCtxEq or "") then
            -- Оружие сменилось — скрываем viz немедленно
            State.kaCtx     = nil
            State.kaCtxTime = 0
            hideViz()
            hidePacketViz()
            return
        end
    end
    updateViz(actor)
end

local function dumpDebug(testSwing)
    refreshTeamAndRep(true)
    -- [FLUX FIX] Дамп состояния Flux LocalActor
    local fluxActor = getFluxLocalActor()
    print("====== KillAura v3 DEBUG (H) ======")
    if fluxActor then
        print(string.format("[FluxActor] Alive=%s Health=%s Downed=%s",
            tostring(rawget(fluxActor, "Alive")),
            tostring(rawget(fluxActor, "Health")),
            tostring(rawget(fluxActor, "Downed"))))
    else
        print("[FluxActor] NOT FOUND — getFluxLocalActor() returned nil")
    end
    print("isLocalAlive():", isLocalAlive())
    local ctx   = resolveMeleeContext(true)
    local actor = ctx and resolveActor(ctx) or nil
    local rep   = actor and getRepHandler(actor, ctx) or nil
    local eq    = actor and rawget(actor, "_equipped") or nil
    local svc   = State.kaMeleeSvc
    print("melee:", ctx ~= nil, "equipped:", tostring(eq), "rep:", rep ~= nil,
        "build:", rep and rawget(rep, "_build"))
    print("svc:", svc ~= nil,
        "useFn:", svc and getHandlerMethod(svc, "_use") ~= nil,
        "svcSrc:", State.kaSvcSrc or "nil",
        "bootEq:", tostring(State.kaBootEq),
        "ctxEq:", tostring(State.kaCtxEq))
    print("warmup:", State.kaWarmupDone == true,
        "swingBusy:", State.kaSwingBusy == true,
        "useThread:", State.kaUseThreadActive == true)
    local t, p, pt = pickTarget(true, actor)
    print("picked:", t and (t.label or t.uid) or "NONE",
        "part:", p and p.Name or "nil",
        "point:", pt)
    if testSwing and actor and typeof(pt) == "Vector3" then
        State.kaLastSwing = 0
        releaseSwingState()
        print("test swing:", performSwing(actor, ctx, p, pt, t, true))
    end
    print("===================================")
end

local _M = {}
_M.CONFIG = KA_CONFIG

function _M.start()
    if kaConn then return end
    -- FIX: безусловная заливка затирала пользовательские значения и
    -- автозагруженный конфиг MacLib при каждом старте. Дефолты уже применены
    -- при загрузке модуля — здесь дозаполняем только отсутствующие ключи.
    for k, v in pairs(KA_CONFIG) do
        if CONFIG[k] == nil then CONFIG[k] = v end
    end
    -- v14.1 [H2]: через refcount (общий флаг иначе никто не опускает).
    if Bridge.markModuleRunning then Bridge.markModuleRunning("killaura", true)
    else State.running = true end
    pcall(function()
        if type(shared) == "table" and type(shared.import) == "function" then
            local ok, net = pcall(shared.import, "network")
            -- v14 [FIX 5]: только таблица — функция/userdata отсюда роняла
            -- rawget в scanNetworkModule (ошибку глотал pcall(tick)).
            if ok and type(net) == "table" then
                State.networkModule       = net
                State.networkModuleSource = "shared.import"
            end
        end
    end)
    if kaInputConn then kaInputConn:Disconnect() end
    kaInputConn = UIS.InputBegan:Connect(function(input, processed)
        if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        local key = input.KeyCode
        if CONFIG.KillAuraDebugKey and key == CONFIG.KillAuraDebugKey then
            task.spawn(function() dumpDebug(true) end)
        end
    end)
    local lp = Players.LocalPlayer
    if kaCharConn then kaCharConn:Disconnect() end
    if lp then
        kaCharConn = lp.CharacterAdded:Connect(function()
            kaCharGraceUntil    = now() + KA_CHAR_GRACE
            State.kaWasDead     = false
            _fluxActorCache     = nil
            _fluxActorCacheTime = 0
            clearKaTarget()
            releaseSwingState()
            clearMeleeBoot()
            task.defer(function()
                pcall(function()
                    if Bridge.resolveLocalActor then Bridge.resolveLocalActor(true) end
                end)
            end)
        end)
    end
    local acc = 0
    -- Per-frame kill-aura тик. Под Luraph нативно (LPH_NO_VIRTUALIZE).
    kaConn = RunService.Heartbeat:Connect(LPH_NO_VIRTUALIZE(function(dt)
        if not State.running or not CONFIG.KillAura then
            -- v14 [FIX 3]: tick() при выкл вообще не зовётся (гейт здесь),
            -- поэтому стиринг снимаем ТУТ, один раз (dirty-проверка).
            if State.kaImpactSteer or State.kaSwingBusy or State.kaTarget then
                clearKaTarget()
                releaseSwingState()
            end
            return
        end
        acc = acc + dt
        if acc < (CONFIG.KillAuraTickInterval or 0.2) then return end
        acc = 0
        -- v14.1 [M1]: был голый pcall(tick) — ошибка выбрасывалась молча.
        -- Если тик начинал падать (апдейт игры, nil-поле), KillAura просто
        -- «ничего не делала», без единого следа в консоли. Warn с троттлом 3с.
        local ok, err = pcall(tick)
        if not ok and now() - kaTickErrWarnT > 3 then
            kaTickErrWarnT = now()
            warn("[KA] tick упал:", tostring(err))
        end
    end))
    -- FIX: было RenderStepped — он идёт ДО апдейта камеры, поэтому кольцо
    -- отставало на кадр и «ползло» при шифтлоке/резком повороте. Heartbeat
    -- выполняется ПОСЛЕ камеры — проекция совпадает с тем, что видит игрок.
    -- Per-frame viz-тик (проекция кольца). Под Luraph нативно.
    -- v14: ВЕСЬ кадр под pcall (kaVizFrame) — раньше resolveActor/normalizeEqUid
    -- шли до pcall, и throw из Bridge.getActorTable молча ронял кадр без лога.
    kaVizConn = RunService.Heartbeat:Connect(LPH_NO_VIRTUALIZE(function()
        if not State.running or not CONFIG.KillAura then hideViz(); hidePacketViz() return end
        local ok, err = pcall(kaVizFrame)
        if not ok and now() - kaVizErrWarnT > 3 then
            kaVizErrWarnT = now()
            warn("[KA] viz frame error:", tostring(err))
        end
    end))
    task.defer(function()
        if not State.running or not CONFIG.KillAura then return end
        refreshTeamAndRep(true)
        local ctx   = resolveMeleeContext(true)
        local actor = ctx and resolveActor(ctx) or nil
        if actor and ctx then ensureMeleeSvc(actor, ctx) end
    end)
    log("KA", "v3 started | dist=", kaDist())
end

-- v14: откат клиентских модов одного svc (stop/реинжект): скорость анимаций,
-- _distance (из kaDistOrig, CRITICAL FIX #1) и _timer/_delay (из kaTimerOrig —
-- писались _use-хуком, но никогда не возвращались).
local function kaRestoreSvcMods(svc)
    if type(svc) ~= "table" then return end
    for _, field in ipairs({ "_slash", "_slashTP", "_equip", "_idle" }) do
        local track = rawget(svc, field)
        if track and type(track.AdjustSpeed) == "function" then
            pcall(track.AdjustSpeed, track, 1)
        end
    end
    local dOrig = State.kaDistOrig
    local base  = type(dOrig) == "table" and dOrig[svc] or nil
    if type(base) == "number" then pcall(rawset, svc, "_distance", base) end
    local tOrig = State.kaTimerOrig
    local orig  = type(tOrig) == "table" and tOrig[svc] or nil
    if type(orig) == "table" then
        if type(orig.t) == "number" then pcall(rawset, svc, "_timer", orig.t) end
        if type(orig.d) == "number" then pcall(rawset, svc, "_delay", orig.d) end
    end
end

function _M.stop()
    -- v14.1 [H2]: снимаем ссылку в общем refcount (см. markModuleRunning).
    if Bridge.markModuleRunning then Bridge.markModuleRunning("killaura", false) end
    if kaConn     then kaConn:Disconnect()     kaConn     = nil end
    if kaVizConn  then kaVizConn:Disconnect()  kaVizConn  = nil end
    if kaInputConn then kaInputConn:Disconnect() kaInputConn = nil end
    if kaCharConn  then kaCharConn:Disconnect() kaCharConn  = nil end
    hideViz()
    hidePacketViz()
    -- v14: пулы уничтожаем целиком (раньше только прятались и текли по реинжекту)
    kaDestroyVizPools()
    clearKaTarget()
    releaseSwingState()
    -- Сбрасываем Hook-стиринг
    State.kaImpactSteer = false
    State.kaImpactPart  = nil
    State.kaImpactUid   = nil
    -- v14: снимаем hookfunction-хуки с восстановлением оригиналов. Гард дедупа
    -- живёт в State — свежий State при реинжекте хукал ту же функцию повторно,
    -- и каждый слой пинил State прошлой сессии.
    if type(hookfunction) == "function" then
        for fn, orig in pairs(State.kaImpactHookedFns or {}) do
            pcall(hookfunction, fn, orig)
        end
        for fn, orig in pairs(State.kaUseHookedFns or {}) do
            pcall(hookfunction, fn, orig)
        end
    end
    State.kaImpactHookedFns = nil
    State.kaImpactFnHooked  = nil
    State.kaUseHookedFns    = nil
    State.kaUseSpeedHooked  = nil
    -- v14: возвращаем клиентские моды всем затронутым svc (текущему и всем,
    -- чьи оригиналы запомнены в weak-таблицах)
    local restored = {}
    local function restoreOnce(svc)
        if type(svc) == "table" and not restored[svc] then
            restored[svc] = true
            pcall(kaRestoreSvcMods, svc)
        end
    end
    restoreOnce(State.kaMeleeSvc)
    if type(State.kaDistOrig) == "table" then
        for svc in pairs(State.kaDistOrig) do restoreOnce(svc) end
    end
    if type(State.kaTimerOrig) == "table" then
        for svc in pairs(State.kaTimerOrig) do restoreOnce(svc) end
    end
    State.kaDistOrig  = nil
    State.kaTimerOrig = nil
    -- Полный сброс melee-бутстрапа: рестарт заново найдёт svc и переприменит моды
    clearMeleeBoot()
end

function _M.toggle()
    CONFIG.KillAura = not CONFIG.KillAura
    if CONFIG.KillAura and not kaConn then _M.start() end
    if not CONFIG.KillAura then clearKaTarget() releaseSwingState() end
    return CONFIG.KillAura
end

function _M.dumpStatus()  dumpDebug(false) end
function _M.debugDump()   dumpDebug(true)  end

function _M.swingOnce()
    -- v14 [FIX 4]: раньше force=true обходил alive-гейт resolveMeleeContext,
    -- и performSwing слал FireServer мёртвым игроком.
    if not isLocalAlive() then return false, "dead" end
    local ctx   = resolveMeleeContext(true)
    local actor = ctx and resolveActor(ctx) or nil
    local target, part, pt = pickTarget(true, actor)
    if not actor or typeof(pt) ~= "Vector3" then return false, "no_target" end
    State.kaLastSwing = 0
    releaseSwingState()
    return performSwing(actor, ctx, part, pt, target, true)
end

-- ─────────────────────────────────────────────────────────────────────────
-- UI-интеграция (MacLib). Лоадер вызывает _M.buildUI(ui) ПОСЛЕ start().
--   ui.tabs.KillAura — таб KillAura; колбэки пишут прямо в CONFIG (= Lib.CONFIG).
-- ─────────────────────────────────────────────────────────────────────────
function _M.buildUI(ui)
    local flag = ui.flag or function(s) return "KA_" .. s end
    local tab = ui.tabs and ui.tabs.KillAura
    if not tab then return end
    -- Melee Mods — это МОДИФИКАЦИЯ ОРУЖИЯ, её место в Gun Mods рядом с
    -- Weapon Mods и Free Gun, а не в табе автоатаки.
    local gmtab = ui.tabs and ui.tabs.GunMods
    local dtab = ui.tabs and ui.tabs.Debug

    local K = Bridge.makeUiKit(ui)

    -- ═══ LEFT: сама фича и как она выбирает цель ═══════════════════════
    local L = tab:Section({ Side = "Left" })

    K.feature(L, {
        Title = "Kill Aura", Flag = "KillAura",
        get = function() return CONFIG.KillAura end,
        set = function(v)
            CONFIG.KillAura = v
            -- v14 [FIX 3]: off → сразу снимаем стиринг Impact-хука, не ждём
            -- heartbeat (иначе ручной удар мог уйти в устаревшую цель).
            if not v then clearKaTarget() releaseSwingState() end
        end,
        Desc = "hits whoever is in range for u\nbind works on PC + mobile",
    })
    -- v14: флаги Mode/Distance/FOV → KA-префикс. "Distance" бился с Toggle
    -- esp.lua, "FOV" — со слайдером silentaim.lua (MacLib.Options общие на все
    -- модули, коллизия = чужое значение затирает наше). "Mode" — превентивно.
    K.dropdown(L, {
        Name = "Mode", Flag = "KAMode",
        Options = { "Hook", "PacketAuto", "LegitAuto" },
        Default = CONFIG.KillAuraMode or "Hook",
        Callback = function(v) CONFIG.KillAuraMode = v end,
        Desc = "Hook = redirects ur own swings, quietest\nPacketAuto = swings by itself, fastest n most obvious",
    })

    K.group(L, "Targeting")
    K.slider(L, { Name = "Distance", Flag = "KADistance", Default = CONFIG.KillAuraDistance,
        Min = 5, Max = 60, Suffix = " st",
        Callback = function(v) CONFIG.KillAuraDistance = v end,
        Desc = "how far we look for someone to hit" })
    K.slider(L, { Name = "FOV", Flag = "KAFOV", Default = CONFIG.KillAuraFOV,
        Min = 30, Max = 360, Suffix = "°",
        Callback = function(v) CONFIG.KillAuraFOV = v end,
        Desc = "360 = all around u" })
    K.dropdown(L, {
        Name = "Force Bone", Flag = "ForceBone",
        Options = { "Auto", "Head", "UpperTorso", "LowerTorso" },
        Default = CONFIG.KillAuraForceBone or "Head",
        Callback = function(v) CONFIG.KillAuraForceBone = (v == "Auto") and nil or v end,
    })
    K.slider(L, { Name = "Switch Margin", Flag = "SwitchMargin", Default = CONFIG.KillAuraSwitchMargin,
        Min = 0, Max = 10, Precision = 1, Suffix = " st",
        Callback = function(v) CONFIG.KillAuraSwitchMargin = v end,
        Desc = "how much closer a new guy must be before we ditch the current one\n0 = swaps constantly in a crowd" })
    K.toggle(L, { Name = "No Wall Check", Flag = "NoWall", Title = "No Wall Check",
        get = function() return CONFIG.KillAuraNoWallCheck end,
        set = function(v) CONFIG.KillAuraNoWallCheck = v end,
        Desc = "hits thru walls (client sided, obvious)" })

    K.group(L, "Timing")
    K.slider(L, { Name = "Prediction", Flag = "PredictMs", Default = CONFIG.KillAuraPredictMs,
        Min = 0, Max = 600, Suffix = " ms",
        Callback = function(v) CONFIG.KillAuraPredictMs = v end,
        Desc = "leads moving targets\nstart ~120 n tune from there" })
    K.slider(L, { Name = "Swing Cooldown", Flag = "SwingCd", Default = CONFIG.KillAuraSwingCd,
        Min = 0.1, Max = 1.5, Precision = 2, Suffix = " s",
        Callback = function(v) CONFIG.KillAuraSwingCd = v end,
        Desc = "lower = faster swings but way easier to spot" })
    K.slider(L, { Name = "Reach", Flag = "Reach", Default = CONFIG.KillAuraReach,
        Min = 5, Max = 999, Suffix = " st",
        Callback = function(v) CONFIG.KillAuraReach = v end })

    K.group(L, "Manual")
    K.button(L, { Name = "Swing Once", Flag = "SwingOnce", Title = "Kill Aura",
        Callback = function() _M.swingOnce(); return "swung" end })

    -- ═══ Melee Mods → таб Gun Mods (фолбэк в KillAura, если таба нет) ═══
    local R = (gmtab or tab):Section({ Side = "Right" })
    R:Header({ Name = "Melee Mods" })
    R:SubLabel({ Text = "client only — server packets stay untouched" })
    -- v14: слайдеры сбрасывают guard идемпотентности и переприменяют моды к
    -- текущему svc сразу (applyMeleeMods пишет orig+boost — без накопления).
    local function kaReapplyMods()
        State.kaModsAppliedEq = nil
        if State.kaMeleeSvc then pcall(applyMeleeMods, State.kaMeleeSvc) end
    end
    K.slider(R, { Name = "Anim Speed", Flag = "AnimSpeed", Default = CONFIG.MeleeAnimSpeed,
        Min = 1, Max = 5, Precision = 1, Suffix = "x",
        Callback = function(v) CONFIG.MeleeAnimSpeed = v; kaReapplyMods() end })
    K.slider(R, { Name = "Reach Boost", Flag = "ReachBoost", Default = CONFIG.MeleeReachBoost,
        Min = 0, Max = 15, Precision = 1, Suffix = " st",
        Callback = function(v) CONFIG.MeleeReachBoost = v; kaReapplyMods() end })

    -- Множитель и масштаб задержки имеют смысл только при ручной скорости —
    -- прячем их, пока тумблер выключен.
    local swingEls = {}
    local function swingVis()
        K.setVisible(swingEls, CONFIG.MeleeSwingSpeed == true)
    end
    K.toggle(R, { Name = "Manual Swing Speed", Flag = "SwingSpeedOn", Title = "Manual Swing Speed",
        get = function() return CONFIG.MeleeSwingSpeed end,
        set = function(v) CONFIG.MeleeSwingSpeed = v end,
        after = swingVis })
    swingEls[#swingEls + 1] = K.slider(R, { Name = "Swing Speed", Flag = "SwingSpeedMult",
        Default = CONFIG.MeleeSwingSpeedMult, Min = 1, Max = 5, Precision = 1, Suffix = "x",
        Callback = function(v) CONFIG.MeleeSwingSpeedMult = v end })
    swingEls[#swingEls + 1] = K.toggle(R, { Name = "Scale Hit Delay", Flag = "SwingScaleDelay",
        Title = "Scale Hit Delay",
        get = function() return CONFIG.MeleeSwingScaleDelay end,
        set = function(v) CONFIG.MeleeSwingScaleDelay = v end,
        Desc = "shrinks the slash→impact gap along with the anim" })
    swingVis()

    -- ═══ RIGHT #2: визуал ═══════════════════════════════════════════════
    local V = tab:Section({ Side = "Right" })

    -- Настройки кольца бессмысленны при выключенном кольце — прячем их.
    local ringEls = {}
    local function ringVis() K.setVisible(ringEls, CONFIG.KillAuraViz ~= false) end
    K.feature(V, {
        Title = "Target Ring", Flag = "Viz", NoKeybind = true,
        get = function() return CONFIG.KillAuraViz end,
        set = function(v) CONFIG.KillAuraViz = v; ringVis() end,
        Desc = "ring that orbits whoever ur locked on",
    })
    ringEls[#ringEls + 1] = K.color(V, { Name = "Color A", Flag = "VizColorA",
        Default = CONFIG.KillAuraVizColorA,
        Callback = function(c) CONFIG.KillAuraVizColorA = c end })
    ringEls[#ringEls + 1] = K.color(V, { Name = "Color B", Flag = "VizColorB",
        Default = CONFIG.KillAuraVizColorB,
        Callback = function(c) CONFIG.KillAuraVizColorB = c end })
    ringEls[#ringEls + 1] = K.slider(V, { Name = "Radius", Flag = "VizRadius",
        Default = CONFIG.KillAuraVizRadius, Min = 0.5, Max = 5, Precision = 1,
        Callback = function(v) CONFIG.KillAuraVizRadius = v end })
    ringEls[#ringEls + 1] = K.slider(V, { Name = "Segments", Flag = "VizSeg",
        Default = CONFIG.KillAuraVizSegments, Min = 8, Max = 48,
        Callback = function(v) CONFIG.KillAuraVizSegments = v end,
        Desc = "more = smoother ring, costs a bit of fps" })
    ringEls[#ringEls + 1] = K.toggle(V, { Name = "Spin", Flag = "VizSpin", Title = "Ring Spin",
        get = function() return CONFIG.KillAuraVizSpin end,
        set = function(v) CONFIG.KillAuraVizSpin = v end })
    ringEls[#ringEls + 1] = K.slider(V, { Name = "Spin Speed", Flag = "VizSpinSpeed",
        Default = CONFIG.KillAuraVizSpinSpeed, Min = 0, Max = 6, Precision = 1,
        Callback = function(v) CONFIG.KillAuraVizSpinSpeed = v end })
    ringEls[#ringEls + 1] = K.slider(V, { Name = "Transparency", Flag = "VizTransp",
        Default = math.floor((CONFIG.KillAuraVizTransparency or 0) * 100),
        Min = 0, Max = 95, Suffix = "%",
        Callback = function(v) CONFIG.KillAuraVizTransparency = v / 100 end })
    ringVis()

    K.group(V, "Lock-on HUD")
    local hudEls = {}
    local function hudVis() K.setVisible(hudEls, CONFIG.KillAuraPacketViz ~= false) end
    K.toggle(V, { Name = "Enabled", Flag = "PacketViz", Title = "Lock-on HUD",
        get = function() return CONFIG.KillAuraPacketViz end,
        set = function(v) CONFIG.KillAuraPacketViz = v; hudVis() end,
        Desc = "brackets on ur target, only in PacketAuto" })
    hudEls[#hudEls + 1] = K.color(V, { Name = "HUD Color", Flag = "PVizColor",
        Default = CONFIG.KillAuraPacketVizColor,
        Callback = function(c) CONFIG.KillAuraPacketVizColor = c end })
    hudEls[#hudEls + 1] = K.color(V, { Name = "Hit Flash", Flag = "PVizFlash",
        Default = CONFIG.KillAuraPacketVizFlash,
        Callback = function(c) CONFIG.KillAuraPacketVizFlash = c end })
    hudEls[#hudEls + 1] = K.slider(V, { Name = "Thickness", Flag = "PVizThick",
        Default = CONFIG.KillAuraPacketVizThick, Min = 1, Max = 5, Precision = 1,
        Callback = function(v) CONFIG.KillAuraPacketVizThick = v end })
    hudEls[#hudEls + 1] = K.toggle(V, { Name = "Shockwave on Hit", Flag = "PVizShock",
        Title = "Shockwave",
        get = function() return CONFIG.KillAuraPacketVizShock end,
        set = function(v) CONFIG.KillAuraPacketVizShock = v end })
    hudVis()

    -- ═══ DEBUG ══════════════════════════════════════════════════════════
    if dtab then
        local D = dtab:Section({ Side = "Left" })
        D:Header({ Name = "Kill Aura" })
        K.slider(D, { Name = "Tick Interval", Flag = "DbgTick",
            Default = math.floor((CONFIG.KillAuraTickInterval or 0.2) * 1000),
            Min = 50, Max = 1000, Suffix = " ms",
            Callback = function(v) CONFIG.KillAuraTickInterval = v / 1000 end,
            Desc = "how often we look for a target" })
        K.slider(D, { Name = "Pick Interval", Flag = "DbgPick",
            Default = math.floor((CONFIG.KillAuraPickInterval or 0.25) * 1000),
            Min = 50, Max = 1000, Suffix = " ms",
            Callback = function(v) CONFIG.KillAuraPickInterval = v / 1000 end })
        K.slider(D, { Name = "Context Cache", Flag = "DbgCtx",
            Default = math.floor((CONFIG.KillAuraCtxCacheSec or 1.5) * 1000),
            Min = 500, Max = 5000, Suffix = " ms",
            Callback = function(v) CONFIG.KillAuraCtxCacheSec = v / 1000 end })

        K.group(D, "Diagnostics")
        K.button(D, { Name = "Dump State", Flag = "DbgDump", Title = "Kill Aura",
            Callback = function()
                task.spawn(function() dumpDebug(false) end)
                return "dumped to console"
            end })
        K.button(D, { Name = "Dump + Test Swing", Flag = "DbgDumpSwing", Title = "Kill Aura",
            Callback = function()
                task.spawn(function() dumpDebug(true) end)
                return "dumped to console"
            end })
    end

    K.ready()   -- со следующего кадра уведомления разрешены
end

-- v14.1 [C1]: guard от повторной инжекции — прошлый инстанс держал свои
-- kaConn/kaViz/хуки Impact и продолжал тикать параллельно с новым.
do
    local g = (type(getgenv) == "function" and getgenv()) or _G
    local prev = g.BRM5_KA_MODULE
    if type(prev) == "table" and type(prev.stop) == "function" and prev ~= _M then
        pcall(prev.stop)
    end
    g.BRM5_KA_MODULE = _M
end

_M.Bridge            = Bridge
if Bridge.registerModule then Bridge.registerModule("killaura", _M) end
Bridge._killAuraModule = _M
return _M
end
