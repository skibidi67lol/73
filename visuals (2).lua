--[[
    BRM5 Visuals / World  v3  (scripts/visuals.lua)
    Контракт загрузчика: файл возвращает function(Lib) -> { start=fn, stop=fn }

    ── BRM5 Visuals v3 — CHANGELOG от v2: ──────────────────────────────────────
      • FOV: BindToRenderStep бессилен — ВСЕ бинды (0..2000) идут ДО
        RenderStepped-коннектов, а Flux пишет FieldOfView именно там. Теперь
        перебиваем его запись через GetPropertyChangedSignal("FieldOfView") +
        следим за сменой CurrentCamera; в start() защитный Unbind + warn при
        неудаче бинда; restore FOV в stop() — только если реально меняли.
      • SelfSkin: игра подменяет контроллер/актор БЕЗ Alive=false (транспорт и
        пр.) — кэш _ctrl протухал НАВСЕГДА, скин пропадал до конца сессии.
        Сброс кэша при «живом» акторе без модели; isCtrl отсекает контроллер,
        на который актор уже не ссылается; nil-ветка findCtrl затроттлена
        (было: 60 filtergc-сканов/сек в лобби/спектейте).
      • NoFWait: UI-тоггл ставил только флаг — enable/disableNoFWait звал лишь
        хоткей Num7, из меню фича была мёртвой. Теперь сеттер зовёт их сам.
      • Ambient/Fullbright/NoFog: выкл из UI не откатывал Lighting (это делали
        только хоткеи) — мир оставался перекрашенным. Общий off-путь lightingOff().
      • FreeGun: выкл тоггла/хоткея не возвращал la.SeatCanEquip (только stop);
        restoreFreeGunHook больше не форсит V.FreeGunEnabled=false.
      • heartbeat: был ОДИН pcall на все шаги — упавший шаг молча выключал все
        последующие до конца сессии (log — no-op). Теперь pcall на каждый шаг
        + warn не чаще 1/сек на шаг.
      • Хоткеи синкают MacLib-тоггл (MacLib сохраняет ЭЛЕМЕНТЫ, не CONFIG —
        SaveConfig после хоткея писал устаревшее значение); флаг-фолбэк
        выровнен с kit ("BRM5_<имя>", а не tostring).
      • VmRestyleSec добавлен в SETTINGS (+слайдер в Debug); слайдеры Hand
        Right/Up/Tilt (ViewmodelOffset/Tilt читались, но UI не было);
        AmbShadows/AmbFogOn сбрасывают пресет в Custom, эхо ambRefresh — нет.
      • Память/перф: promptAttrConn чистится по Destroying (тек на каждый
        промпт), маркеры BRM5_timer/BRM5_hold снимаются в disableNoFWait,
        поиск ViewmodelClass затроттлен (2с), vm-хук без table.pack/замыкания
        на кадр, applySelfHighlight пишет только при изменении, lightingStep
        ~4 Гц (ClockTime — каждый кадр), restore* красят и де-парентнутые
        части, sort в tickGradientStore читает Position внутри pcall.

    ── ХОТКЕИ (Numpad) ─────────────────────────────────────────────────────────
      Num1  Viewmodel      — смещение рук, FOV, материал/цвет рук от 1-го лица
      Num2  GunModel       — подсветка оружия (как ResolveAngle-виз)
      Num3  ThirdPersonSkin— стилизация СВОЕЙ модели в 3-м лице (камера в movement)
      Num4  VehicleFly     — полёт на транспорте (WASD + Space/Ctrl)
      Num5  VehicleSpeed   — множитель скорости транспорта
      KpEnter FreeGun      — снять блок экипировки оружия (в транспорте и пр.)
      Num6  Ambient        — время суток и яркость (только клиент)
      Num7  NoFWait        — убирает hold-таймер ProximityPrompt
      Num8  LockpickBypass — авто-успех мини-игры взлома
      Num9  Fullbright     — максимальное освещение без теней
      Num0  NoFog          — убирает туман

    ── ЧТО ИГРА ХРАНИТ (дамп Flux, для справки) ────────────────────────────────
      _localActor : { UID, Alive, IsLocalPlayer, Character, CFrame, SimulatedPosition,
                      ForceNextPosition, HeightState, Zoom, CameraZoom, ViewModel,
                      Controller, CurrentState, Focused, Seat, Vehicle }
      ViewModel   : { Root(BasePart), Offset(CFrame), ADSOffset, ADSLerp, CQB,
                      SprintLerp, NVGFOV, Canted, Recoil, Material, :SetModel,
                      :Update }   ← Update() ставит Root.CFrame каждый кадр
      Camera      : FieldOfView каждый кадр пишет Flux в СВОЁМ RenderStepped-
                    коннекте, который идёт ПОСЛЕ всех BindToRenderStep (любой
                    приоритет — бинд НЕ перебивает) → FOV держим через
                    GetPropertyChangedSignal("FieldOfView") поверх записи игры
      Vehicle     : { Throttle, Steering, Seats, VehicleMain, _derivedVelocity }
      LockPickCtrl: { _picks(0..6), _speed, _expires, _cancelled, _localActor }
                    при _picks==6 шлёт FireServer("ActivateInteract","Picked")
]]

return function(Lib)
    local CONFIG = Lib.CONFIG
    local State  = Lib.State
    local Bridge = Lib.Bridge   -- нужен для общего UI-kit (Bridge.makeUiKit)

    local RunService = game:GetService("RunService")
    local UIS        = game:GetService("UserInputService")
    local Lighting   = game:GetService("Lighting")
    local Workspace  = game:GetService("Workspace")
    local Players    = game:GetService("Players")
    local PPS        = game:GetService("ProximityPromptService")
    local LP         = Players.LocalPlayer

    -- ═══════════════════════════════════════════════════════════════════════
    -- Luraph PRELUDE (только строковые ключи). Голый `function LPH_*` рушит Luraph.
    -- Этот модуль НЕ имел макросов → под Luraph его filtergc-сканеры (findCtrl/
    -- findCam/findLockPick и др.) виртуализировались. Когда рядом обфусцирован
    -- silentaim, его VM-замыкания раздувают GC → один filtergc-проход в VM = фриз.
    -- Обёртываем сканеры в LPH_NO_VIRTUALIZE, чтобы шли нативно.
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

    local function now() return os.clock() end
    local function log() end   -- logging disabled (was print("[VIS]", ...))

    ---------------------------------------------------------------------------
    -- ⚙️  НАСТРОЙКИ ВИЗУАЛОВ  ─────────────────────────────────────────────────
    --  Всё, что можно менять, лежит ЗДЕСЬ, в одной таблице SETTINGS.
    --  Формат: Ключ = значение,  -- пояснение.
    --  *Enabled  — включена ли фича (можно стартовать сразу включённой).
    --  *Key      — хоткей (Numpad). Меняй на любой Enum.KeyCode.
    --  Цвета: Color3.fromRGB(r,g,b).  Материалы: Enum.Material.*.
    ---------------------------------------------------------------------------
    CONFIG.Visuals = CONFIG.Visuals or {}
    local V = CONFIG.Visuals

    local SETTINGS = {
        --== 1 · VIEWMODEL — вид РУК от первого лица (перекраска/материал/сдвиг) ==
        --   Оружие красит отдельная фича GunModel (№2). Хоткей: Numpad 1.
        ViewmodelEnabled          = false,
        ViewmodelKey              = Enum.KeyCode.KeypadOne,
        ViewmodelColorEnabled     = true,                        -- красить руки (ВКЛ → эффект виден сразу)
        ViewmodelColor            = Color3.fromRGB(0, 200, 255), -- цвет рук
        -- ВКЛ по умолчанию: ForceField даёт красивое равномерное свечение и, что
        -- важно, ПЕРЕКРЫВАЕТ текстуры/SurfaceAppearance рукавов и перчаток —
        -- поэтому теперь рукав/перчатка красятся так же, как сама рука.
        ViewmodelMaterialEnabled  = true,                        -- менять материал рук
        ViewmodelMaterial         = Enum.Material.ForceField,
        ViewmodelTransparency     = 0,                           -- 0..1 прозрачность рук (0 = как есть)
        ViewmodelOffset           = Vector3.new(0, 0, 0),        -- сдвиг рук: право / верх / назад (studs)
        ViewmodelTilt             = 0,                           -- наклон рук (градусы)
        ViewmodelDepth            = 0,     -- приближение рук по Z, в сотых studs (0 = как в игре)
        -- FIX v3: ключ читался (период до-обхода частей рук/оружия), но нигде
        -- не задавался — работал только фолбэк `or 3`. Теперь настоящий дефолт.
        VmRestyleSec              = 3,     -- раз в сколько секунд до-красить поздние части (руки/ствол)
        WorldFOVEnabled           = false, -- мировой FOV камеры (отдельно от рук)
        WorldFOV                  = 70,

        --== 2 · GUNMODEL — подсветка МОДЕЛИ ОРУЖИЯ. Хоткей: Numpad 2 ==
        GunModelEnabled           = false,
        GunModelKey               = Enum.KeyCode.KeypadTwo,
        GunModelHighlightEnabled  = true,   -- show Highlight instance on gun
        GunModelFill              = Color3.fromRGB(0, 170, 255),
        GunModelOutline           = Color3.fromRGB(255, 255, 255),
        GunModelFillTransparency  = 0.5,
        GunModelOutlineTransparency = 0,
        -- Те же «визуалы», что и у рук (Viewmodel): реальная перекраска частей
        -- оружия + смена материала (ForceField перекрывает текстуры/камо).
        GunModelColorEnabled      = true,
        GunModelColor             = Color3.fromRGB(0, 170, 255),
        GunModelMaterialEnabled   = true,
        GunModelMaterial          = Enum.Material.ForceField,
        GunModelTransparency      = 0,                           -- 0..1 прозрачность оружия

        --== 3 · THIRD PERSON SKIN — стилизация СВОЕЙ модели в 3-м лице. Numpad 3 ==
        --   (камерой рулит movement; тут только внешний вид тела)
        ThirdPersonEnabled        = false,
        ThirdPersonKey            = Enum.KeyCode.KeypadThree,
        ThirdPersonFill           = Color3.fromRGB(120, 200, 255),
        ThirdPersonOutline        = Color3.fromRGB(180, 235, 255),
        ThirdPersonFillTransparency = 0.55,
        ThirdPersonMaterial       = Enum.Material.Glass,          -- nil = не менять материал
        ThirdPersonBodyColor      = Color3.fromRGB(120, 200, 255),
        ThirdPersonBodyTransparency = 0.35,

        --== 3b · GRADIENT — плавный градиент МЕЖДУ ДВУМЯ ЦВЕТАМИ ==
        --   НЕ радуга: цвет пингпонг-л��рпит ColorA ⇆ ColorB (по умолчанию
        --   светло-фиолетовый ⇆ голубой). Работает поверх перекраски рук/оружия/
        --   тела. Для оружия «умный»: фаза бежит волной по частям (GradientSpread),
        --   поэтому части переливаются постепенно, а не все разом.
        ViewmodelGradientEnabled   = false,   -- переливать руки (Viewmodel)
        GunModelGradientEnabled    = false,   -- переливать оружие (GunModel)
        GunModelHighlightGradient  = true,    -- и обводку тоже красить волной
        ThirdPersonGradientEnabled = false,   -- переливать тело (ThirdPerson)
        GradientSpeed              = 0.35,     -- скорость перелива (циклов A⇆B в секунду)
        GradientColorA             = Color3.fromRGB(190, 150, 255), -- светло-фиолетовый
        GradientColorB             = Color3.fromRGB(120, 210, 255), -- голубой
        GunModelGradientSpread     = 1.6,      -- «растяжение» волны по частям оружия (0 = все синхронно)

        --== 4 · VEHICLE FLY — полёт на транспорте (WASD + Space/Ctrl). Numpad 4 ==
        VehicleFlyEnabled         = false,
        VehicleFlyKey             = Enum.KeyCode.KeypadFour,
        VehicleFlySpeed           = 120,                          -- studs/сек

        --== 5 · VEHICLE SPEED — множитель скорости транспорта. Numpad 5 ==
        VehicleSpeedEnabled       = false,
        VehicleSpeedKey           = Enum.KeyCode.KeypadFive,
        VehicleSpeedMult          = 2.0,

        --== 5b · FREE GUN — снять блок экипировки оружия (в транспорте и пр.). KeypadEnter ==
        -- Игра гейтит экипировку в InventoryService._canEquip: в транспорте
        -- HeightState==Sitting и SeatCanEquip==false → оружие не достать.
        -- FreeGun хукает _canEquip (возвращает true) и держит SeatCanEquip=true.
        FreeGunEnabled            = false,
        FreeGunKey                = Enum.KeyCode.KeypadEnter,

        --== 6 · AMBIENT — время суток и яркость (только у тебя). Numpad 6 ==
        AmbientEnabled            = false,
        AmbientPreset             = "Custom",
        AmbientColor              = Color3.fromRGB(120, 120, 130),
        AmbientOutdoorColor       = Color3.fromRGB(140, 140, 150),
        AmbientTintTop            = Color3.fromRGB(0, 0, 0),
        AmbientTintBottom         = Color3.fromRGB(0, 0, 0),
        AmbientExposure           = 0,
        AmbientLatitude           = 45,
        AmbientDiffuse            = 1,
        AmbientSpecular           = 1,
        AmbientShadows            = true,
        AmbientFogEnabled         = false,
        AmbientFogColor           = Color3.fromRGB(150, 160, 175),
        AmbientFogStart           = 0,
        AmbientFogEnd             = 800,
        AmbientKey                = Enum.KeyCode.KeypadSix,
        AmbientClockTime          = 14,                           -- 0..24 (14 = день, 0 = ночь)
        AmbientBrightness         = 2,

        --== 7 · NO F WAIT — убирает hold-таймер взаимодействий (F). Numpad 7 ==
        NoFWaitEnabled            = false,
        NoFWaitKey                = Enum.KeyCode.KeypadSeven,

        --== 8 · LOCKPICK BYPASS — авто-успех мини-игры взлома. Numpad 8 ==
        LockpickBypassEnabled     = false,
        LockpickBypassKey         = Enum.KeyCode.KeypadEight,
        LockpickScanInterval      = 0.4,                          -- как часто (сек) искать активный замок, если стейт неизвестен

        --== 9 · FULLBRIGHT — максимум света без теней. Numpad 9 ==
        FullbrightEnabled         = false,
        FullbrightKey             = Enum.KeyCode.KeypadNine,

        --== 0 · NO FOG — убирает туман. Numpad 0 ==
        NoFogEnabled              = false,
        NoFogKey                  = Enum.KeyCode.KeypadZero,
    }

    -- применяем дефолты, не затирая уже заданные пользователем значения
    for k, val in pairs(SETTINGS) do if V[k] == nil then V[k] = val end end

    ---------------------------------------------------------------------------
    -- GC-ФАЙНДЕРЫ
    ---------------------------------------------------------------------------
    local function isCtrl(t)
        if type(t) ~= "table" then return false end
        if type(rawget(t, "MoveSpeed"))    ~= "number"  then return false end
        if type(rawget(t, "IsGrounded"))   ~= "boolean" then return false end
        if type(rawget(t, "IsSprinting"))  ~= "boolean" then return false end
        local la = rawget(t, "_localActor")
        if type(la) ~= "table" or rawget(la, "IsLocalPlayer") == false then return false end
        -- FIX v3: игра пересоздаёт контроллер, НЕ трогая Alive (movement ловит
        -- это как ctrlSwapped) — старая таблица проходила все проверки и кэш
        -- жил вечно. Отсекаем контроллер, если актор ссылается на ДРУГОЙ
        -- ПЕРСОНАЖНЫЙ контроллер. Важно: в транспорте la.Controller — это
        -- контроллер машины (без MoveSpeed), его за подмену НЕ считаем, иначе
        -- скин слетал бы каждый раз при посадке.
        local backRef = rawget(la, "Controller")
        if type(backRef) == "table" and not rawequal(backRef, t)
        and type(rawget(backRef, "MoveSpeed")) == "number" then
            return false
        end
        return true
    end
    local _scanCd, _lastScan = 1.0, -999
    local _ctrl
    local _ctrlRescan = -999
    -- жив ли актор этого контроллера?
    local function ctrlAlive(c)
        local la = c and rawget(c, "_localActor")
        return type(la) == "table" and rawget(la, "Alive") ~= false
    end
    -- filtergc-скан по всему GC. Под Luraph обязан быть нативным.
    local rescanCtrl = LPH_NO_VIRTUALIZE(function()
        if type(filtergc) ~= "function" then return nil end
        local ok, gc = pcall(filtergc, "table",
            { Keys = { "MoveSpeed", "VelocityGravity", "TrySprinting", "IsGrounded", "IsSprinting" } })
        if not ok then return nil end
        -- предпочитаем ЖИВОЙ контроллер (после респавна старый _ctrl мёртв, но
        -- его таблица ещё проходит isCtrl → без этого 3-е лицо не возвращалось)
        local firstValid
        for _, v in ipairs(gc) do
            if isCtrl(v) then
                firstValid = firstValid or v
                if ctrlAlive(v) then _ctrl = v; return v end
            end
        end
        if firstValid then _ctrl = firstValid end
        return firstValid
    end)
    local function findCtrl()
        -- кэш валиден И актор жив → используем без сканов
        if _ctrl and isCtrl(_ctrl) and ctrlAlive(_ctrl) then return _ctrl end
        -- FIX v3: nil-ветка (лобби/спектейт/пре-спавн/сброс кэша) звала
        -- rescanCtrl БЕЗ троттла — полный filtergc-проход каждый Heartbeat,
        -- 60 сканов/сек. Теперь троттл общий для обеих веток; пока живого
        -- нет — возвращаем мёртвый кэш (мы реально мертвы) либо nil.
        local t = now()
        if t - _ctrlRescan < _scanCd then
            return (_ctrl and isCtrl(_ctrl)) and _ctrl or nil
        end
        _ctrlRescan = t
        local fresh = rescanCtrl()
        if fresh then return fresh end
        return (_ctrl and isCtrl(_ctrl)) and _ctrl or nil
    end
    -- ═══════════════════════════════════════════════════════════════════════
    -- FIX v4 [BUG#2] Сброс «брошенной» пары контроллер/актор — ОБЩИЙ для всех.
    --
    -- Игра подменяет контроллер/актор БЕЗ Alive=false (транспорт, редеплой и
    -- пр.). Такая пара проходит оба гейта findCtrl навсегда: isCtrl проходит
    -- (backref на месте), ctrlAlive проходит (Alive не переворачивали) — и
    -- rescanCtrl больше НИКОГДА не выполняется до конца сессии.
    --
    -- Сброс для этого случая в v3 уже был написан, но лежал внутри
    -- getSelfCharacter — а тот зовётся только из thirdPersonStep, который
    -- выходит сразу при выключенном V.ThirdPersonEnabled (это дефолт!). То
    -- есть у большинства пользователей фикс не работал: FreeGun писал
    -- SeatCanEquip призраку (экипировка в транспорте оставалась заблокирована),
    -- LockpickBypass читал CurrentState призрака и никогда не срабатывал, а
    -- findVehicleController деградировал до GC-сканов. Ничего не самолечилось —
    -- только включение Self Skin «магически» всё чинило. Теперь проверка живёт
    -- в getLA, то есть работает для ВСЕХ потребителей.
    -- ═══════════════════════════════════════════════════════════════════════
    local function getLA()
        local c = findCtrl()
        local la = c and rawget(c, "_localActor") or nil
        if type(la) == "table" and rawget(la, "Alive") ~= false then
            local ok, char = pcall(function() return la.Character end)
            -- актор «жив», но модели нет → пара брошена, кэш пора выбросить.
            -- В транспорте la.Character остаётся валидным, поэтому скин в
            -- машине не слетает (см. коммент про isCtrl выше).
            if not (ok and typeof(char) == "Instance"
                    and char:IsA("Model") and char.Parent) then
                _ctrl = nil
            end
        end
        return la
    end

    -- (поиск транспорта переехал в findVehicleController — секция VEHICLE FLY/SPEED)

    -- LockPickController (активная мини-игра)
    local function isLockPick(t)
        return type(t) == "table"
            and type(rawget(t, "_picks")) == "number"
            and rawget(t, "_expires") ~= nil
            and type(rawget(t, "_localActor")) == "table"
            and rawget(t, "_cancelled") ~= nil
    end
    local findLockPick = LPH_NO_VIRTUALIZE(function()
        if type(filtergc) ~= "function" then return nil end
        local ok, gc = pcall(filtergc, "table",
            { Keys = { "_picks", "_speed", "_expires", "_cancelled" } })
        if not ok then return nil end
        for _, v in ipairs(gc) do
            if isLockPick(v) and not rawget(v, "_cancelled") then return v end
        end
    end)

    -- Net module (для LockpickBypass)
    local function isNetObj(v)
        if type(v) ~= "table" then return false end
        local ok, fs = pcall(function() return v.FireServer end)
        return ok and type(fs) == "function"
            and type(rawget(v, "_code")) == "string"
            and type(rawget(v, "_events")) == "table"
    end
    local findNet = LPH_NO_VIRTUALIZE(function()
        if isNetObj(State.networkModule) then return State.networkModule end
        if type(filtergc) ~= "function" then return nil end
        local ok, gc = pcall(filtergc, "table",
            { Keys = { "_code", "_key", "_events", "_functions" } })
        if not ok then return nil end
        for _, v in ipairs(gc) do
            if isNetObj(v) then State.networkModule = v; return v end
        end
    end)

    ---------------------------------------------------------------------------
    -- 1. VIEWMODEL hook (пост-смещение ПОСЛЕ игрового Update)
    --
    -- ВАЖНО: hookfunction(orig, hook) -> origRef
    --   origRef — это безопасный вызываемый «оригинал». Вызов самого orig
    --   внутри hook уже перенаправлен на hook → бесконечная рекурсия.
    --   Всегда вызываем возвращённый origRef.
    ---------------------------------------------------------------------------
    -- Объявлен ЗДЕСЬ, до хука viewmodel: хук читает `running`, и если объявить
    -- локал ниже (у главного цикла), внутри хука он станет глобалом=nil и
    -- Viewmodel/GunModel перестанут применяться.
    local running     = false
    local vmHooked    = false
    local vmOrigRef   = nil   -- ← значение, ВОЗВРАЩЁННОЕ hookfunction (НЕ исходный rawget)
    local vmHookMode  = nil   -- "hookfunction" | "field" — как ставили, так и снимаем
    local vmHookTbl   = nil   -- таблица класса для field-режима (cls.Update = orig)
    local vmHookFn    = nil   -- исходная функция для hookfunction-режима
    -- FIX: раньше `local gunHighlight` объявлялся НИЖЕ (стр. 624) — уже после
    -- замыкания хука, которое его использует. Из-за этого обращения внутри
    -- хука компилировались как ГЛОБАЛ, а весь код очистки (хоткей, stop,
    -- тоггл в UI) захватывал пустой локал → gunHighlight:Destroy() никогда
    -- не выполнялся и Highlight утекал навсегда. Теперь объявлен ДО хука.
    local gunHighlight = nil

    -- Список стилизованных частей: { [part] = { M, C, T } } для restore
    local vmStyledParts  = {}
    local vmStyledVM     = nil
    local _vmStyleApplied = nil   -- FIX: declared here so restoreViewmodelStyle can reset it
    local _vmRestyleT     = 0     -- время последнего пере-обхода частей рук

    local function restoreViewmodelStyle()
        for part, s in pairs(vmStyledParts) do
            -- FIX v3: гейт `part.Parent` пропускал де-парентнутые части — игра
            -- их пере-использует, и они оставались крашеными навсегда. Свойства
            -- отпарентченных инстансов писать можно (pcall уже есть).
            if part then
                pcall(function()
                    part.Material    = s.M
                    part.Color       = s.C
                    part.Transparency = s.T
                    if s.tex ~= nil then part.TextureID = s.tex end
                end)
            end
            -- вернуть отключённые SurfaceAppearance (иначе рукав останется без текстуры)
            if s.sa then
                for _, rec in ipairs(s.sa) do
                    pcall(function()
                        if rec.inst and rec.parent then rec.inst.Parent = rec.parent end
                    end)
                end
            end
        end
        vmStyledParts = {}
        vmStyledVM    = nil
        _vmStyleApplied = nil
    end

    -- ── ПОДХОД (переписан): красим ИМЕННО РУКИ ────────────────────────────
    -- По дампу ViewmodelClass руки — это _leftArm / _rightArm (MeshPart'ы) плюс
    -- приваренные к ним перчатки/рукава/часы (Part0 = _leftArm/_rightArm,
    -- Parent = _container). Оружие — это отдельная _container-модель CurrentModel.
    -- Раньше стилизация опиралась ТОЛЬКО на об��од контейнера, и если руки лежали
    -- не там / грузились позже — эффекта не было («не работает»). Теперь мы
    -- ЯВНО берём _leftArm/_rightArm + их потомков И добираем контейнер (минус
    -- оружие). Плюс каждый кадр ПЕРЕ-применяем цвет к уже пойманным частям, если
    -- игра/анимации его сбросили — так эффект реально держится и виден.
    -- Обобщённое ядро: красит одну часть и сохраняет оригинал в store.
    -- opts = { colorOn, color, matOn, mat, transp }. Возвращает true если тронул.
    local function stylePartInto(d, store, opts)
        if not (d:IsA("BasePart") or d:IsA("MeshPart")) then return false end
        local paint = opts.colorOn or opts.matOn
        if store[d] == nil then
            local rec = { M = d.Material, C = d.Color, T = d.Transparency }
            -- Текстуры/камо (TextureID у MeshPart, SurfaceAppearance/Decal/Texture)
            -- перекрывают наш цвет — снимаем их с сохранением для восстановления.
            if paint then
                if d:IsA("MeshPart") and d.TextureID ~= "" then rec.tex = d.TextureID end
                local sa = {}
                for _, ch in ipairs(d:GetChildren()) do
                    if ch:IsA("SurfaceAppearance") or ch:IsA("Decal") or ch:IsA("Texture") then
                        sa[#sa + 1] = { inst = ch, parent = ch.Parent }
                    end
                end
                if #sa > 0 then rec.sa = sa end
            end
            store[d] = rec
        end
        local rec = store[d]
        pcall(function()
            if opts.matOn   then d.Material = opts.mat   end
            if opts.colorOn then d.Color    = opts.color end
            if paint then
                if rec.tex ~= nil and d:IsA("MeshPart") and d.TextureID ~= "" then
                    d.TextureID = ""
                end
                if rec.sa then
                    for _, r in ipairs(rec.sa) do
                        if r.inst and r.inst.Parent then r.inst.Parent = nil end
                    end
                end
            end
            -- При transp > 0 → ставим, при transp == 0 → восстанавливаем оригинал (если часть не полностью невидима)
            if (opts.transp or 0) > 0 then
                if d.Transparency < 1 then d.Transparency = opts.transp end
            elseif rec and (rec.T or 0) < 1 then
                d.Transparency = rec.T or 0
            end
        end)
        return true
    end

    -- восстановление произвольного store (руки ИЛИ оружие)
    local function restoreStore(store)
        for part, s in pairs(store) do
            -- FIX v3: без гейта `part.Parent` — см. restoreViewmodelStyle
            if part then
                pcall(function()
                    part.Material     = s.M
                    part.Color        = s.C
                    part.Transparency = s.T
                    if s.tex ~= nil then part.TextureID = s.tex end
                end)
            end
            if s.sa then
                for _, rec in ipairs(s.sa) do
                    pcall(function()
                        if rec.inst and rec.parent then rec.inst.Parent = rec.parent end
                    end)
                end
            end
        end
        table.clear(store)
    end

    -- ── GRADIENT (плавный перелив между ДВУМЯ цветами, НЕ радуга) ─────────────
    -- phase01 крутится 0..1; треуго����ьная (пинг-понг) волна t: 0→1→0 даёт
    -- плавный ColorA → ColorB → ColorA без резкого скачка на стыке цикла.
    local function gradientColorAt(phase01)
        local a = V.GradientColorA or Color3.fromRGB(190, 150, 255)
        local b = V.GradientColorB or Color3.fromRGB(120, 210, 255)
        local p = phase01 % 1
        local t = (p < 0.5) and (p * 2) or (2 - p * 2)   -- ping-pong 0..1..0
        return a:Lerp(b, t)
    end
    -- Фаза части по её ИНДЕКСУ в store (не по мировой позиции — та меняется при движении и даёт джиттер).
    -- Индекс определяется один раз: сортируем части по начальной мировой Y+X, присваиваем idx.
    -- spread растягивает/сжимает волну по индексам; 0 → все части в фазе (синхронно).
    -- Вынесено из горячего цикла: одна функция вместо замыкания на часть/кадр.
    local function _setPartColor(part, col) part.Color = col end
    local function _getPartPos(part) return part.Position end
    -- FIX v3: старый компаратор считывал Position ПОВТОРНО уже СНАРУЖИ pcall
    -- (использовался только boolean) — защита не защищала ничего. Теперь
    -- значение берётся изнутри pcall, упавшая часть даёт Vector3.zero.
    local function _safePos(part)
        local ok, pos = pcall(_getPartPos, part)
        return (ok and typeof(pos) == "Vector3") and pos or Vector3.zero
    end
    local function _posLess(a, b)
        local pa, pb = _safePos(a), _safePos(b)
        return (pa.Y + pa.X) < (pb.Y + pb.X)
    end
    local function tickGradientStore(store, spread, baseHue)
        -- 1) Собираем пары (part, rec) где нужно посчитать gp
        -- FIX: таблица needPhase создавалась каждый вызов, даже когда все фазы
        -- уже посчитаны (обычный случай) — теперь только по факту необходимости.
        local needPhase = nil
        local total = 0
        for part, rec in pairs(store) do
            if part and part.Parent then
                total = total + 1
                if rec.gp == nil then
                    needPhase = needPhase or {}
                    needPhase[part] = rec
                end
            end
        end
        if total == 0 then return end
        -- 2) Для частей без фазы — назначаем по сортировке idx/total
        if needPhase then
            local arr = {}
            for part in pairs(needPhase) do arr[#arr + 1] = part end
            -- Сортировка по базовой позиции: стабильная, не меняется при движении игрока
            table.sort(arr, _posLess)
            for i, part in ipairs(arr) do
                local rec = needPhase[part]
                if rec then
                    rec.gp = ((i - 1) / math.max(1, #arr)) * (spread or 1)
                end
            end
        end
        -- 3) Красим с кэшированными фазами
        for part, rec in pairs(store) do
            if part and part.Parent then
                -- FIX: было pcall(function() ... end) — новое замыкание на КАЖДУЮ
                -- часть КАЖДЫЙ кадр (2-4 тысячи аллокаций в секунду → GC-нагрузка
                -- и микрофризы). Теперь передаём аргументы в готовую функцию.
                pcall(_setPartColor, part, gradientColorAt(baseHue + (rec.gp or 0)))
            end
        end
    end

    local function styleOnePart(d, weapon)
        if weapon and d:IsDescendantOf(weapon) then return end   -- это оружие → мимо
        stylePartInto(d, vmStyledParts, {
            -- при включённом градиенте красим всегда (иначе текстуры перекроют цвет)
            colorOn = V.ViewmodelColorEnabled or V.ViewmodelGradientEnabled,
            color   = V.ViewmodelColor,
            matOn   = V.ViewmodelMaterialEnabled,
            mat     = V.ViewmodelMaterial,
            transp  = V.ViewmodelTransparency,
        })
    end

    -- FIX: стиль применяется один раз и кэшируется по (vm/оружие). Смена
    -- материала, цвета или тумблеров кэш НЕ сбрасывала — работал только
    -- слайдер прозрачности, потому что он единственный звал restore*Style().
    -- Отсюда «материал переприменяется только при смене прозрачности».
    -- Эти два хелпера вызываются из UI на любое изменение стиля.
    local function invalidateVmStyle()
        restoreViewmodelStyle()
    end

    local function applyViewmodelStyle(vm)
        if vmStyledVM ~= nil and vmStyledVM ~= vm then
            restoreViewmodelStyle()  -- resets _vmStyleApplied = nil
        end
        -- FIX FPS: обходим GetDescendants только при смене vm/оружия.
        -- Раньше при включённом градиенте этот ранний выход пропускался и весь
        -- обход дерева шёл КАЖДЫЙ кадр — тысячи Instance-вызовов в секунду,
        -- ровно отсюда и брался просад FPS при включении градиента.
        -- Перекраску градиента делает tickGradientStore ��о уже собранному
        -- списку частей, повторно собирать его не нужно.
        -- FIX («после смерти меняет руки, но не ��ука��»): стиль применялся
        -- РОВНО ОДИН раз на объект viewmodel. Части рук (перчатки, рукав,
        -- часы) досоздаются игрой асинхронно — те, что появились после
        -- первого прохода, так и оставались неокрашенными. При первом
        -- включении обычно успевало, после респавна — нет.
        -- Решение то же, что уже работает для тела в thirdPersonStep:
        -- периодический пере-обход раз в VmRestyleSec (дёшево, не каждый кадр).
        local nowT = now()
        if _vmStyleApplied == vm and (nowT - _vmRestyleT) < (V.VmRestyleSec or 3) then
            return
        end
        _vmRestyleT = nowT
        _vmStyleApplied = vm
        -- FIX v4 [BUG#2]: если Flux переиспользует объект vm между респавнами
        -- (пересоздавая только его Instance'ы), записи об уничтоженных частях
        -- прошлых жизней копились в vmStyledParts НАВСЕГДА: очистка была только
        -- при смене identity объекта vm или выключении фичи. tickGradientStore
        -- обходил их каждый кадр (пропуская по part.Parent) — медленная утечка
        -- памяти и per-frame итераций, растущая с числом смертей.
        -- Отпарентченным частям возвращаем оригинал и выкидываем запись: если
        -- игра часть переиспользует, styleOnePart перехватит её заново.
        -- Восстановление один-в-один как в restoreStore (включая sa/tex).
        for part, s in pairs(vmStyledParts) do
            if part and not part.Parent then
                pcall(function()
                    part.Material     = s.M
                    part.Color        = s.C
                    part.Transparency = s.T
                    if s.tex ~= nil then part.TextureID = s.tex end
                end)
                if s.sa then
                    for _, rec in ipairs(s.sa) do
                        pcall(function()
                            if rec.inst and rec.parent then rec.inst.Parent = rec.parent end
                        end)
                    end
                end
                vmStyledParts[part] = nil
            end
        end
        local weapon = rawget(vm, "CurrentModel")   -- модель оружия — НЕ трогаем

        -- 1) явные корни рук + всё, что к ним приварено/вложено (перчатки, рукав, часы)
        for _, key in ipairs({ "_leftArm", "_rightArm" }) do
            local arm = rawget(vm, key)
            if typeof(arm) == "Instance" then
                styleOnePart(arm, weapon)
                for _, d in ipairs(arm:GetDescendants()) do styleOnePart(d, weapon) end
            end
        end

        -- 2) добор по контейнеру (на случай перчаток, вложенных в _container, а не в руку)
        local root = rawget(vm, "Root")
        local container = root and root.Parent
        if container then
            for _, d in ipairs(container:GetDescendants()) do styleOnePart(d, weapon) end
        end

        vmStyledVM = vm
    end

    -- ── GUNMODEL: та же перекраска/материал, но для МОДЕЛИ ОРУЖИЯ ──────────────
    local gunStyledParts  = {}     -- [part] = { M, C, T, tex, sa }
    local gunStyledModel  = nil
    local _gunStyleApplied = nil  -- FIX: declared here so restoreGunStyle can reset it
    local _gunRestyleT     = 0
    local function restoreGunStyle()
        restoreStore(gunStyledParts)
        gunStyledModel = nil
        _gunStyleApplied = nil
    end
    local function invalidateGunStyle()
        restoreGunStyle()
    end

    local function applyGunStyle(vm)
        local weapon = rawget(vm, "CurrentModel")
        if not (typeof(weapon) == "Instance" and weapon.Parent) then
            if gunStyledModel then restoreGunStyle() end  -- resets _gunStyleApplied = nil
            return
        end
        if gunStyledModel ~= nil and gunStyledModel ~= weapon then
            restoreGunStyle()   -- сменили ствол → вернуть старый
            _gunStyleApplied = nil
        end
        -- FIX FPS: GetDescendants только при смене ствола (см. коммент в
        -- applyViewmodelStyle) — при градиенте кэш больше не обходится.
        -- Та же периодическая доводка, что и для рук: аттачменты/магазин
        -- могут досоздаться после первого прохода.
        local nowG = now()
        if _gunStyleApplied == weapon and (nowG - _gunRestyleT) < (V.VmRestyleSec or 3) then
            return
        end
        _gunRestyleT = nowG
        _gunStyleApplied = weapon
        local opts = {
            colorOn = V.GunModelColorEnabled or V.GunModelGradientEnabled,
            color   = V.GunModelColor,
            matOn   = V.GunModelMaterialEnabled,
            mat     = V.GunModelMaterial,
            transp  = V.GunModelTransparency,
        }
        stylePartInto(weapon, gunStyledParts, opts)   -- no-op если weapon это Model
        for _, d in ipairs(weapon:GetDescendants()) do
            stylePartInto(d, gunStyledParts, opts)
        end
        gunStyledModel = weapon
    end

    -- FIX v3 (перф): тело vm-хука вынесено в ИМЕНОВАННУЮ функцию уровня модуля.
    -- Раньше на КАЖДЫЙ кадр аллоцировались table.pack + замыкание в pcall +
    -- table.unpack — ровно тот паттерн, что уже чинили в tickGradientStore.
    local vmHookBody = LPH_NO_VIRTUALIZE(function(self)
        -- ГЕОМЕТРИЯ РУК (offset / tilt / zoom) — ВНЕ гейта
        -- V.ViewmodelEnabled.
        -- FIX: раньше этот блок был внутри `if V.ViewmodelEnabled`,
        -- то есть Hand Zoom и смещение работали только когда включена
        -- ПЕРЕКРАСКА рук. Это НЕ связанные вещи: человек крутил ползунок
        -- при выключенном тумблере и не понимал, почему ничего нет.
        --
        -- Про сам зум: «Custom FOV» раньше писал в Camera.FieldOfView —
        -- это мировой FOV (отсюда ощущение смены чувствительности). В
        -- BRM5 руки рендерятся ОБЩЕЙ камерой (дамп ViewmodelClass:822,
        -- FOV там только масштабирует отдачу), отдельной камеры для
        -- viewmodel нет. Честный аналог «зума рук» — двигать сами руки
        -- по оси Z.
        do
            local root = rawget(self, "Root")
            if root and root.Parent then
                local o = V.ViewmodelOffset or Vector3.new()
                local tilt = V.ViewmodelTilt or 0
                local depth = (V.ViewmodelDepth or 0) / 100   -- studs
                if o.Magnitude > 0.001 or math.abs(tilt) > 0.001
                or math.abs(depth) > 0.0001 then
                    root.CFrame = root.CFrame
                        * CFrame.new(o.X, o.Y, -o.Z + depth)
                        * CFrame.Angles(0, 0, math.rad(tilt))
                end
            end
        end
        if V.ViewmodelEnabled then
            -- стилизация рук — только один раз (не каждый кадр)
            if V.ViewmodelMaterialEnabled or V.ViewmodelColorEnabled
            or (V.ViewmodelTransparency or 0) > 0 or V.ViewmodelGradientEnabled then
                applyViewmodelStyle(self)
                -- градиент — перекрас каждый кадр под текущую фазу
                if V.ViewmodelGradientEnabled then
                    tickGradientStore(vmStyledParts, 0.4, now() * (V.GradientSpeed or 0.35))
                end
            elseif vmStyledVM then
                restoreViewmodelStyle()
            end
        else
            if vmStyledVM then restoreViewmodelStyle() end
        end
        -- GunModel Highlight — ТОЛЬКО модель оружия (self.CurrentModel),
        -- НЕ руки. Highlight держим в контейнере, адорним само оружие;
        -- при смене ствола игра пересоздаёт CurrentModel — переадорним.
        if V.GunModelEnabled then
            local root2 = rawget(self, "Root")
            local container = root2 and root2.Parent
            local weapon = rawget(self, "CurrentModel")
            -- Highlight is optional — can be disabled without disabling full GunModel
            if V.GunModelHighlightEnabled ~= false then
                if container and weapon and weapon.Parent then
                    if not (gunHighlight and gunHighlight.Parent) then
                        gunHighlight = Instance.new("Highlight")
                        gunHighlight.Name = "BRM5_GunHL"
                        gunHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    end
                    -- FIX: у Highlight не было градиента вообще —
                    -- переливалась только сама модель, а обводка
                    -- оставалась статичной, из-за чего эффект выглядел
                    -- рассинхронизированным. Теперь Highlight берёт
                    -- тот же цвет волны, что и части оружия.
                    if V.GunModelGradientEnabled and V.GunModelHighlightGradient ~= false then
                        local gcol = gradientColorAt(now() * (V.GradientSpeed or 0.35))
                        gunHighlight.FillColor    = gcol
                        gunHighlight.OutlineColor = gcol
                    else
                        gunHighlight.FillColor    = V.GunModelFill
                        gunHighlight.OutlineColor = V.GunModelOutline
                    end
                    gunHighlight.FillTransparency   = V.GunModelFillTransparency
                    gunHighlight.OutlineTransparency = V.GunModelOutlineTransparency
                    if gunHighlight.Adornee ~= weapon then gunHighlight.Adornee = weapon end
                    gunHighlight.Parent = container
                elseif gunHighlight then
                    gunHighlight.Adornee = nil  -- оружие не экипировано сейчас
                end
            elseif gunHighlight then
                -- Highlight toggled off while GunModel is still on
                pcall(function() gunHighlight:Destroy() end); gunHighlight = nil
            end
            -- та же перекраска/материал, что и у рук — но для оружия
            if V.GunModelColorEnabled or V.GunModelMaterialEnabled
            or (V.GunModelTransparency or 0) > 0 or V.GunModelGradientEnabled then
                applyGunStyle(self)
                -- умный градиент: волна фазы бежит по частям (spread из конфига)
                if V.GunModelGradientEnabled then
                    tickGradientStore(gunStyledParts, V.GunModelGradientSpread or 1.6,
                        now() * (V.GradientSpeed or 0.35))
                end
            elseif gunStyledModel then
                restoreGunStyle()
            end
        else
            if gunHighlight then
                pcall(function() gunHighlight:Destroy() end)
                gunHighlight = nil
            end
            if gunStyledModel then restoreGunStyle() end
        end
    end)

    -- FIX v3: пока класс не найден (лобби/ранний джойн) filtergc-скан шёл
    -- КАЖДЫЙ кадр при включённом Viewmodel/GunModel. Троттлим как у FreeGun.
    local _vmScanT = -999
    local function ensureViewmodelHook()
        if vmHooked then return true end
        if type(hookfunction) ~= "function" then return false end
        if type(filtergc)     ~= "function" then return false end
        local tScan = now()
        if tScan - _vmScanT < 2.0 then return false end
        _vmScanT = tScan

        -- Ищем ViewmodelClass. filtergc-проход по GC обёрнут в NO_VIRTUALIZE —
        -- под Luraph он обязан идти нативно (иначе фриз на раздутом GC).
        local cls = LPH_NO_VIRTUALIZE(function()
            local ok, gc = pcall(filtergc, "table",
                { Keys = { "Update", "SetModel", "AddReticle", "LoadAnimation" } })
            if not ok then return nil end
            for _, v in ipairs(gc) do
                if type(rawget(v, "Update")) == "function"
                and type(rawget(v, "SetModel")) == "function"
                and type(rawget(v, "AddReticle")) == "function" then
                    return v
                end
            end
            return nil
        end)()
        if not cls then return false end

        local origFn = rawget(cls, "Update")
        if type(origFn) ~= "function" then return false end

        -- hookfunction возвращает origRef — именно его вызываем внутри хука
        -- Хук ViewmodelClass.Update вызывается КАЖДЫЙ кадр игровой системой
        -- вьюмодели. Под Luraph тело обязано быть нативным, иначе каждый кадр
        -- гоняется через VM → фриз при включённом Viewmodel/GunModel.
        local newUpdate = LPH_NO_VIRTUALIZE(function(self, dt, ...)
            -- FIX: хук раньше не проверял `running`, поэтому после M.stop()
            -- продолжал каждый кадр перекрашивать руки/оружие — и откатывал
            -- restoreViewmodelStyle буквально на следующем кадре.
            if not running then return vmOrigRef(self, dt, ...) end
            -- Update() по дампу ничего не возвращает; на всякий случай ловим
            -- до четырёх значений в ФИКСИРОВАННЫЕ локалы (без table.pack).
            local r1, r2, r3, r4 = vmOrigRef(self, dt, ...)   -- ← vmOrigRef, не origFn!
            pcall(vmHookBody, self)
            return r1, r2, r3, r4
        end)

        local wrapped = (type(newcclosure) == "function")
            and newcclosure(newUpdate, "ViewmodelClass.Update")
            or newUpdate

        -- hookfunction возвращает оригинальный безопасный callable
        local hookOk, ret = pcall(hookfunction, origFn, wrapped)
        if hookOk and type(ret) == "function" then
            vmOrigRef  = ret
            vmHooked   = true
            vmHookMode = "hookfunction"
            vmHookFn   = origFn
            vmHookTbl  = cls
            log("Viewmodel hook OK (hookfunction)")
            return true
        end

        -- Fallback: заменяем метод в таблице
        -- В этом случае origFn и есть оригинал — кладём его в vmOrigRef
        vmOrigRef = origFn
        local ok2 = pcall(function() cls.Update = wrapped end)
        if ok2 then
            vmHooked   = true
            vmHookMode = "field"
            vmHookFn   = origFn
            vmHookTbl  = cls
            log("Viewmodel hook OK (table replace fallback)")
            return true
        end
        log("Viewmodel hook FAILED")
        return false
    end

    -- FIX: раньше хук не снимался НИКОГДА. После unload он продолжал жить и
    -- каждый кадр перекрашивал руки/оружие, а повторный запуск скрипта вешал
    -- хук поверх хука. Теперь снимаем ровно тем способом, каким ставили.
    local function unhookViewmodel()
        if not vmHooked then return end
        if vmHookMode == "hookfunction" and vmHookFn and vmOrigRef then
            pcall(hookfunction, vmHookFn, vmOrigRef)
        elseif vmHookMode == "field" and vmHookTbl and vmHookFn then
            pcall(function() vmHookTbl.Update = vmHookFn end)
        end
        vmHooked, vmHookMode, vmHookTbl, vmHookFn, vmOrigRef = false, nil, nil, nil, nil
    end

    -- (gunHighlight объявлен выше, до хука — см. FIX там)

    ---------------------------------------------------------------------------
    -- FOV override (после камеры каждый кадр)
    ---------------------------------------------------------------------------
    local FOV_BIND = "BRM5_FOV"
    local fovBound = false
    local fovApplied = false  -- флаг: мы изменили FOV → надо восстановить при выключении
    -- FIX: восстанавливали жёстко 70. Запоминаем настоящий FOV до первой правки.
    local _origFov = nil
    -- Мировой FOV камеры. ОТДЕЛЬНАЯ фича от «зума рук»: она реально меняет
    -- угол обзора всей сцены (и да, ощущается как смена чувствительности —
    -- это нормально и ожидаемо для FOV, поэт��му вынесено в свой тумблер).
    -- RenderStep callback (каждый кадр после камеры). Под Luraph — нативным.
    local fovStep = LPH_NO_VIRTUALIZE(function()
        local fov = V.WorldFOV or 0
        if V.WorldFOVEnabled and fov > 0 then
            local cam = Workspace.CurrentCamera
            if cam then
                if not _origFov then _origFov = cam.FieldOfView end
                pcall(function() cam.FieldOfView = fov end)
                fovApplied = true
            end
        else
            if fovApplied then
                local cam = Workspace.CurrentCamera
                if cam then pcall(function() cam.FieldOfView = _origFov or 70 end) end
                fovApplied = false
            end
        end
    end)

    -- FIX v3: сам по себе бинд FOV НЕ работал. Roblox гоняет ВСЕ BindToRenderStep
    -- (приоритеты 0..2000) ДО RenderStepped-коннектов, а Flux пересчитывает
    -- Camera.FieldOfView именно в СВОЁМ RenderStepped-коннекте → наша запись
    -- перетиралась каждый кадр ДО рендера при любом приоритете (killaura и
    -- movement упёрлись в то же самое). Бинд оставлен для первичного применения
    -- и восстановления при выкле, а ДЕРЖИТ значение перехват самой записи игры
    -- через GetPropertyChangedSignal — без коллизий с Update-хуком movement.
    local _fovConn, _fovCamConn = nil, nil
    local _fovWriting = false

    local applyFov = LPH_NO_VIRTUALIZE(function(cam)
        local fov = V.WorldFOV or 0
        if not (V.WorldFOVEnabled and fov > 0) then return end
        cam = cam or Workspace.CurrentCamera
        if not cam then return end
        if _origFov == nil then _origFov = cam.FieldOfView end
        if math.abs(cam.FieldOfView - fov) > 0.01 then
            _fovWriting = true
            pcall(function() cam.FieldOfView = fov end)
            _fovWriting = false
        end
        fovApplied = true
    end)

    local function hookFovSignal()
        if _fovConn then _fovConn:Disconnect(); _fovConn = nil end
        local cam = Workspace.CurrentCamera
        if not cam then return end
        -- Flux пишет FieldOfView в СВОЁМ RenderStepped-коннекте, который идёт ПОСЛЕ
        -- всех BindToRenderStep. Поэтому ловим саму запись и перебиваем её.
        _fovConn = cam:GetPropertyChangedSignal("FieldOfView"):Connect(LPH_NO_VIRTUALIZE(function()
            if not _fovWriting then applyFov(cam) end
        end))
    end

    ---------------------------------------------------------------------------
    -- 3. THIRD PERSON SKIN
    ---------------------------------------------------------------------------
    local selfHighlight  = nil
    local tpOrig         = {}   -- [part] = { M, C, T }
    local tpStyledChar   = nil

    -- В этой игре НЕТ Roblox-персонажа (LP.Character почти всегда nil). Тело
    -- живёт на кастомном акторе: _localActor.Character. Берём его И только пока
    -- мы ЖИВЫ (la.Alive) — иначе после смерти будем стилизовать рэгдолл/чужие
    -- модели каждый кадр → просадка FPS.
    local function getSelfCharacter()
        -- FIX (Self Skin «вообще не работает»): раньше функция ВЫХОДИЛА, если
        -- не резолвился Flux-контроллер (getLA). findCtrl зависит от filtergc
        -- и на ��асти экзекуторов/в лобби просто не находит контроллер — и
        -- фича молча ничего не делала, даже когда персонаж ес��ь.
        -- Теперь Flux-путь опционален, а базовый LP.Character работает всегда.
        local la = getLA()
        if type(la) == "table" then
            if rawget(la, "Alive") == false then return nil end
            local ok, char = pcall(function() return la.Character end)
            if ok and typeof(char) == "Instance" and char:IsA("Model") and char.Parent then
                return char
            end
            -- FIX v3: актор «жив», но модели нет → это брошенный (подменённый)
            -- актор: игра пересоздала контроллер, НЕ тронув Alive. Без сброса
            -- кэш _ctrl проходил isCtrl/ctrlAlive вечно, рескана не было, и
            -- скин «интермиттентно» пропадал до конца сессии. Сбрасываем кэш —
            -- findCtrl (затроттленный) пере-найдёт живую пару.
            _ctrl = nil
        end
        local c = LP.Character
        if typeof(c) == "Instance" and c:IsA("Model") and c.Parent then
            -- если есть Humanoid и он мёртв — не стилизуем труп
            local hum = c:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health <= 0 then return nil end
            return c
        end
        return nil
    end

    local function applySelfHighlight(char)
        char = char or getSelfCharacter()
        if not char then return end
        if not (selfHighlight and selfHighlight.Parent) then
            selfHighlight = Instance.new("Highlight")
            selfHighlight.Name = "BRM5_SelfHL"
            selfHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        end
        -- FIX v3: 4 свойства + Parent писались КАЖДЫЙ кадр — теперь только
        -- при реальном изменении (запись свойства дороже чтения).
        local hl = selfHighlight
        if hl.FillColor ~= V.ThirdPersonFill then hl.FillColor = V.ThirdPersonFill end
        if hl.OutlineColor ~= V.ThirdPersonOutline then hl.OutlineColor = V.ThirdPersonOutline end
        if hl.FillTransparency ~= V.ThirdPersonFillTransparency then
            hl.FillTransparency = V.ThirdPersonFillTransparency
        end
        if hl.OutlineTransparency ~= 0 then hl.OutlineTransparency = 0 end
        if hl.Adornee ~= char then hl.Adornee = char end
        if hl.Parent ~= char then hl.Parent = char end
    end

    local function clearSelfHighlight()
        if selfHighlight then
            pcall(function() selfHighlight:Destroy() end)
            selfHighlight = nil
        end
    end

    local function restoreSelfBody()
        for part, s in pairs(tpOrig) do
            -- FIX v3: без гейта `part.Parent` — см. restoreViewmodelStyle
            if part then
                pcall(function() part.Material     = s.M end)
                pcall(function() part.Color        = s.C end)
                pcall(function() part.Transparency = s.T end)
            end
        end
        tpOrig = {}
        tpStyledChar = nil
    end

    -- Части, которые игра прячет НАМЕРЕННО и навсегда — их нельзя проявлять.
    -- Head в BRM5 всегда Transparency=1 (дамп ActorClass:1419: у головы
    -- удаляются Pupil/Mouth, вместо неё рисуется отдельный меш), плюс
    -- служебные коллайдеры и якоря аксессуаров.
    local TP_NEVER_SHOW = {
        Head = true, HumanoidRootPart = true,
        Handle = true, RootPart = true,
    }
    local function tpShouldSkip(d)
        if TP_NEVER_SHOW[d.Name] then return true end
        -- хитбоксы/триггеры: невидимые и без коллизии — служебные
        if d.Transparency >= 1 and d.CanCollide == false then return true end
        -- части внутри аксессуаров/инструментов трогать не надо
        local par = d.Parent
        if par and (par:IsA("Accessory") or par:IsA("Tool")) then return true end
        return false
    end

    local function styleSelfBody(char)
        restoreSelfBody()
        local bodyTranp = V.ThirdPersonBodyTransparency or 0
        local styled = 0
        for _, d in ipairs(char:GetDescendants()) do
            if (d:IsA("BasePart") or d:IsA("MeshPart")) and not tpShouldSkip(d) then
                local origT = d.Transparency
                -- Баланс двух ошибок:
                --  • раньше стоял `if origT >= 1 then continue end` — под него
                --    попадало почти всё тело, и фича не работала вообще;
                --  • затем я снял проверку целиком — и стали проявляться
                --    служебные парты, которые видимыми быть не должны.
                -- Теперь: пропускаем только заведомо служебные (tpShouldSkip),
                -- а у остальных скрытых НЕ трогаем прозрачность — красим лишь
                -- цвет/материал. Так скрытое остаётся скрытым, а видимое
                -- получает скин.
                local isHidden = origT >= 1
                tpOrig[d] = { M = d.Material, C = d.Color, T = origT }
                if V.ThirdPersonMaterial then
                    pcall(function() d.Material = V.ThirdPersonMaterial end)
                end
                pcall(function() d.Color = V.ThirdPersonBodyColor end)
                if not isHidden then
                    pcall(function() d.Transparency = bodyTranp end)
                end
                styled += 1
            end
        end
        tpStyledChar = char
        State._tpStyledCount = styled
    end

    local _tpRestyeT = 0
    -- FIX v7 [SelfSkin]: форс немедленного перекраса тела из UI-колбэков.
    -- styleSelfBody затроттлен (смена персонажа ИЛИ раз в 3с), поэтому смена
    -- цвета/материала/прозрачности проявлялась с задержкой до 3 секунд и
    -- выглядела как «не работает» — приходилось перезапускать фичу, что меняло
    -- tpStyledChar и форсило перекрас. Обнуляем стамп → перекрас на следующем
    -- же heartbeat (~16мс).
    local function tpForceRestyle()
        _tpRestyeT = 0
    end
    local function thirdPersonStep()
        if not V.ThirdPersonEnabled then
            if tpStyledChar then restoreSelfBody() end
            clearSelfHighlight()
            return
        end
        local char = getSelfCharacter()
        if not char then
            -- мертвы / модели ещё нет: чистим виз, НЕ работаем каждый кадр
            if tpStyledChar then restoreSelfBody() end
            clearSelfHighlight()
            return
        end
        applySelfHighlight(char)
        -- FIX: check if character changed OR re-style every 3s to catch late-spawning parts
        -- (avoids calling styleSelfBody / GetDescendants on every single heartbeat frame)
        local t = now()
        if tpStyledChar ~= char or (t - _tpRestyeT) > 3 then
            _tpRestyeT = t
            styleSelfBody(char)
        end
        -- градиент по телу: перекрас каждый кадр под текущую фазу
        if V.ThirdPersonGradientEnabled then
            tickGradientStore(tpOrig, 0.5, now() * (V.GradientSpeed or 0.35))
        end
    end

    ---------------------------------------------------------------------------
    -- 4 + 5. VEHICLE FLY / SPEED
    ---------------------------------------------------------------------------
    -- ── КАК УСТРОЕН ТРАНСПОРТ (по дампу GroundController/VehicleClass) ─────────
    -- Активный контроллер машины (LocalActor.Controller) — это GroundController
    -- с полями: _solver, _tune, _vehicle, _throttle, _localActor. Игра меняет
    -- поведение машины ИМЕННО через _tune + _solver:NewTune() (так работают её
    -- собственные дебаг-слайдеры: AccelerationFactor, Mass, Grip …), а
    -- телепортирует машину методом _solver:SetState(cf, vel, angvel, compRep).
    -- Поэтому:
    --   • VehicleSpeed = увеличить _tune.AccelerationFactor и вызвать NewTune()
    --     (реально меняем параметры транспорта, как и просил юзер);
    --   • VehicleFly  = каждый кадр solver:SetState(новый CFrame, 0, 0, compRep).
    -- Старый код искал несуществующие поля (Throttle/Steering/Seats у объекта
    -- машины, LocalActor.Vehicle) → findVehicle никогда не находил → не работало.
    local function isVehicleController(t)
        if type(t) ~= "table" then return false end
        if type(rawget(t, "_solver")) ~= "table" then return false end
        if type(rawget(t, "_tune"))   ~= "table" then return false end
        local veh = rawget(t, "_vehicle")
        if type(veh) ~= "table" then return false end
        if rawget(veh, "Controlling") == false then return false end -- вышли из машины
        return true
    end
    local _vehCtrl
    local function findVehicleController()
        -- FIX v4 [BUG#2]: кэш проверялся ПЕРВЫМ и перекрывал честный путь через
        -- la.Controller. Единственная проверка на протухание — veh.Controlling,
        -- а его игра опускает только при ШТАТНОМ выходе из машины. Если игрок
        -- погиб от уничтожения машины, клиентская таблица просто выбрасывается
        -- (наша ссылка держит её в GC) с Controlling == true — кэш оставался
        -- «валидным» навсегда, и Fly/Speed до конца сессии работали по
        -- обломкам, не подхватывая новую машину. Сверяем кэш с актуальным
        -- контроллером актора и живостью VehicleMain.
        if isVehicleController(_vehCtrl) then
            local laChk = getLA()
            local cur = type(laChk) == "table" and rawget(laChk, "Controller") or nil
            if isVehicleController(cur) and not rawequal(cur, _vehCtrl) then
                _vehCtrl = nil                       -- игрок уже в ДРУГОЙ машине
            else
                local veh   = rawget(_vehCtrl, "_vehicle")
                local vmain = type(veh) == "table" and rawget(veh, "VehicleMain") or nil
                if typeof(vmain) == "Instance" and vmain.Parent == nil then
                    _vehCtrl = nil                   -- машина уничтожена (взрыв)
                else
                    return _vehCtrl
                end
            end
        end
        _vehCtrl = nil
        -- 1) через LocalActor.Controller — без сканов
        local la = getLA()
        if type(la) == "table" then
            local c = rawget(la, "Controller")
            if isVehicleController(c) then _vehCtrl = c; return c end
        end
        -- 2) GC-скан (троттлится) — персонажный контроллер в машине уничтожен,
        --    поэтому getLA() может не сработать; ищем контроллер напрямую.
        local t = now()
        if t - _lastScan < _scanCd then return nil end
        _lastScan = t
        if type(filtergc) ~= "function" then return nil end
        -- filtergc-проход обёрнут в NO_VIRTUALIZE (нативно под Luraph).
        _vehCtrl = LPH_NO_VIRTUALIZE(function()
            local ok, gc = pcall(filtergc, "table",
                { Keys = { "_solver", "_tune", "_vehicle", "_throttle" } })
            if not ok then return nil end
            for _, v in ipairs(gc) do
                if isVehicleController(v) then return v end
            end
            return nil
        end)()
        return _vehCtrl
    end

    -- восстановление оригинальных параметров машины после VehicleSpeed.
    -- Храним снимок всех тронутых полей tune, чтобы вернуть штатное поведение.
    local _spdTune, _spdOrig, _spdSolver = nil, nil, nil
    local function restoreVehicleSpeed()
        if _spdTune and type(_spdOrig) == "table" then
            pcall(function()
                if _spdOrig.Accel ~= nil then _spdTune.AccelerationFactor = _spdOrig.Accel end
                if _spdOrig.Mass  ~= nil then _spdTune.Mass = _spdOrig.Mass end
                local fw, rw = rawget(_spdTune, "FrontWheels"), rawget(_spdTune, "RearWheels")
                if type(fw) == "table" and _spdOrig.FGrip ~= nil then fw.Grip = _spdOrig.FGrip end
                if type(rw) == "table" and _spdOrig.RGrip ~= nil then rw.Grip = _spdOrig.RGrip end
                if _spdSolver then _spdSolver:NewTune() end
            end)
        end
        _spdTune, _spdOrig, _spdSolver = nil, nil, nil
    end

    local function vehicleStep(dt)
        local wantAny = V.VehicleFlyEnabled or V.VehicleSpeedEnabled
        local ctrl = wantAny and findVehicleController() or nil

        -- вернуть оригинальную скорость, если SpeedHack выключен / сменилась машина
        if _spdTune and not (V.VehicleSpeedEnabled and ctrl and rawequal(rawget(ctrl, "_tune"), _spdTune)) then
            restoreVehicleSpeed()
        end
        if not ctrl then return end

        dt = (type(dt) == "number" and dt > 0) and dt or (1 / 60)
        local solver  = rawget(ctrl, "_solver")
        local vehicle = rawget(ctrl, "_vehicle")
        local tune    = rawget(ctrl, "_tune")

        -- VEHICLE SPEED — меняем параметры транспорта (как дебаг-слайдеры игры).
        -- Прошлый вариант трогал только AccelerationFactor (в игре капается ~1) —
        -- он влияет на РАЗГОН, но почти не на максималку → эффект был незаметен.
        -- Главный рычаг максимальной скорости — Mass: при фиксированной силе движка
        -- и сопротивлении лёгкая машина имеет и выше разгон, и выше терминальную
        -- скорость. Дополнительно поднимаем Grip, чтобы на скорости не срывало.
        if V.VehicleSpeedEnabled and type(tune) == "table" then
            local mult = V.VehicleSpeedMult or 2
            if mult < 1 then mult = 1 end
            if not rawequal(_spdTune, tune) then
                restoreVehicleSpeed()
                _spdTune, _spdSolver = tune, solver
                local fw, rw = rawget(tune, "FrontWheels"), rawget(tune, "RearWheels")
                _spdOrig = {
                    Accel = rawget(tune, "AccelerationFactor"),
                    Mass  = rawget(tune, "Mass"),
                    FGrip = type(fw) == "table" and rawget(fw, "Grip") or nil,
                    RGrip = type(rw) == "table" and rawget(rw, "Grip") or nil,
                }
            end
            local o = _spdOrig
            -- целевые значения
            local wantMass  = (type(o.Mass) == "number") and (o.Mass / mult) or nil
            local wantAccel = (type(o.Accel) == "number") and math.min(o.Accel * mult, 1) or nil
            local wantFGrip = (type(o.FGrip) == "number") and (o.FGrip * math.min(mult, 3)) or nil
            local wantRGrip = (type(o.RGrip) == "number") and (o.RGrip * math.min(mult, 3)) or nil
            local dirty = false
            pcall(function()
                if wantMass and rawget(tune, "Mass") ~= wantMass then tune.Mass = wantMass; dirty = true end
                if wantAccel and rawget(tune, "AccelerationFactor") ~= wantAccel then tune.AccelerationFactor = wantAccel; dirty = true end
                local fw, rw = rawget(tune, "FrontWheels"), rawget(tune, "RearWheels")
                if type(fw) == "table" and wantFGrip and rawget(fw, "Grip") ~= wantFGrip then fw.Grip = wantFGrip; dirty = true end
                if type(rw) == "table" and wantRGrip and rawget(rw, "Grip") ~= wantRGrip then rw.Grip = wantRGrip; dirty = true end
                if dirty then solver:NewTune() end
            end)
        end

        -- VEHICLE FLY — репозиционируем машину штатным solver:SetState
        if V.VehicleFlyEnabled then
            local cam = Workspace.CurrentCamera
            if not cam then return end
            local baseCF = rawget(vehicle, "CFrame")
            if typeof(baseCF) ~= "CFrame" then
                local st = rawget(solver, "_state")
                if type(st) == "table" and typeof(st.CFrame) == "CFrame" then
                    baseCF = st.CFrame
                end
            end
            if typeof(baseCF) ~= "CFrame" then return end
            local dir = Vector3.zero
            if UIS:IsKeyDown(Enum.KeyCode.W)           then dir += cam.CFrame.LookVector end
            if UIS:IsKeyDown(Enum.KeyCode.S)           then dir -= cam.CFrame.LookVector end
            if UIS:IsKeyDown(Enum.KeyCode.A)           then dir -= cam.CFrame.RightVector end
            if UIS:IsKeyDown(Enum.KeyCode.D)           then dir += cam.CFrame.RightVector end
            if UIS:IsKeyDown(Enum.KeyCode.Space)       then dir += Vector3.yAxis end
            if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
            local step = (dir.Magnitude > 0.001)
                and (dir.Unit * (V.VehicleFlySpeed or 120) * dt)
                or  Vector3.zero
            local newCF = baseCF.Rotation + (baseCF.Position + step)
            local compRep = rawget(vehicle, "ComponentReplicates")
            pcall(function()
                solver:SetState(newCF, Vector3.zero, Vector3.zero, compRep)
            end)
            -- двигаем и VehicleMain, чтобы визуально не «резинило»
            local vm = rawget(vehicle, "VehicleMain")
            if typeof(vm) == "Instance" then
                pcall(function()
                    local p = vm:IsA("BasePart") and vm or vm.PrimaryPart
                    if p then p.CFrame = newCF end
                end)
            end
        end
    end

    ---------------------------------------------------------------------------
    -- 5b. FREE GUN — снять блок экипировки оружия
    ---------------------------------------------------------------------------
    -- Блок находится в InventoryService._canEquip(self, localActor):
    --   • HeightState == Sitting (в транспорте) и not SeatCanEquip → false
    --   • Climbing/Vaulting/Swimming/Skydiving/Parachuting → false
    -- Хукаем сам метод: пока FreeGunEnabled — возвращаем true (живым, с контроллером).
    -- Хук ставится один раз и гейтится флагом, поэтому при выкле остаётся инертным
    -- (та же схема, что и у Viewmodel-хука выше).
    local _canEquipHooked = false
    local _canEquipCallOrig = nil        -- вызываемый оригинал
    local _fgScanCd = 0
    -- FIX: не хранили ни таблицу, ни режим установки → снять хук было нечем.
    local _fgTbl, _fgMode, _fgRawFn = nil, nil, nil
    -- FIX: SeatCanEquip форсился в true и никогда не возвращался обратно —
    -- фича «выключена», а оружие в транспорте всё равно достаётся.
    local _fgSeatOrig = nil
    local function installFreeGunHook()
        if _canEquipHooked then return true end
        local t = now()
        if t - _fgScanCd < 2.0 then return false end
        _fgScanCd = t
        if type(filtergc) ~= "function" then return false end
        -- filtergc-проход обёрнут в NO_VIRTUALIZE (нативно под Luraph), иначе
        -- один проход по раздутому GC вешает игру.
        local res = LPH_NO_VIRTUALIZE(function()
            local ok, r = pcall(filtergc, "table",
                { Keys = { "_canEquip", "_cycle", "_sync" } })
            if not ok or type(r) ~= "table" then return nil end
            return r
        end)()
        if type(res) ~= "table" then return false end
        for _, tbl in ipairs(res) do
            local fn = rawget(tbl, "_canEquip")
            if type(fn) == "function" then
                _canEquipCallOrig = fn
                -- _canEquip зовётся движком при проверке экипировки. Нативно.
                local wrapper = LPH_NO_VIRTUALIZE(function(self, la)
                    if V.FreeGunEnabled and la and la.Alive
                        and la.Controller and not la.Downed then
                        return true
                    end
                    return _canEquipCallOrig(self, la)
                end)
                -- 1) замена поля класса (обратимо и без детуров)
                local setOk = pcall(function() tbl._canEquip = wrapper end)
                if setOk and rawget(tbl, "_canEquip") == wrapper then
                    _canEquipHooked = true
                    _fgTbl, _fgMode, _fgRawFn = tbl, "field", fn
                    log("FreeGun: _canEquip перехвачен (field)")
                    return true
                end
                -- 2) таблица заморожена → hookfunction (origRef = callable оригинал)
                if type(hookfunction) == "function" then
                    local hookOk, origRef = pcall(hookfunction, fn, wrapper)
                    if hookOk then
                        _canEquipCallOrig = (type(origRef) == "function") and origRef or fn
                        _canEquipHooked = true
                        _fgTbl, _fgMode, _fgRawFn = tbl, "hookfunction", fn
                        log("FreeGun: _canEquip перехвачен (hookfunction)")
                        return true
                    end
                end
            end
        end
        return false
    end

    -- FIX v3: возврат SeatCanEquip вынесен отдельно — его обязан звать и
    -- ОБЫЧНЫЙ выкл тоггла (UI/хоткей), а не только M.stop, иначе поле игры
    -- оставалось пропатченным до выгрузки.
    local function restoreFreeGunSeat()
        if _fgSeatOrig ~= nil then
            pcall(function()
                local la = getLA()
                if type(la) == "table" then la.SeatCanEquip = _fgSeatOrig end
            end)
            _fgSeatOrig = nil
        end
    end

    -- FIX: полностью снимаем FreeGun — и хук, и форс SeatCanEquip.
    -- FIX v3: больше НЕ форсим V.FreeGunEnabled = false — ни одна другая фича
    -- не мутирует конфиг юзера при снятии, эта тоже не должна.
    local function restoreFreeGunHook()
        restoreFreeGunSeat()
        if not _canEquipHooked then return end
        if _fgMode == "field" and _fgTbl and _canEquipCallOrig then
            pcall(function() _fgTbl._canEquip = _canEquipCallOrig end)
        elseif _fgMode == "hookfunction" and _fgRawFn and _canEquipCallOrig then
            pcall(hookfunction, _fgRawFn, _canEquipCallOrig)
        end
        _canEquipHooked = false
        _fgTbl, _fgMode, _fgRawFn = nil, nil, nil
    end

    local function freeGunStep()
        if not V.FreeGunEnabled then return end
        if not _canEquipHooked then installFreeGunHook() end
        -- лёгкий фолбэк для транспорта: разрешаем экипировку в сиденье
        local la = getLA()
        -- FIX v4 [BUG#2]: на экране смерти findCtrl намеренно возвращает МЁРТВЫЙ
        -- кэш («мы реально мертвы»), поэтому getLA отдавал труп. _fgSeatOrig
        -- захватывался с трупа из прошлой жизни, и потом этот «оригинал»
        -- restoreFreeGunSeat писал уже ЖИВОМУ актору — FreeGun после выключения
        -- оставлял поле игры в неверном состоянии. Мёртвых не трогаем.
        if type(la) == "table" and rawget(la, "Alive") ~= false
        and rawget(la, "SeatCanEquip") ~= true then
            -- запоминаем исходное значение ОДИН раз, чтобы вернуть его в stop
            if _fgSeatOrig == nil then _fgSeatOrig = rawget(la, "SeatCanEquip") or false end
            pcall(function() la.SeatCanEquip = true end)
        end
    end

    ---------------------------------------------------------------------------
    -- 6 + bonus. AMBIENT / FULLBRIGHT / NOFOG
    ---------------------------------------------------------------------------
    local lightSaved, lightSavedOK = {}, false
    local function saveLighting()
        if lightSavedOK then return end
        lightSaved = {
            ClockTime    = Lighting.ClockTime,
            Brightness   = Lighting.Brightness,
            Ambient      = Lighting.Ambient,
            OutdoorAmbient = Lighting.OutdoorAmbient,
            FogEnd       = Lighting.FogEnd,
            FogStart     = Lighting.FogStart,
            GlobalShadows = Lighting.GlobalShadows,
            -- расширенная атмосфера
            FogColor        = Lighting.FogColor,
            ColorShift_Top  = Lighting.ColorShift_Top,
            ColorShift_Bottom = Lighting.ColorShift_Bottom,
            ExposureCompensation = Lighting.ExposureCompensation,
            GeographicLatitude = Lighting.GeographicLatitude,
            EnvironmentDiffuseScale  = Lighting.EnvironmentDiffuseScale,
            EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
        }
        lightSavedOK = true
    end
    local function restoreLighting()
        if not lightSavedOK then return end
        pcall(function()
            Lighting.ClockTime     = lightSaved.ClockTime
            Lighting.Brightness    = lightSaved.Brightness
            Lighting.Ambient       = lightSaved.Ambient
            Lighting.OutdoorAmbient = lightSaved.OutdoorAmbient
            Lighting.FogEnd        = lightSaved.FogEnd
            Lighting.FogStart      = lightSaved.FogStart
            Lighting.GlobalShadows  = lightSaved.GlobalShadows
            Lighting.FogColor       = lightSaved.FogColor
            Lighting.ColorShift_Top = lightSaved.ColorShift_Top
            Lighting.ColorShift_Bottom = lightSaved.ColorShift_Bottom
            Lighting.ExposureCompensation = lightSaved.ExposureCompensation
            Lighting.GeographicLatitude   = lightSaved.GeographicLatitude
            Lighting.EnvironmentDiffuseScale  = lightSaved.EnvironmentDiffuseScale
            Lighting.EnvironmentSpecularScale = lightSaved.EnvironmentSpecularScale
        end)
    end

    -- Константа: раньше два Color3 создавались каждый кадр при Fullbright
    local FULLBRIGHT_COL = Color3.fromRGB(178, 178, 178)

    -- ═══════════════════════════════════════════════════════════════════════
    -- FIX v5 [МЕЛЬКАНИЕ ATMOSPHERE] Игра перезаписывает освещение каждый кадр.
    --
    -- ПРИЧИНА (из дампа Flux/Services/EnvironmentService.Update):
    --   строка 605:  Lighting.ClockTime          = ClockTime
    --   строка 702:  Lighting.GeographicLatitude = v81.GeographicLatitude or ...
    --   строка 829:  if not v81.NoColors then
    --                    Lighting.ColorShift_Top = ...
    --                    Lighting.OutdoorAmbient = ...
    --                end
    -- Update зовётся из per-frame Stepped клиента, то есть игра пишет эти
    -- четыре свойства 60 раз в секунду. Наш полный проход по Lighting был
    -- затроттлен до ~4 Гц (perf-фикс v3), поэтому из каждых ~15 кадров наши
    -- значения держались только в одном — отсюда мельканиe между нашей
    -- атмосферой и игровой.
    --
    -- РЕШЕНИЕ — ровно тот же приём, что уже применён здесь для FOV: не гонять
    -- запись каждый кадр (это и есть фриз), а ПЕРЕБИВАТЬ саму запись игры через
    -- GetPropertyChangedSignal. Событийно: ноль стоимости, когда игра молчит, и
    -- коррекция в том же кадре, когда пишет → окно мелькания нулевое.
    --
    -- ClockTime вдобавок решается совсем без борьбы: игра берёт его из
    -- Lighting:GetAttribute("ClockTime") (строка 588 дампа). Пишем АТРИБУТ — и
    -- игра сама, своей же рукой, ставит наше время суток каждый кадр.
    --
    -- Незатронутые свойства (Ambient, Brightness, ColorShift_Bottom, Fog*,
    -- Exposure, GlobalShadows, EnvironmentDiffuse/Specular) игра НЕ пишет —
    -- они остаются на дешёвом 4 Гц проходе, перф не теряем.
    -- ═══════════════════════════════════════════════════════════════════════
    local _lightConns   = {}      -- [prop] = RBXScriptConnection
    local _lightWriting = false   -- анти-рекурсия: наша запись тоже дёргает сигнал
    local _ctAttrConn   = nil
    local _ctAttrOrig   = nil
    local _ctAttrSet    = false

    -- Fullbright сохраняет ОТТЕНОК пользователя, берёт только светимость
    -- (FIX v4 [BUG#4]). Единый источник истины: формулу зовут и lightingStep,
    -- и re-assert по сигналу — иначе OutdoorAmbient дёргался бы между двумя
    -- независимо посчитанными «правильными» цветами.
    local function liftToFullbright(c)
        if typeof(c) ~= "Color3" then return FULLBRIGHT_COL end
        local peak = math.max(c.R, c.G, c.B)
        if peak < 0.02 then return FULLBRIGHT_COL end
        local k = math.max(1, FULLBRIGHT_COL.R / peak)   -- целевая светимость
        return Color3.new(
            math.min(c.R * k, 1),
            math.min(c.G * k, 1),
            math.min(c.B * k, 1))
    end

    -- Цель для контестируемого свойства; nil = сейчас не наше, не трогаем.
    --
    -- FIX v6: НАЙДЕН ВТОРОЙ ПИСАТЕЛЬ — Flux/Services/PostProcessingService.
    -- Его Update (строка 59 дампа) тоже идёт каждый кадр и пишет:
    --   L53   Lighting.Ambient              = not RGE and p4.Ambient or Color3.new()
    --   L217  Lighting.Brightness           = v21   (сумма вкладов _brightness)
    --   L237  Lighting.ExposureCompensation = v22   (сумма вкладов _exposures)
    -- В v5 я считал эти три «неконтестируемыми» (в EnvironmentService их нет) —
    -- поэтому Fullbright продолжал мелькать (он живёт ровно на Ambient +
    -- Brightness), а у Atmosphere мелькали Shadow Tint, Brightness и Exposure.
    local function contestedTarget(prop)
        local amb = V.AmbientEnabled
        local fb  = V.FullbrightEnabled

        if prop == "Ambient" then
            -- Fullbright работает и БЕЗ Atmosphere — это его основное свойство.
            if fb then
                if amb then return liftToFullbright(V.AmbientColor) end
                return FULLBRIGHT_COL
            end
            if amb then return V.AmbientColor end
            return nil

        elseif prop == "OutdoorAmbient" then
            -- как и Ambient: Fullbright им владеет даже без Atmosphere
            if fb then
                if amb then return liftToFullbright(V.AmbientOutdoorColor) end
                return FULLBRIGHT_COL
            end
            if amb then return V.AmbientOutdoorColor end
            return nil

        elseif prop == "Brightness" then
            -- ВАЖНО: раньше Fullbright писал math.max(Lighting.Brightness, 2) —
            -- ЧТЕНИЕ живого свойства. PostProcessingService перезаписывает его
            -- каждый кадр, поэтому результат зависел от того, кто отработал
            -- последним → значение прыгало само по себе. Считаем ТОЛЬКО из
            -- своего конфига и сохранённого оригинала — стабильно между кадрами.
            local base
            if amb then base = V.AmbientBrightness end
            if type(base) ~= "number" then
                base = (lightSavedOK and type(lightSaved.Brightness) == "number")
                       and lightSaved.Brightness or 2
            end
            if fb then return math.max(base, 2) end
            if amb then return base end
            return nil

        elseif prop == "ExposureCompensation" then
            if amb then return V.AmbientExposure or 0 end
            return nil
        end

        -- дальше — только атмосферные, вне Atmosphere не наши
        if not amb then return nil end
        if prop == "GeographicLatitude" then
            return V.AmbientLatitude or 45
        elseif prop == "ColorShift_Top" then
            return V.AmbientTintTop
        end
        return nil
    end

    local CONTESTED = {
        -- EnvironmentService.Update
        "GeographicLatitude", "ColorShift_Top", "OutdoorAmbient",
        -- PostProcessingService.Update  (FIX v6 — причина мелькания Fullbright)
        "Ambient", "Brightness", "ExposureCompensation",
    }

    local function reassertLightProp(prop)
        if _lightWriting then return end
        local want = contestedTarget(prop)
        if want == nil then return end
        local cur = Lighting[prop]
        if cur == want then return end   -- уже наше — не пишем (иначе эхо-цикл)
        _lightWriting = true
        pcall(function() Lighting[prop] = want end)
        _lightWriting = false
    end

    local function hookLightingSignals()
        for _, prop in ipairs(CONTESTED) do
            if not _lightConns[prop] then
                local ok, conn = pcall(function()
                    return Lighting:GetPropertyChangedSignal(prop):Connect(
                        LPH_NO_VIRTUALIZE(function() reassertLightProp(prop) end))
                end)
                if ok then _lightConns[prop] = conn end
            end
        end
        -- ClockTime: пишем атрибут, который игра читает сама. Плюс страховка —
        -- если сервер пушнёт своё значение, вернём наше (событийно, не в кадре).
        if not _ctAttrConn then
            local ok, conn = pcall(function()
                return Lighting:GetAttributeChangedSignal("ClockTime"):Connect(
                    LPH_NO_VIRTUALIZE(function()
                        if _lightWriting or not V.AmbientEnabled then return end
                        local want = V.AmbientClockTime
                        if type(want) ~= "number" then return end
                        if Lighting:GetAttribute("ClockTime") == want then return end
                        _lightWriting = true
                        pcall(function() Lighting:SetAttribute("ClockTime", want) end)
                        _lightWriting = false
                    end))
            end)
            if ok then _ctAttrConn = conn end
        end
    end

    local function unhookLightingSignals()
        for prop, conn in pairs(_lightConns) do
            pcall(function() conn:Disconnect() end)
            _lightConns[prop] = nil
        end
        if _ctAttrConn then pcall(function() _ctAttrConn:Disconnect() end); _ctAttrConn = nil end
        -- возвращаем атрибут времени суток игре
        if _ctAttrSet then
            _lightWriting = true
            pcall(function() Lighting:SetAttribute("ClockTime", _ctAttrOrig) end)
            _lightWriting = false
            _ctAttrSet, _ctAttrOrig = false, nil
        end
    end

    -- ═══════════════════════════════════════════════════════════════════════
    -- FIX v5 [МЕЛЬКАНИЕ ТУМАНА] Игровой Atmosphere-инстанс.
    --
    -- Кроме свойств Lighting, EnvironmentService держит СВОЙ объект Atmosphere
    -- (p78._atmosphere) и анимирует его каждый кадр (дамп, строки 746-752):
    --   _atmosphere.Density = ...   _atmosphere.Color = ...:Lerp(...)
    --   _atmosphere.Decay   = ...   _atmosphere.Glare / .Haze = Lerp(...)
    -- Atmosphere в Roblox рендерится ПОВЕРХ Lighting.Fog* — поэтому наш
    -- Custom Fog визуально боролся с игровой дымкой, которая ещё и плавно
    -- лерпится каждый кадр. Обнулять её свойства бессмысленно: игра перепишет
    -- их в том же кадре (та же причина, что и с ColorShift_Top).
    --
    -- Решение — ровно то, что делает сама игра в SetOverride при NoColors
    -- (дамп, строки 556-563): `p70._atmosphere.Parent = nil`. Отпарентченный
    -- Atmosphere не рендерится, а игровые записи в него становятся безвредными
    -- — мелькать больше нечему. Состояние поддерживаемое: это её же ветка кода.
    -- ═══════════════════════════════════════════════════════════════════════
    local _gameAtmo, _gameAtmoParent = nil, nil
    local function parkGameAtmosphere()
        if _gameAtmo then return end
        local ok, atmo = pcall(function()
            return Lighting:FindFirstChildOfClass("Atmosphere")
        end)
        if not ok or not atmo then return end
        _gameAtmo, _gameAtmoParent = atmo, atmo.Parent
        pcall(function() atmo.Parent = nil end)
    end
    local function restoreGameAtmosphere()
        if not _gameAtmo then return end
        pcall(function() _gameAtmo.Parent = _gameAtmoParent end)
        _gameAtmo, _gameAtmoParent = nil, nil
    end

    -- Ставит наше время суток через атрибут (игра сама применит его в Update).
    local function applyClockTimeViaAttribute()
        local want = V.AmbientClockTime
        if type(want) ~= "number" then return false end
        local okRead, cur = pcall(function() return Lighting:GetAttribute("ClockTime") end)
        if not okRead then return false end
        if cur == nil then return false end          -- атрибута нет — работаем по свойству
        if not _ctAttrSet then
            _ctAttrOrig = cur
            _ctAttrSet = true
        end
        if cur ~= want then
            _lightWriting = true
            pcall(function() Lighting:SetAttribute("ClockTime", want) end)
            _lightWriting = false
        end
        return true
    end

    -- ── Готовые атмосферы ──────────────────────────────────────────────
    -- Крутить 12 ползунков вручную, чтобы получить нормальный вайб, —
    -- неудобно. Пресет ставит всё разом, дальше можно доводить руками
    -- (любая правка ползунка переводит пресет в "Custom").
    local AMBIENT_PRESETS = {
        Midnight = {
            ClockTime = 0, Brightness = 1.2, Exposure = 0.15,
            Ambient = Color3.fromRGB(38, 44, 70),
            Outdoor = Color3.fromRGB(48, 56, 88),
            TintTop = Color3.fromRGB(20, 28, 60), TintBottom = Color3.fromRGB(0, 0, 0),
            Fog = true, FogColor = Color3.fromRGB(18, 22, 40), FogStart = 0, FogEnd = 420,
            Shadows = true, Latitude = 20,
        },
        Sunset = {
            ClockTime = 17.6, Brightness = 2.4, Exposure = 0.2,
            Ambient = Color3.fromRGB(120, 78, 62),
            Outdoor = Color3.fromRGB(178, 108, 70),
            TintTop = Color3.fromRGB(255, 150, 70), TintBottom = Color3.fromRGB(40, 20, 30),
            Fog = true, FogColor = Color3.fromRGB(220, 130, 85), FogStart = 40, FogEnd = 1400,
            Shadows = true, Latitude = 60,
        },
        Overcast = {
            ClockTime = 11, Brightness = 1.8, Exposure = -0.1,
            Ambient = Color3.fromRGB(120, 124, 132),
            Outdoor = Color3.fromRGB(150, 155, 165),
            TintTop = Color3.fromRGB(180, 190, 200), TintBottom = Color3.fromRGB(0, 0, 0),
            Fog = true, FogColor = Color3.fromRGB(168, 175, 185), FogStart = 20, FogEnd = 700,
            Shadows = false, Latitude = 45,
        },
        Toxic = {
            ClockTime = 14, Brightness = 2.2, Exposure = 0.35,
            Ambient = Color3.fromRGB(70, 105, 55),
            Outdoor = Color3.fromRGB(120, 165, 70),
            TintTop = Color3.fromRGB(150, 255, 90), TintBottom = Color3.fromRGB(20, 40, 10),
            Fog = true, FogColor = Color3.fromRGB(110, 160, 70), FogStart = 0, FogEnd = 520,
            Shadows = true, Latitude = 45,
        },
        Nightvision = {
            ClockTime = 12, Brightness = 4.5, Exposure = 0.6,
            Ambient = Color3.fromRGB(90, 190, 90),
            Outdoor = Color3.fromRGB(110, 220, 110),
            TintTop = Color3.fromRGB(120, 255, 120), TintBottom = Color3.fromRGB(0, 30, 0),
            Fog = false, FogColor = Color3.fromRGB(40, 90, 40), FogStart = 0, FogEnd = 2000,
            Shadows = false, Latitude = 45,
        },
        Clear = {
            ClockTime = 13, Brightness = 2.6, Exposure = 0,
            Ambient = Color3.fromRGB(130, 135, 145),
            Outdoor = Color3.fromRGB(160, 168, 180),
            TintTop = Color3.fromRGB(0, 0, 0), TintBottom = Color3.fromRGB(0, 0, 0),
            Fog = false, FogColor = Color3.fromRGB(180, 190, 200), FogStart = 0, FogEnd = 5000,
            Shadows = true, Latitude = 45,
        },
    }
    local AMBIENT_PRESET_ORDER = {
        "Custom", "Clear", "Midnight", "Sunset", "Overcast", "Toxic", "Nightvision",
    }

    local function applyAmbientPreset(name)
        local pr = AMBIENT_PRESETS[name]
        if not pr then return false end
        V.AmbientClockTime      = pr.ClockTime
        V.AmbientBrightness     = pr.Brightness
        V.AmbientExposure       = pr.Exposure
        V.AmbientColor          = pr.Ambient
        V.AmbientOutdoorColor   = pr.Outdoor
        V.AmbientTintTop        = pr.TintTop
        V.AmbientTintBottom     = pr.TintBottom
        V.AmbientFogEnabled     = pr.Fog
        V.AmbientFogColor       = pr.FogColor
        V.AmbientFogStart       = pr.FogStart
        V.AmbientFogEnd         = pr.FogEnd
        V.AmbientShadows        = pr.Shadows
        V.AmbientLatitude       = pr.Latitude
        V.AmbientPreset         = name
        return true
    end
    -- FIX v3 (перф): до 14 записей в Lighting шли КАЖДЫЙ кадр. Полный проход
    -- теперь ~4 Гц; ClockTime — исключение, игра его анимирует, поэтому он
    -- перебивается каждый кадр (но пишется только при реальном отличии).
    local _lightT = -999
    local function lightingStep()
        local amb, fb, nofog = V.AmbientEnabled, V.FullbrightEnabled, V.NoFogEnabled
        if not (amb or fb or nofog) then return end
        -- FIX v4 [BUG#2]: ПЕРВЫЙ снапшот Lighting нельзя снимать на экране
        -- смерти — игра тонирует Lighting под своё death-состояние, снимок
        -- one-shot, и потом lightingOff() навсегда «восстанавливал» мёртвый
        -- вайб вместо освещения карты. Хоткеи и UI на экране смерти работают,
        -- так что попасть сюда мёртвым — обычное дело.
        if not lightSavedOK then
            local laL = getLA()
            if type(laL) == "table" and rawget(laL, "Alive") == false then return end
        end
        saveLighting()
        -- FIX v5/v6 [МЕЛЬКАНИЕ]: сигналы на контестируемые свойства ставим ровно
        -- один раз (idempotent). Гейт `amb or fb`, а не только `amb`:
        -- Fullbright живёт на Ambient + Brightness, которые перезаписывает
        -- PostProcessingService каждый кадр — при одном включённом Fullbright
        -- (без Atmosphere) сигналы раньше вообще не ставились, и он мелькал.
        if amb or fb then
            hookLightingSignals()
        end
        if amb then
            -- ClockTime: сначала пробуем атрибут — игра читает его в Update и
            -- сама поставит наше время (см. EnvironmentService строка 588).
            -- Борьбы нет вообще. Если атрибута нет — падаем на прямую запись,
            -- как раньше (она нужна каждый кадр, игру никто не перебьёт иначе).
            if not applyClockTimeViaAttribute() then
                pcall(function()
                    if Lighting.ClockTime ~= V.AmbientClockTime then
                        Lighting.ClockTime = V.AmbientClockTime
                    end
                end)
            end
        end
        local tL = now()
        if tL - _lightT < 0.25 then return end
        _lightT = tL
        -- Atmosphere: полноценная кастомизация вайба (время суток, оттенки,
        -- экспозиция, туман). Раньше тут было только время + яркость.
        if amb then
            pcall(function()
                -- FIX v6: контестируемые свойства пишем ИСКЛЮЧИТЕЛЬНО через
                -- contestedTarget — тот же источник истины, что у re-assert по
                -- сигналу. Иначе 4 Гц проход и сигнал считали бы «правильное»
                -- значение независимо и дёргали свойство между двумя разными
                -- корректными числами (особенно Brightness при Fullbright).
                for _, p in ipairs(CONTESTED) do
                    local want = contestedTarget(p)
                    if want ~= nil and Lighting[p] ~= want then
                        Lighting[p] = want
                    end
                end
                -- НЕконтестируемые (игра их не пишет ни в одном сервисе):
                -- GeographicLatitude отсюда УБРАН — он в CONTESTED (дубль писал
                -- бы то же значение вторым путём, мимо единого источника истины).
                Lighting.ColorShift_Bottom = V.AmbientTintBottom
                Lighting.EnvironmentDiffuseScale  = V.AmbientDiffuse  or 1
                Lighting.EnvironmentSpecularScale = V.AmbientSpecular or 1
                Lighting.GlobalShadows = V.AmbientShadows ~= false
                if V.AmbientFogEnabled then
                    Lighting.FogColor = V.AmbientFogColor
                    Lighting.FogStart = V.AmbientFogStart or 0
                    Lighting.FogEnd   = V.AmbientFogEnd or 800
                end
            end)
        end
        -- Fullbright — отдельная простая фича: просто «видно всё».
        --
        -- FIX v4 [BUG#4]: раньше Fullbright БЕЗУСЛОВНО писал серый
        -- FULLBRIGHT_COL в Ambient/OutdoorAmbient — уже ПОСЛЕ ambient-ветки.
        -- При обеих включённых фичах выбранные Shadow/Outdoor Tint молча
        -- заменялись на серый 178,178,178: пользователь тыкал цвет в пикере, а
        -- на экране видел серость. Это одна из причин «цвет Atmosphere не тот,
        -- что указан в UI». Теперь при активной Atmosphere сохраняем ОТТЕНОК
        -- пользователя, а от Fullbright берём только яркость: поднимаем цвет до
        -- нужной светимости, не убивая тон.
        -- FIX v5: сам lift вынесен в liftToFullbright (объявлен выше) — его же
        -- использует contestedTarget("OutdoorAmbient") в re-assert по сигналу.
        -- Раньше формула жила локально внутри этого pcall, и re-assert считал бы
        -- своё значение независимо → OutdoorAmbient дёргался бы между двумя
        -- разными «правильными» цветами.
        -- FIX v6 [МЕЛЬКАНИЕ FULLBRIGHT]: тут стояло
        --     Lighting.Brightness = math.max(Lighting.Brightness, 2)
        -- то есть ЧТЕНИЕ живого свойства. А PostProcessingService.Update
        -- (строка 217 дампа) перезаписывает Brightness КАЖДЫЙ кадр своей суммой
        -- вкладов. Значит max() считался то от нашего значения, то от игрового —
        -- яркость прыгала сама по себе, даже без Atmosphere. Плюс Ambient/
        -- OutdoorAmbient писались тут в третий раз, независимо от 4 Гц прохода и
        -- от re-assert. Теперь всё контестируемое идёт ОДНИМ путём через
        -- contestedTarget, а Fullbright-специфичного осталось только отключение
        -- теней (GlobalShadows игра не пишет — это единственное его «своё»).
        if fb then
            pcall(function()
                for _, p in ipairs(CONTESTED) do
                    local want = contestedTarget(p)
                    if want ~= nil and Lighting[p] ~= want then
                        Lighting[p] = want
                    end
                end
                Lighting.GlobalShadows = false
            end)
        end
        if nofog then
            pcall(function()
                Lighting.FogEnd   = 1e9
                Lighting.FogStart = 1e9
            end)
        end
        -- FIX v5: решение по игровой дымке — СНАРУЖИ ветки amb.
        -- Держать его внутри `if amb` было ошибкой: при включённом No Fog и
        -- выключенной Atmosphere парковка не выполнялась вообще, и «No Fog» не
        -- убирал туман до конца — игровой Atmosphere рендерится поверх Fog* и
        -- давал остаточную дымку (плюс лерпился каждый кадр).
        if (amb and V.AmbientFogEnabled) or nofog then
            parkGameAtmosphere()
        else
            restoreGameAtmosphere()
        end
    end

    -- FIX v3: общий off-путь Ambient/Fullbright/NoFog. Раньше его имели ТОЛЬКО
    -- хоткеи — UI-тогглы лишь снимали флаг, lightingStep переставал писать, и
    -- мир оставался перекрашенным насовсем. Ещё включённые соседи пере-применят
    -- своё следующим heartbeat (_lightT сброшен → без 250мс мигания).
    local function lightingOff()
        -- FIX v5 [МЕЛЬКАНИЕ]: сначала снимаем сигналы, иначе наш же
        -- re-assert перебил бы restoreLighting и мир остался бы перекрашенным.
        unhookLightingSignals()
        restoreGameAtmosphere()   -- возвращаем игровую дымку на место
        restoreLighting()
        lightSavedOK = false
        _lightT = -999
    end

    ---------------------------------------------------------------------------
    -- 7. NO F WAIT
    ---------------------------------------------------------------------------
    -- ВАЖНО: игра НЕ использует HoldDuration прокси-промпта для тайминга.
    -- InteractionInterface при нажатии читает АТРИБУТ "Timer" промпта и держит
    -- задачу PromptTask ровно Timer секунд (см. дамп InteractionInterface:Enable
    -- → prompt:GetAttribute("Timer")). Поэтому чтобы убрать ожидание, обнуляем
    -- атрибут "Timer" (0 → задача финиширует в тот же кадр). HoldDuration тоже
    -- зануляем — на случай промптов со штатным нативным триггеро��.
    local promptConn = nil
    local promptAttrConn = {}
    local function zeroPrompt(p)
        if not (p and p:IsA("ProximityPrompt")) then return end
        pcall(function()
            local t = p:GetAttribute("Timer")
            if type(t) == "number" and t > 0 and p:GetAttribute("BRM5_timer") == nil then
                p:SetAttribute("BRM5_timer", t)
            end
            if p:GetAttribute("BRM5_hold") == nil then
                p:SetAttribute("BRM5_hold", p.HoldDuration)
            end
            if p:GetAttribute("Timer") ~= nil then p:SetAttribute("Timer", 0) end
            p.HoldDuration = 0
        end)
        -- сервер/игра могут переустановить Timer → держим его в 0, пока фича вкл
        if not promptAttrConn[p] then
            local attrC = p:GetAttributeChangedSignal("Timer"):Connect(function()
                if V.NoFWaitEnabled and p:GetAttribute("Timer") and p:GetAttribute("Timer") ~= 0 then
                    pcall(function() p:SetAttribute("Timer", 0) end)
                end
            end)
            -- FIX v3: промпт, уничтоженный при включённой фиче, оставлял и ключ,
            -- и коннект НАВСЕГДА (таблица только росла). Чистим по Destroying.
            local dstC = p.Destroying:Connect(function()
                local rec = promptAttrConn[p]
                promptAttrConn[p] = nil
                if rec then
                    pcall(function() rec[1]:Disconnect() end)
                    pcall(function() rec[2]:Disconnect() end)
                end
            end)
            promptAttrConn[p] = { attrC, dstC }
        end
    end
    local function enableNoFWait()
        if promptConn then return end
        for _, d in ipairs(Workspace:GetDescendants()) do zeroPrompt(d) end
        promptConn = PPS.PromptShown:Connect(function(p)
            if V.NoFWaitEnabled then zeroPrompt(p) end
        end)
    end
    local function disableNoFWait()
        if promptConn then promptConn:Disconnect(); promptConn = nil end
        for p, rec in pairs(promptAttrConn) do
            pcall(function() rec[1]:Disconnect() end)
            pcall(function() rec[2]:Disconnect() end)
            promptAttrConn[p] = nil
        end
        for _, d in ipairs(Workspace:GetDescendants()) do
            if d:IsA("ProximityPrompt") then
                local st = d:GetAttribute("BRM5_timer")
                if st ~= nil then pcall(function() d:SetAttribute("Timer", st) end) end
                local s = d:GetAttribute("BRM5_hold")
                if s ~= nil then pcall(function() d.HoldDuration = s end) end
                -- FIX v3: маркеры-атрибуты оставались на промптах навсегда
                pcall(function()
                    d:SetAttribute("BRM5_timer", nil)
                    d:SetAttribute("BRM5_hold", nil)
                end)
            end
        end
    end

    ---------------------------------------------------------------------------
    -- 8. LOCKPICK BYPASS
    --
    -- ФИКС ПРОСАДКИ FPS: раньше lockpickStep() дёргал findLockPick() (это
    -- filtergc — полный проход по GC) КАЖДЫЙ кадр, даже когда никакого замка
    -- рядом нет. Полный GC-скан 60 раз/сек = дикая просадка.
    --
    -- Теперь:
    --   1) СНАЧАЛА дешёвая проверка стейта актора — CurrentState.LockPick
    --      (по дампу LockPickController:new вызывает localActor:State("LockPick",
    --      true), а :State пишет в CurrentState[name]). Нет мини-игры → мгновенно
    --      выходим, БЕЗ единого GC-скана.
    --   2) Только когда мини-игра реально активна — ищем её экземпляр (и то не
    --      чаще LockpickScanInterval), кэшируем, шлём успех ОДИН раз.
    ---------------------------------------------------------------------------
    local lpLastScan = -999
    local function lockpickActive()
        local la = getLA()
        if type(la) ~= "table" then return false end
        -- FIX v4 [BUG#2]: труп держит CurrentState.LockPick, если игрок умер
        -- посреди мини-взлома. Гейт гонял filtergc каждые 0.4с ВЕСЬ экран
        -- смерти (хитчи), а если игра не выставила _cancelled прерванной
        -- мини-игре — уходил FireServer("ActivateInteract","Picked") от
        -- мёртвого игрока, то есть серверу видимый интеракт с того света.
        if rawget(la, "Alive") == false then return false end
        local cs = rawget(la, "CurrentState")
        return type(cs) == "table" and cs.LockPick and true or false
    end
    local function lockpickStep()
        if not V.LockpickBypassEnabled then return end
        -- дешёвый гейт: пока замок не открыт игрой — никаких GC-сканов
        if not lockpickActive() then return end
        local t = now()
        if t - lpLastScan < (V.LockpickScanInterval or 0.4) then return end
        lpLastScan = t
        local lp = findLockPick()          -- filtergc только во время активной мини-игры
        if not lp then return end
        local net = findNet()
        if net then
            pcall(function() lp._cancelled = true end)
            pcall(function() net:FireServer("ActivateInteract", "Picked") end)
        end
    end

    ---------------------------------------------------------------------------
    -- ГЛАВНЫЙ ЦИКЛ
    ---------------------------------------------------------------------------
    local hbConn  = nil
    -- ВАЖНО: `running` объявлен в самом верху модуля (рядом с vmHooked), а НЕ
    -- здесь. Хук viewmodel читает его на ~548 — если объяви��ь локал тут, внутри
    -- хука это будет глобал (=nil), и Viewmodel/GunModel молча перестанут
    -- работать. Ровно та же ловушка, что была с gunHighlight.

    -- FIX v3: раньше ВСЕ шаги шли в одном pcall с замыканием на кадр — первый
    -- же упавший шаг молча (log — no-op) вырубал все последующие до конца
    -- сессии: ошибка в vehicleStep убивала Ambient/Fullbright/NoFog/Lockpick.
    -- Теперь pcall на КАЖДЫЙ шаг + warn, затроттленный до 1/сек на шаг.
    local _stepWarnT = {}
    local runStep = LPH_NO_VIRTUALIZE(function(name, fn, dt)
        local ok, err = pcall(fn, dt)
        if not ok then
            local t = now()
            if t - (_stepWarnT[name] or -999) >= 1 then
                _stepWarnT[name] = t
                warn("[VIS] шаг", name, "упал:", err)
            end
        end
    end)
    local function vmHookStep()
        if V.ViewmodelEnabled or V.GunModelEnabled then ensureViewmodelHook() end
    end

    -- Главный per-frame Heartbeat. Под Luraph обязан быть нативным.
    local heartbeat = LPH_NO_VIRTUALIZE(function(dt)
        if not running then return end
        runStep("vmhook",   vmHookStep)
        runStep("tps",      thirdPersonStep)
        runStep("vehicle",  vehicleStep, dt)
        runStep("freegun",  freeGunStep)
        runStep("lighting", lightingStep)
        runStep("lockpick", lockpickStep)
    end)

    ---------------------------------------------------------------------------
    -- ХОТКЕИ
    ---------------------------------------------------------------------------
    local inputConn = nil
    -- FIX v3: MacLib сохраняет состояние ЭЛЕМЕНТОВ, а не CONFIG — хоткей,
    -- флипавший только V.*, давал рассинхрон: SaveConfig после Numpad-тоггла
    -- писал в конфиг ПРОТИВОПОЛОЖНОЕ значение. Синкаем элемент через
    -- K.syncToggle. Таблица: ключ конфига → Flag его UI-тоггла.
    local HOTKEY_UI_FLAGS = {
        ViewmodelEnabled      = "VM",
        GunModelEnabled       = "GM",
        ThirdPersonEnabled    = "TP",
        VehicleFlyEnabled     = "VehFly",
        VehicleSpeedEnabled   = "VehSpeed",
        FreeGunEnabled        = "FreeGun",
        AmbientEnabled        = "Ambient",
        NoFWaitEnabled        = "NoFWait",
        LockpickBypassEnabled = "Lockpick",
        FullbrightEnabled     = "Fullbright",
        NoFogEnabled          = "NoFog",
    }
    local _uiKitRef, _uiFlagFn = nil, nil   -- заполняет buildUI
    local function toggle(name, label)
        V[name] = not V[name]
        log(label, V[name] and "ВКЛ" or "выкл")
        local fl = HOTKEY_UI_FLAGS[name]
        if _uiKitRef and _uiFlagFn and fl then
            pcall(_uiKitRef.syncToggle, _uiFlagFn(fl), V[name])
        end
        return V[name]
    end

    local function onInput(input, gpe)
        if gpe then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        local kc = input.KeyCode
        if kc == V.ViewmodelKey then
            if not toggle("ViewmodelEnabled", "Viewmodel") then restoreViewmodelStyle() end
        elseif kc == V.GunModelKey then
            if not toggle("GunModelEnabled", "GunModel") then
                if gunHighlight then pcall(function() gunHighlight:Destroy() end); gunHighlight = nil end
            end
        elseif kc == V.ThirdPersonKey then
            if not toggle("ThirdPersonEnabled", "ThirdPersonSkin") then
                clearSelfHighlight(); restoreSelfBody()
            end
        elseif kc == V.VehicleFlyKey   then toggle("VehicleFlyEnabled",    "VehicleFly")
        elseif kc == V.VehicleSpeedKey then toggle("VehicleSpeedEnabled",   "VehicleSpeed")
        elseif kc == V.FreeGunKey then
            -- FIX v3: off-путь возвращает SeatCanEquip (раньше — только M.stop)
            if toggle("FreeGunEnabled", "FreeGun") then installFreeGunHook() else restoreFreeGunSeat() end
        elseif kc == V.AmbientKey then
            if not toggle("AmbientEnabled", "Ambient") then lightingOff() end
        elseif kc == V.NoFWaitKey then
            if toggle("NoFWaitEnabled", "NoFWait") then enableNoFWait() else disableNoFWait() end
        elseif kc == V.LockpickBypassKey then
            toggle("LockpickBypassEnabled", "LockpickBypass")
        elseif kc == V.FullbrightKey then
            if not toggle("FullbrightEnabled", "Fullbright") then lightingOff() end
        elseif kc == V.NoFogKey then
            if not toggle("NoFogEnabled", "NoFog") then lightingOff() end
        end
    end

    ---------------------------------------------------------------------------
    -- START / STOP
    ---------------------------------------------------------------------------
    local M = {}

    function M.start()
        if running then return end
        running = true
        hbConn = RunService.Heartbeat:Connect(heartbeat)
        -- FIX v3: при ре-инжекте прошлый бинд ещё жив → повторный BindToRenderStep
        -- с тем же именем падал ВНУТРИ pcall молча, и зомби-степ крутился на
        -- мёртвом конфиге. Снимаем защитно ДО бинда; неудачу бинда теперь warn-им.
        pcall(function() RunService:UnbindFromRenderStep(FOV_BIND) end)
        local bindOk, bindErr = pcall(function()
            RunService:BindToRenderStep(FOV_BIND,
                Enum.RenderPriority.Camera.Value + 1, fovStep)
            fovBound = true
        end)
        if not bindOk then warn("[VIS] FOV: BindToRenderStep не встал:", bindErr) end
        -- FIX v3: держит FOV не бинд (см. шапку — Flux перетирает его в своём
        -- RenderStepped), а перехват записи игры + пере-хук при смене камеры.
        hookFovSignal()
        _fovCamConn = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
            _origFov = nil
            hookFovSignal()
        end)
        inputConn = UIS.InputBegan:Connect(onInput)
        log("Visuals/World v3 запущен | Numpad1..0 = ту��блеры | CONFIG.Visuals для настройки")
    end

    function M.stop()
        running = false
        if hbConn    then hbConn:Disconnect();    hbConn    = nil end
        if inputConn then inputConn:Disconnect(); inputConn = nil end
        if fovBound  then
            pcall(function() RunService:UnbindFromRenderStep(FOV_BIND) end)
            fovBound = false
        end
        -- FIX v3: снимаем сигнал-хуки FOV ДО восстановления FieldOfView — иначе
        -- наша же запись-восстановление триггерит applyFov и вернёт кастомный FOV.
        if _fovConn    then _fovConn:Disconnect();    _fovConn    = nil end
        if _fovCamConn then _fovCamConn:Disconnect(); _fovCamConn = nil end
        -- Снимаем хук ДО restore — иначе живой хук вернёт стиль обратно
        -- на следующем же кадре (ровно так и было раньше).
        unhookViewmodel()
        restoreViewmodelStyle()
        restoreGunStyle()        -- FIX: не вызывался → оружие оставалось перекрашенным
        restoreVehicleSpeed()    -- FIX: не вызывался → тачка навсегда с изменённой массой
        if gunHighlight then pcall(function() gunHighlight:Destroy() end); gunHighlight = nil end
        clearSelfHighlight()
        restoreSelfBody()
        restoreFreeGunHook()     -- FIX: снимаем _canEquip и возвращаем SeatCanEquip
        disableNoFWait()
        lightingOff()
        -- FIX v3: раньше FieldOfView писался БЕЗУСЛОВНО (70), даже если фича ни
        -- разу не включалась — сбивали игровой/чужой FOV на выгрузке. Теперь
        -- только если мы реально его меняли (или успели захватить оригинал).
        if fovApplied or _origFov then
            pcall(function()
                local cam = Workspace.CurrentCamera
                -- FIX: было жёстко 70 — теперь возвращаем реально захваченный FOV
                if cam then cam.FieldOfView = _origFov or 70 end
            end)
            fovApplied = false
            _origFov = nil
        end
        log("Visuals/World остановлен")
    end

    -- ─────────────────────────────────────────────────────────────────────
    -- UI-интеграция (MacLib). Visuals-модуль раскидывает ко��тролы по табам:
    --   Visuals  → Viewmodel / GunModel / Gradient / ThirdPerson
    --   Movement → Vehicle (fly/speed) — это движение
    --   GunMods  → FreeGun — это изменение оружия
    --   Misc     → Fullbright / Ambient / NoFog / NoFWait
    -- Все колбэки пишут в V (= CONFIG.Visuals), heartbeat применяет каждый кадр.
    -- ─────────────────────────────────────────────────────────────────────
    -- Материалы для дропдаунов (строка ⇄ Enum.Material).
    local MATERIALS = { "ForceField", "Neon", "Glass", "SmoothPlastic", "Plastic", "Metal", "Marble" }
    local function matName(m) return (typeof(m) == "EnumItem") and m.Name or tostring(m or "ForceField") end
    local function matFromName(n) return Enum.Material[n] or Enum.Material.ForceField end

    function M.buildUI(ui)
        local tabV    = ui.tabs and ui.tabs.Visuals
        local tabMov  = ui.tabs and ui.tabs.Movement
        local tabGM   = ui.tabs and ui.tabs.GunMods
        local tabMisc = ui.tabs and ui.tabs.Misc
        local tabDbg  = ui.tabs and ui.tabs.Debug
        local K = Bridge.makeUiKit(ui)
        -- FIX v3: ТОТ ЖЕ флаг-хелпер, что внутри kit (library.makeUiKit): фолбэк
        -- обязан давать "BRM5_<имя>". Старый локальный `(ui.flag or tostring)`
        -- при отсутствии ui.flag выдавал "VehSpeed" вместо "BRM5_VehSpeed" —
        -- syncToggle бил мимо элемента.
        local uiFlag = ui.flag or function(s) return "BRM5_" .. tostring(s) end
        _uiKitRef, _uiFlagFn = K, uiFlag

        if tabV then
            -- ═══ Viewmodel ═════════════════════════════════════════════
            local S = tabV:Section({ Side = "Left" })
            -- Настройки видны ВСЕГДА, даже когда фича выключена: иначе панель
            -- выглядит пустой и непонятно, что она вообще умеет.
            K.feature(S, {
                Title = "Viewmodel", Flag = "VM",
                get = function() return V.ViewmodelEnabled end,
                set = function(v) V.ViewmodelEnabled = v end,
                Desc = "restyles ur first person arms",
            })
            K.toggle(S, { Name = "Recolor", Flag = "VMColorOn", Title = "VM Recolor",
                get = function() return V.ViewmodelColorEnabled end,
                set = function(v) V.ViewmodelColorEnabled = v end,
                after = invalidateVmStyle })
            K.color(S, { Name = "Color", Flag = "VMColor",
                Default = V.ViewmodelColor,
                Callback = function(c) V.ViewmodelColor = c; invalidateVmStyle() end })
            K.toggle(S, { Name = "Change Material", Flag = "VMMatOn",
                Title = "VM Material",
                get = function() return V.ViewmodelMaterialEnabled end,
                set = function(v) V.ViewmodelMaterialEnabled = v end,
                after = invalidateVmStyle })
            K.dropdown(S, { Name = "Material", Flag = "VMMat",
                Options = MATERIALS, Default = matName(V.ViewmodelMaterial),
                -- FIX: смена материала не применялась, пока не дёрнешь
                -- прозрачность — только она сбрасывала кэш стиля.
                Callback = function(n) V.ViewmodelMaterial = matFromName(n); invalidateVmStyle() end })
            K.slider(S, { Name = "Transparency", Flag = "VMTransp",
                Default = math.floor((V.ViewmodelTransparency or 0) * 100),
                Min = 0, Max = 100, Suffix = "%",
                Callback = function(v)
                    V.ViewmodelTransparency = v / 100
                    invalidateVmStyle()
                end })
            K.toggle(S, { Name = "Gradient", Flag = "VMGrad", Title = "VM Gradient",
                get = function() return V.ViewmodelGradientEnabled end,
                set = function(v) V.ViewmodelGradientEnabled = v end,
                after = invalidateVmStyle,
                Desc = "colors set in Gradient on the right" })

            K.group(S, "Placement")
            K.slider(S, { Name = "Hand Zoom", Flag = "VMDepth",
                Default = math.floor(V.ViewmodelDepth or 0) + 100, Min = 0, Max = 200,
                Callback = function(v) V.ViewmodelDepth = v - 100 end,
                Desc = "100 = stock. pulls the arms closer or pushes em away\nthis is NOT camera fov, that one lives in Misc" })
            -- FIX v3: ViewmodelOffset/ViewmodelTilt читались хуком, а контролов
            -- не было (шапка обещает «смещение рук»). Ось Z не дублируем — это
            -- уже Hand Zoom выше. Слайдеры целые → в конфиг идут сотые studs.
            local _vmo = (typeof(V.ViewmodelOffset) == "Vector3") and V.ViewmodelOffset or Vector3.zero
            K.slider(S, { Name = "Hand Right", Flag = "VMOffX",
                Default = math.floor(_vmo.X * 100) + 100, Min = 0, Max = 200,
                Callback = function(v)
                    local o = (typeof(V.ViewmodelOffset) == "Vector3") and V.ViewmodelOffset or Vector3.zero
                    V.ViewmodelOffset = Vector3.new((v - 100) / 100, o.Y, o.Z)
                end,
                Desc = "100 = stock. slides the arms sideways" })
            K.slider(S, { Name = "Hand Up", Flag = "VMOffY",
                Default = math.floor(_vmo.Y * 100) + 100, Min = 0, Max = 200,
                Callback = function(v)
                    local o = (typeof(V.ViewmodelOffset) == "Vector3") and V.ViewmodelOffset or Vector3.zero
                    V.ViewmodelOffset = Vector3.new(o.X, (v - 100) / 100, o.Z)
                end,
                Desc = "100 = stock. raises or drops em" })
            K.slider(S, { Name = "Hand Tilt", Flag = "VMTilt",
                Default = math.floor(V.ViewmodelTilt or 0) + 45, Min = 0, Max = 90, Suffix = "°",
                Callback = function(v) V.ViewmodelTilt = v - 45 end,
                Desc = "45 = stock. rolls the arms" })

            -- ═══ Gun Model ═════════════════════════════════════════════
            local G = tabV:Section({ Side = "Left" })
            K.feature(G, {
                Title = "Gun Model", Flag = "GM",
                get = function() return V.GunModelEnabled end,
                set = function(v) V.GunModelEnabled = v end,
                Desc = "same styling but for the gun in ur hands",
            })
            K.toggle(G, { Name = "Recolor", Flag = "GMColorOn", Title = "Gun Recolor",
                get = function() return V.GunModelColorEnabled end,
                set = function(v) V.GunModelColorEnabled = v end,
                after = invalidateGunStyle })
            K.color(G, { Name = "Color", Flag = "GMColor",
                Default = V.GunModelColor,
                Callback = function(c) V.GunModelColor = c; invalidateGunStyle() end })
            K.toggle(G, { Name = "Change Material", Flag = "GMMatOn",
                Title = "Gun Material",
                get = function() return V.GunModelMaterialEnabled end,
                set = function(v) V.GunModelMaterialEnabled = v end,
                after = invalidateGunStyle })
            K.dropdown(G, { Name = "Material", Flag = "GMMat",
                Options = MATERIALS, Default = matName(V.GunModelMaterial),
                Callback = function(n) V.GunModelMaterial = matFromName(n); invalidateGunStyle() end })
            K.slider(G, { Name = "Transparency", Flag = "GMTransp",
                Default = math.floor((V.GunModelTransparency or 0) * 100),
                Min = 0, Max = 100, Suffix = "%",
                Callback = function(v)
                    V.GunModelTransparency = v / 100
                    invalidateGunStyle()
                end })
            K.toggle(G, { Name = "Gradient", Flag = "GMGrad", Title = "Gun Gradient",
                get = function() return V.GunModelGradientEnabled end,
                set = function(v) V.GunModelGradientEnabled = v end,
                after = invalidateGunStyle,
                Desc = "wave runs part to part, see Wave Spread" })

            K.group(G, "Highlight")
            K.toggle(G, { Name = "Enabled", Flag = "GMHighlight",
                Title = "Gun Highlight",
                get = function() return V.GunModelHighlightEnabled ~= false end,
                set = function(v)
                    V.GunModelHighlightEnabled = v
                    if not v and gunHighlight then
                        pcall(function() gunHighlight:Destroy() end); gunHighlight = nil
                    end
                end,
                Desc = "glowing outline around the gun" })
            K.color(G, { Name = "Fill", Flag = "GMFill",
                Default = V.GunModelFill,
                Callback = function(c) V.GunModelFill = c end })
            K.color(G, { Name = "Outline", Flag = "GMOutline",
                Default = V.GunModelOutline,
                Callback = function(c) V.GunModelOutline = c end })
            K.slider(G, { Name = "Fill Transparency", Flag = "GMFillT",
                Default = math.floor((V.GunModelFillTransparency or 0.5) * 100),
                Min = 0, Max = 100, Suffix = "%",
                Callback = function(v) V.GunModelFillTransparency = v / 100 end })
            K.toggle(G, { Name = "Follow Gradient", Flag = "GMHlGrad",
                Title = "Highlight Gradient",
                get = function() return V.GunModelHighlightGradient ~= false end,
                set = function(v) V.GunModelHighlightGradient = v end,
                Desc = "outline rides the same wave as the gun\noff = keeps the fixed colors above" })

            -- ═══ Third Person ══════════════════════════════════════════
            local S2 = tabV:Section({ Side = "Right" })
            -- Честное имя: фича НЕ включает камеру от третьего лица (та живёт
            -- в модуле Movement). Она красит твою собственную модель, которую
            -- видно, когда камера уже отъехала.
            K.feature(S2, {
                Title = "Self Skin", Flag = "TP",
                get = function() return V.ThirdPersonEnabled end,
                set = function(v) V.ThirdPersonEnabled = v end,
                Desc = "recolors ur own body\nu see it in third person or spectate",
            })
            -- ═══════════════════════════════════════════════════════════════
            -- FIX v7 [SelfSkin: смена цвета не работает / highlight не меняется]
            --
            -- Было ДВЕ отдельные причины, и вместе они дают ровно тот симптом,
            -- который описал пользователь.
            --
            -- 1) applySelfHighlight читает КАЖДЫЙ кадр три ключа:
            --      V.ThirdPersonFill, V.ThirdPersonOutline,
            --      V.ThirdPersonFillTransparency
            --    — и НИ ОДНОГО из них не было в UI. Они навсегда оставались на
            --    дефолтах (120,200,255 / 180,235,255 / 0.55). Пользователь менял
            --    «Body Color», тело перекрашивалось, а highlight — нет. Отсюда
            --    «меняется цвет кожи, а highlight нет».
            --
            -- 2) styleSelfBody вызывается не каждый кадр, а при смене персонажа
            --    ИЛИ раз в 3 секунды (throttle _tpRestyeT). Поэтому даже цвет
            --    тела появлялся с задержкой до 3с и это выглядело как «смена
            --    цвета не работает» / «приходится перезапускать SelfSkin»
            --    (перезапуск менял tpStyledChar и форсил перекрас немедленно).
            --    Теперь колбэки форсят перекрас сами — применяется в тот же кадр.
            -- ═══════════════════════════════════════════════════════════════
            K.color(S2, { Name = "Body Color", Flag = "TPColor",
                Default = V.ThirdPersonBodyColor,
                Callback = function(c) V.ThirdPersonBodyColor = c; tpForceRestyle() end,
                Desc = "color of ur own body parts" })
            K.slider(S2, { Name = "Transparency", Flag = "TPTransp",
                Default = math.floor((V.ThirdPersonBodyTransparency or 0) * 100),
                Min = 0, Max = 100, Suffix = "%",
                Callback = function(v)
                    V.ThirdPersonBodyTransparency = v / 100
                    tpForceRestyle()
                end })
            K.dropdown(S2, { Name = "Material", Flag = "TPMat",
                Options = MATERIALS, Default = matName(V.ThirdPersonMaterial),
                Callback = function(n) V.ThirdPersonMaterial = matFromName(n); tpForceRestyle() end })

            -- Контролы highlight — раньше их не существовало вовсе,
            -- хотя код читал эти ключи каждый кадр.
            K.group(S2, "Highlight")
            K.color(S2, { Name = "Highlight Fill", Flag = "TPFill",
                Default = V.ThirdPersonFill,
                Callback = function(c) V.ThirdPersonFill = c end,
                Desc = "silhouette fill — applies instantly" })
            K.color(S2, { Name = "Highlight Outline", Flag = "TPOutline",
                Default = V.ThirdPersonOutline,
                Callback = function(c) V.ThirdPersonOutline = c end })
            K.slider(S2, { Name = "Highlight Opacity", Flag = "TPFillTransp",
                Default = math.floor((1 - (V.ThirdPersonFillTransparency or 0.55)) * 100),
                Min = 0, Max = 100, Suffix = "%",
                Callback = function(v)
                    -- в UI — «плотность», в Roblox Highlight — прозрачность
                    V.ThirdPersonFillTransparency = 1 - (v / 100)
                end,
                Desc = "0% = outline only" })
            K.toggle(S2, { Name = "Gradient", Flag = "TPGrad", Title = "TP Gradient",
                get = function() return V.ThirdPersonGradientEnabled end,
                set = function(v) V.ThirdPersonGradientEnabled = v end })

            -- ═══ Общие цвета градиента ═════════════════════════════════
            local GC = tabV:Section({ Side = "Right" })
            GC:Header({ Name = "Gradient" })
            GC:SubLabel({ Text = "blends A into B n back, its not a rainbow" })
            K.color(GC, { Name = "Color A", Flag = "GradA", Default = V.GradientColorA,
                Callback = function(c) V.GradientColorA = c end })
            K.color(GC, { Name = "Color B", Flag = "GradB", Default = V.GradientColorB,
                Callback = function(c) V.GradientColorB = c end })
            K.slider(GC, { Name = "Speed", Flag = "GradSpeed",
                Default = math.floor((V.GradientSpeed or 0.5) * 100),
                Min = 5, Max = 200, Suffix = "%",
                Callback = function(v) V.GradientSpeed = v / 100 end })
            K.slider(GC, { Name = "Wave Spread", Flag = "GradSpread",
                Default = math.floor((V.GunModelGradientSpread or 1.6) * 10),
                Min = 0, Max = 50,
                Callback = function(v)
                    V.GunModelGradientSpread = v / 10
                    -- сбрасываем фазы частей, иначе волна не пересчитается
                    for _, rec in pairs(gunStyledParts) do rec.gp = nil end
                end,
                Desc = "0 = whole gun changes color at once" })
        end

        -- ═══ TAB: Movement ═════════════════════════════════════════════
        if tabMov then
            -- Транспорт — правая колонка. Модуль Movement теперь раскладывает
            -- свои фичи по обеим сторонам (перемещение слева, камера/десинк
            -- справа), так что vehicle встаёт третьим блоком справа и колонки
            -- остаются сбалансированными.
            local S = tabMov:Section({ Side = "Right" })
            K.feature(S, {
                Title = "Vehicle Fly", Flag = "VehFly",
                get = function() return V.VehicleFlyEnabled end,
                set = function(v) V.VehicleFlyEnabled = v end,
                Desc = "flies whatever ur driving",
            })
            K.slider(S, { Name = "Fly Speed", Flag = "VehFlySpeed",
                Default = V.VehicleFlySpeed, Min = 20, Max = 400, Suffix = " st/s",
                Callback = function(v) V.VehicleFlySpeed = v end })

            K.group(S, "Vehicle Speed")
            K.toggle(S, { Name = "Enabled", Flag = "VehSpeed", Title = "Vehicle Speed",
                get = function() return V.VehicleSpeedEnabled end,
                set = function(v) V.VehicleSpeedEnabled = v end })
            if ui.keybind then
                -- FIX v3: флаги через uiFlag (фолбэк kit'а), а не `or tostring`
                ui.keybind(S, { Name = "Keybind", Flag = uiFlag("VehSpeed_KB"),
                    Toggle = function()
                        V.VehicleSpeedEnabled = not V.VehicleSpeedEnabled
                        K.syncToggle(uiFlag("VehSpeed"), V.VehicleSpeedEnabled)
                        K.notify("Vehicle Speed", V.VehicleSpeedEnabled and "Enabled" or "Disabled")
                    end })
            end
            K.slider(S, { Name = "Multiplier", Flag = "VehSpeedMult",
                Default = math.floor((V.VehicleSpeedMult or 1) * 10), Min = 10, Max = 60,
                Callback = function(v) V.VehicleSpeedMult = v / 10 end,
                Desc = "10 = stock, 60 = 6x" })
        end

        -- ═══ TAB: Gun Mods ═════════════════════════════════════════════
        if tabGM then
            local S = tabGM:Section({ Side = "Left" })
            K.feature(S, {
                Title = "Free Gun", Flag = "FreeGun",
                get = function() return V.FreeGunEnabled end,
                -- FIX v3: off-путь возвращает la.SeatCanEquip — раньше поле
                -- игры оставалось пропатченным до самого unload (M.stop).
                set = function(v)
                    V.FreeGunEnabled = v
                    if not v then restoreFreeGunSeat() end
                end,
                Desc = "lets u draw a weapon where the game blocks it\nlike inside a vehicle",
            })
        end

        -- ═══ TAB: Misc ═════════════════════════════════════════════════
        if tabMisc then
            local SL = tabMisc:Section({ Side = "Left" })
            -- FIX v3: у всех трёх лайтинг-тогглов (Fullbright/NoFog/Atmosphere)
            -- off-путь был только у ХОТКЕЕВ — выкл из меню оставлял мир
            -- перекрашенным навсегда. Теперь тот же lightingOff(), что у хоткеев.
            K.feature(SL, {
                Title = "Fullbright", Flag = "Fullbright",
                get = function() return V.FullbrightEnabled end,
                set = function(v)
                    V.FullbrightEnabled = v
                    if not v then lightingOff() end
                end,
                Desc = "flat max light, no shadows anywhere\nfor mood lighting use Atmosphere instead",
            })

            K.group(SL, "No Fog")
            K.toggle(SL, { Name = "Enabled", Flag = "NoFog", Title = "No Fog",
                get = function() return V.NoFogEnabled end,
                set = function(v)
                    V.NoFogEnabled = v
                    if not v then lightingOff() end
                end,
                Desc = "strips fog entirely — see the whole map" })

            K.group(SL, "Camera FOV")
            K.toggle(SL, { Name = "Enabled", Flag = "WorldFOVOn", Title = "Camera FOV",
                get = function() return V.WorldFOVEnabled end,
                set = function(v) V.WorldFOVEnabled = v end,
                Desc = "real field of view — wider = see more but aim feels faster" })
            K.slider(SL, { Name = "FOV", Flag = "WorldFOV",
                Default = V.WorldFOV or 70, Min = 40, Max = 120, Suffix = "°",
                Callback = function(v) V.WorldFOV = v end,
                Desc = "70 = game default" })

            -- ═══ Atmosphere: свой вайб ═════════════════════════════════
            local SA = tabMisc:Section({ Side = "Left" })
            K.feature(SA, {
                Title = "Atmosphere", Flag = "Ambient",
                get = function() return V.AmbientEnabled end,
                set = function(v)
                    V.AmbientEnabled = v
                    if not v then lightingOff() end
                end,
                Desc = "ur own time of day n mood\noverrides whatever the map sets",
            })
            -- ═══════════════════════════════════════════════════════════════
            -- FIX v4 [BUG#4 + BUG#5] Atmosphere: переделка контролов.
            --
            -- BUG#4 (цвета не совпадали с UI): manual() менял ТОЛЬКО
            --   V.AmbientPreset, а сам элемент дропдауна оставался на прошлом
            --   выборе ("Sunset"). MacLib сохраняет ЭЛЕМЕНТЫ, а не CONFIG —
            --   значит SaveConfig писал пресет рядом с кастомными цветами, а на
            --   LoadConfig MacLib дёргал колбэк дропдауна, тот звал
            --   applyAmbientPreset и затирал все пять цветов + ambRefresh
            --   пропихивал цвета пресета в сами пикеры. Кастом пользователя
            --   исчезал и из конфига, и из UI. Теперь manual() синхронизирует
            --   элемент, а колбэк дропдауна защищён от собственного эха.
            --   Заодно снят форс V.AmbientEnabled=true при загрузке пресета —
            --   он включал фичу даже если её сохранили выключенной.
            --
            -- BUG#5 (неудобная настройка): три слайдера жили в offset-кодировке
            --   и показывали не то, что значат — Brightness ×10 (юзер видит
            --   «20» = 2.0), Exposure +200 (видит «200» = 0), Sun Angle +90
            --   (видит «135» = 45). Теперь у всех РЕАЛЬНЫЕ значения с
            --   Precision/Prefix, порядок — от частого к редкому, добавлены
            --   Reset и понятные подписи.
            --   ВНИМАНИЕ: у трёх слайдеров сменилась шкала, поэтому сменены и
            --   флаги (AmbBright→AmbBright2, AmbExposure→AmbExp2,
            --   AmbLat→AmbSunAngle) — иначе старое сохранённое «20» приехало бы
            --   как яркость 20 (ослепляющая). Эти три значения сбросятся один
            --   раз, как было при Distance→KADistance в killaura v14.
            -- ═══════════════════════════════════════════════════════════════
            local ambRefresh
            local _ambSync = false
            local elPreset

            elPreset = K.dropdown(SA, { Name = "Preset", Flag = "AmbPreset",
                Options = AMBIENT_PRESET_ORDER,
                Default = V.AmbientPreset or "Custom",
                Callback = function(v)
                    if _ambSync then return end   -- эхо своего же UpdateSelection
                    if v ~= "Custom" and applyAmbientPreset(v) then
                        if ambRefresh then ambRefresh() end
                    else
                        V.AmbientPreset = "Custom"
                    end
                end,
                Desc = "ready-made vibes\ntweak anything below n it flips to Custom" })

            -- Любое ручное изменение сбрасывает пресет в Custom.
            -- FIX v3: _ambSync — ambRefresh дёргает UpdateState/UpdateValue, а
            -- MacLib синхронно эхает колбэки; без гейта только что выбранный
            -- пресет тут же слетал бы в Custom.
            -- FIX v4: синкаем и сам элемент дропдауна (см. блок выше).
            local function manual()
                if _ambSync then return end
                if V.AmbientPreset == "Custom" then return end
                V.AmbientPreset = "Custom"
                if elPreset then
                    _ambSync = true
                    pcall(function() elPreset:UpdateSelection("Custom") end)
                    _ambSync = false
                end
            end

            -- ── Основное: то, что крутят чаще всего ──────────────────────
            local elTime = K.slider(SA, { Name = "Time of Day", Flag = "ClockTime",
                Default = V.AmbientClockTime or 12, Min = 0, Max = 24,
                Precision = 1, Suffix = "h",
                Callback = function(v) V.AmbientClockTime = v; manual() end,
                Desc = "0 = midnight · 6 = dawn · 12 = noon · 18 = sunset" })
            local elBright = K.slider(SA, { Name = "Brightness", Flag = "AmbBright2",
                Default = V.AmbientBrightness or 2, Min = 0, Max = 6,
                Precision = 1,
                Callback = function(v) V.AmbientBrightness = v; manual() end,
                Desc = "2 = game default · 4+ = washed out" })
            local elExp = K.slider(SA, { Name = "Exposure", Flag = "AmbExp2",
                Default = V.AmbientExposure or 0, Min = -2, Max = 2,
                Precision = 2,
                Callback = function(v) V.AmbientExposure = v; manual() end,
                Desc = "0 = neutral · minus = darker · plus = blown out" })

            -- ── Цвета ────────────────────────────────────────────────────
            K.group(SA, "Colors")
            local elAmb = K.color(SA, { Name = "Shadow Tint", Flag = "AmbColor",
                Default = V.AmbientColor,
                Callback = function(c) V.AmbientColor = c; manual() end,
                Desc = "color of everything in shade — the main mood dial" })
            local elOut = K.color(SA, { Name = "Outdoor Tint", Flag = "AmbOutColor",
                Default = V.AmbientOutdoorColor,
                Callback = function(c) V.AmbientOutdoorColor = c; manual() end,
                Desc = "color of open-sky lighting" })
            local elTintT = K.color(SA, { Name = "Highlight Tint", Flag = "AmbTintTop",
                Default = V.AmbientTintTop,
                Callback = function(c) V.AmbientTintTop = c; manual() end,
                Desc = "tints lit surfaces — keep it subtle, black = off" })
            local elTintB = K.color(SA, { Name = "Shade Tint", Flag = "AmbTintBottom",
                Default = V.AmbientTintBottom,
                Callback = function(c) V.AmbientTintBottom = c; manual() end,
                Desc = "tints unlit surfaces, black = off" })

            -- ── Тонкая настройка ─────────────────────────────────────────
            K.group(SA, "Sun & Shadows")
            local elLat = K.slider(SA, { Name = "Sun Angle", Flag = "AmbSunAngle",
                Default = V.AmbientLatitude or 45, Min = -90, Max = 90,
                Precision = 0, Suffix = "°",
                Callback = function(v) V.AmbientLatitude = v; manual() end,
                Desc = "where the sun sits · 0 = overhead track" })
            -- FIX v3: manual() — раньше правка Shadows/Custom Fog не переводила
            -- пресет в Custom, в отличие от всех остальных контролов атмосферы.
            local elShadows = K.toggle(SA, { Name = "Shadows", Flag = "AmbShadows", Title = "Shadows",
                get = function() return V.AmbientShadows ~= false end,
                set = function(v) V.AmbientShadows = v; manual() end,
                Desc = "off = flat lighting, slightly better fps" })

            K.group(SA, "Fog")
            local elFogOn = K.toggle(SA, { Name = "Custom Fog", Flag = "AmbFogOn", Title = "Custom Fog",
                get = function() return V.AmbientFogEnabled end,
                set = function(v) V.AmbientFogEnabled = v; manual() end,
                Desc = "haze n distance mood\nuse No Fog instead if u just want it gone" })
            local elFogCol = K.color(SA, { Name = "Fog Color", Flag = "AmbFogColor",
                Default = V.AmbientFogColor,
                Callback = function(c) V.AmbientFogColor = c; manual() end })
            local elFogStart = K.slider(SA, { Name = "Fog Start", Flag = "AmbFogStart",
                Default = V.AmbientFogStart or 0, Min = 0, Max = 2000, Suffix = " st",
                Callback = function(v) V.AmbientFogStart = v; manual() end,
                Desc = "distance where fog begins" })
            local elFogEnd = K.slider(SA, { Name = "Fog End", Flag = "AmbFogEnd",
                Default = V.AmbientFogEnd or 800, Min = 50, Max = 5000, Suffix = " st",
                Callback = function(v) V.AmbientFogEnd = v; manual() end,
                Desc = "distance where fog is solid" })

            -- Пресет меняет V.*, но ползунки/пикеры об этом не знают —
            -- синхронизируем их отображение, иначе они показывают старые числа.
            ambRefresh = function()
                _ambSync = true   -- FIX v3: эхо UpdateState не должно звать manual()
                local function setV(el, val)
                    if el and val then pcall(function() el:UpdateValue(val, true) end) end
                end
                local function setC(el, col)
                    if el and col then pcall(function() el:SetColor(col) end) end
                end
                -- FIX v4: реальные значения, без ×10 / +200 / +90
                setV(elTime,     V.AmbientClockTime or 12)
                setV(elBright,   V.AmbientBrightness or 2)
                setV(elExp,      V.AmbientExposure or 0)
                setV(elLat,      V.AmbientLatitude or 45)
                setV(elFogStart, V.AmbientFogStart or 0)
                setV(elFogEnd,   V.AmbientFogEnd or 800)
                setC(elAmb,      V.AmbientColor)
                setC(elOut,      V.AmbientOutdoorColor)
                setC(elTintT,    V.AmbientTintTop)
                setC(elTintB,    V.AmbientTintBottom)
                setC(elFogCol,   V.AmbientFogColor)
                if elShadows then pcall(function() elShadows:UpdateState(V.AmbientShadows ~= false) end) end
                if elFogOn   then pcall(function() elFogOn:UpdateState(V.AmbientFogEnabled == true) end) end
                -- дропдаун тоже: applyAmbientPreset выставил V.AmbientPreset
                if elPreset and V.AmbientPreset then
                    pcall(function() elPreset:UpdateSelection(V.AmbientPreset) end)
                end
                _ambSync = false
            end

            -- FIX v4 [BUG#5]: возврат к пресету. Раньше «уехавшую» атмосферу
            -- нельзя было откатить иначе как переключением пресета туда-обратно
            -- (а из Custom и этого не сделать — Custom не применяет ничего).
            K.button(SA, { Name = "Reset Atmosphere", Title = "Atmosphere",
                Callback = function()
                    applyAmbientPreset("Clear")
                    ambRefresh()
                    return "reset to Clear"
                end })

            local SIN = tabMisc:Section({ Side = "Right" })
            SIN:Header({ Name = "Interactions" })
            -- FIX v3: сеттер лишь ставил флаг, а оба читателя живут в коннектах,
            -- которые создаёт enableNoFWait() — её звал ТОЛЬКО хоткей Num7.
            -- Из меню фича была полностью мёртвой.
            K.toggle(SIN, { Name = "No Prompt Hold", Flag = "NoFWait", Title = "No Prompt Hold",
                get = function() return V.NoFWaitEnabled end,
                set = function(v)
                    V.NoFWaitEnabled = v
                    if v then enableNoFWait() else disableNoFWait() end
                end,
                Desc = "prompts fire instantly instead of holding F" })
            K.toggle(SIN, { Name = "Lockpick Bypass", Flag = "Lockpick", Title = "Lockpick Bypass",
                get = function() return V.LockpickBypassEnabled end,
                set = function(v) V.LockpickBypassEnabled = v end,
                Desc = "solves the lockpick minigame for u" })
        end

        -- ═══ DEBUG ═════════════════════════════════════════════════════
        if tabDbg then
            local D = tabDbg:Section({ Side = "Left" })
            D:Header({ Name = "Visuals" })
            K.slider(D, { Name = "Lockpick Scan", Flag = "DbgLockpick",
                Default = math.floor((V.LockpickScanInterval or 0.4) * 1000),
                Min = 100, Max = 2000, Suffix = " ms",
                Callback = function(v) V.LockpickScanInterval = v / 1000 end })
            K.slider(D, { Name = "Restyle Period", Flag = "DbgVmRestyle",
                Default = math.floor((V.VmRestyleSec or 3) * 1000),
                Min = 500, Max = 10000, Suffix = " ms",
                Callback = function(v) V.VmRestyleSec = v / 1000 end,
                Desc = "how often late arm/gun parts get repainted" })
        end

        K.ready()
    end

    -- FIX v4 [C1]: guard от повторной инжекции — прошлый инстанс держал свои
    -- Heartbeat/FOV-коннекты/хуки Viewmodel и перекрашивал мир параллельно.
    do
        local g = (type(getgenv) == "function" and getgenv()) or _G
        local prev = g.BRM5_VIS_MODULE
        if type(prev) == "table" and type(prev.stop) == "function" and prev ~= M then
            pcall(prev.stop)
        end
        g.BRM5_VIS_MODULE = M
    end
    if Bridge.registerModule then Bridge.registerModule("visuals", M) end

    return M
end
