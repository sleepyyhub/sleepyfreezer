--[[
    Clovyre MCP - Roblox client bridge
    ---------------------------------
    Connects a live Roblox client to a Clovyre session over a secure WebSocket and
    answers inspection commands issued by a remote MCP agent.

    Scope: this script can only see what is replicated to THIS client. Server
    Scripts, ServerStorage, ServerScriptService and server memory are not
    reachable from here and never will be.

    Configuration is read from getgenv().ClovyreConfig:
        BaseUrl     - https origin of the Clovyre deployment
        SessionId   - public session id
        RobloxToken - session-specific Roblox credential

    Running this script twice cleans up the previous connection instead of
    creating a duplicate. getgenv().ClovyreDisconnect() tears it down.
]]

local BRIDGE_VERSION = '0.1.0'
local PROTOCOL_VERSION = 1

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local genv = (typeof(getgenv) == 'function') and getgenv() or _G
local config = genv.ClovyreConfig

if type(config) ~= 'table' then
    error('[Clovyre] getgenv().ClovyreConfig is missing. Copy the full loadstring from the Clovyre dashboard.', 0)
end
if type(config.BaseUrl) ~= 'string' or config.BaseUrl == '' then
    error('[Clovyre] ClovyreConfig.BaseUrl is missing.', 0)
end
if type(config.SessionId) ~= 'string' or config.SessionId == '' then
    error('[Clovyre] ClovyreConfig.SessionId is missing.', 0)
end
if type(config.RobloxToken) ~= 'string' or config.RobloxToken == '' then
    error('[Clovyre] ClovyreConfig.RobloxToken is missing.', 0)
end

local BASE_URL = string.gsub(config.BaseUrl, '/+$', '')
local WS_URL = (string.gsub(BASE_URL, '^http', 'ws')) .. '/ws/roblox'

--------------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------------

local HttpService = game:GetService('HttpService')
local Players = game:GetService('Players')
local RunService = game:GetService('RunService')
local CollectionService = game:GetService('CollectionService')
local Workspace = game:GetService('Workspace')

--- Optional services. A stripped or unusual client may not expose all of them,
--- so each is resolved defensively and the handlers that need one say so plainly
--- rather than erroring.
local function optionalService(name)
    local ok, service = pcall(function() return game:GetService(name) end)
    return ok and service or nil
end

local Lighting = optionalService('Lighting')
local SoundService = optionalService('SoundService')
local Teams = optionalService('Teams')
local Stats = optionalService('Stats')

--------------------------------------------------------------------------------
-- Limits
--------------------------------------------------------------------------------

local LIMITS = {
    maxDepth = 8,
    maxItems = 200,
    maxStringLength = 8192,
    maxNodes = 4000,
    maxPayloadBytes = 400 * 1024,
    maxSourceBytes = 200 * 1024,
    maxLogLines = 400,
    -- Ceiling on instances visited by a search, so a scan of a large game cannot
    -- stall the client's frame for an unbounded time.
    maxScanNodes = 20000,
}

--------------------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------------------

local logBuffer = {}

local function pushLog(level, message)
    table.insert(logBuffer, { level = level, message = tostring(message), at = os.time() })
    if #logBuffer > LIMITS.maxLogLines then
        table.remove(logBuffer, 1)
    end
end

--- Whether the bridge may write to the executor console.
--- Off until the server says otherwise: the console belongs to the user, and a
--- tool bridge printing into it unasked is noise in their own output window.
--- Every line is still recorded in the ring buffer above and readable through
--- clovyre_get_logs, so turning printing off loses no diagnostics.
local consoleOutput = false

local function setConsoleOutput(enabled)
    consoleOutput = enabled == true
end

local function info(message)
    pushLog('info', message)
    if consoleOutput then
        print('[Clovyre] ' .. tostring(message))
    end
end

local function warnLog(message)
    pushLog('warn', message)
    if consoleOutput then
        warn('[Clovyre] ' .. tostring(message))
    end
end

--------------------------------------------------------------------------------
-- Executor compatibility adapter
--------------------------------------------------------------------------------

--- Resolves a global by name without erroring on strict environments.
local function globalFn(name)
    local ok, value = pcall(function()
        return genv[name] ~= nil and genv[name] or rawget(_G, name)
    end)
    if ok and type(value) == 'function' then
        return value
    end
    local ok2, value2 = pcall(function()
        return (getfenv and getfenv(1) or _G)[name]
    end)
    if ok2 and type(value2) == 'function' then
        return value2
    end
    return nil
end

local function nestedFn(rootName, childName)
    local root = rawget(_G, rootName)
    if root == nil then
        local ok, value = pcall(function()
            return genv[rootName]
        end)
        root = ok and value or nil
    end
    if type(root) ~= 'table' then
        return nil
    end
    local ok, value = pcall(function()
        return root[childName]
    end)
    if ok and type(value) == 'function' then
        return value
    end
    return nil
end

--- Finds the executor's WebSocket connect function across known naming schemes.
local function resolveWebSocketConnect()
    local candidates = {
        function() return nestedFn('WebSocket', 'connect') end,
        function() return nestedFn('websocket', 'connect') end,
        function() return nestedFn('WebSocket', 'Connect') end,
        function()
            local syn = rawget(_G, 'syn')
            if type(syn) == 'table' and type(syn.websocket) == 'table' then
                return syn.websocket.connect
            end
            return nil
        end,
    }
    for _, candidate in ipairs(candidates) do
        local ok, fn = pcall(candidate)
        if ok and type(fn) == 'function' then
            return fn
        end
    end
    return nil
end

local wsConnect = resolveWebSocketConnect()

local API = {
    decompile = globalFn('decompile'),
    getscriptbytecode = globalFn('getscriptbytecode') or globalFn('dumpstring'),
    getloadedmodules = globalFn('getloadedmodules'),
    getconnections = globalFn('getconnections'),
    getgc = globalFn('getgc'),
    getsenv = globalFn('getsenv'),
    identifyexecutor = globalFn('identifyexecutor') or globalFn('getexecutorname'),
    getcustomasset = globalFn('getcustomasset'),
    setclipboard = globalFn('setclipboard') or globalFn('toclipboard'),
    gethui = globalFn('gethui'),
    -- Executors split between the Lua 5.1 name and the 5.2+ one; either compiles
    -- a chunk, so accept whichever this one provides.
    loadstring = (type(loadstring) == 'function') and loadstring
        or globalFn('loadstring')
        or ((type(load) == 'function') and load or globalFn('load')),
    hookmetamethod = globalFn('hookmetamethod'),
    getnamecallmethod = globalFn('getnamecallmethod'),
    checkcaller = globalFn('checkcaller'),
    getcallingscript = globalFn('getcallingscript'),
}

local function buildCapabilities()
    return {
        websocket = wsConnect ~= nil,
        decompile = API.decompile ~= nil,
        getscriptbytecode = API.getscriptbytecode ~= nil,
        getloadedmodules = API.getloadedmodules ~= nil,
        getconnections = API.getconnections ~= nil,
        getgc = API.getgc ~= nil,
        getsenv = API.getsenv ~= nil,
        getgenv = typeof(getgenv) == 'function',
        identifyexecutor = API.identifyexecutor ~= nil,
        getcustomasset = API.getcustomasset ~= nil,
        loadstring = API.loadstring ~= nil,
        setclipboard = API.setclipboard ~= nil,
        gethui = API.gethui ~= nil,
        hookmetamethod = API.hookmetamethod ~= nil and API.getnamecallmethod ~= nil,
        getnamecallmethod = API.getnamecallmethod ~= nil,
    }
end

if wsConnect == nil then
    error(
        '[Clovyre] This executor does not expose a WebSocket connect function ' ..
        '(tried WebSocket.connect, websocket.connect and syn.websocket.connect). ' ..
        'Clovyre cannot run here.',
        0
    )
end

--------------------------------------------------------------------------------
-- Instance reference registry
--------------------------------------------------------------------------------

local refs = {}          -- ref string -> Instance
local refsByInstance = {} -- Instance -> ref string
local refCounter = 0

setmetatable(refsByInstance, { __mode = 'k' })

local function refFor(instance)
    if typeof(instance) ~= 'Instance' then
        return nil
    end
    local existing = refsByInstance[instance]
    if existing then
        return existing
    end
    refCounter = refCounter + 1
    local ref = 'ref_' .. tostring(refCounter)
    refs[ref] = instance
    refsByInstance[instance] = ref
    return ref
end

local function instanceForRef(ref)
    local instance = refs[ref]
    if instance == nil then
        return nil
    end
    -- A streamed-out or destroyed instance loses its ancestry; treat it as gone.
    local ok, parent = pcall(function()
        return instance.Parent
    end)
    if not ok then
        refs[ref] = nil
        return nil
    end
    if parent == nil and instance ~= game then
        return nil
    end
    return instance
end

--------------------------------------------------------------------------------
-- Paths
--------------------------------------------------------------------------------

local function escapeSegment(name)
    name = string.gsub(name, '\\', '\\\\')
    return (string.gsub(name, '%.', '\\.'))
end

--- Structured path from the DataModel root, plus a display rendering.
local function pathOf(instance)
    local segments = {}
    local display = {}
    local current = instance
    local guard = 0

    while current ~= nil and current ~= game and guard < 64 do
        guard = guard + 1
        local okName, name = pcall(function() return current.Name end)
        local okClass, className = pcall(function() return current.ClassName end)
        table.insert(segments, 1, {
            name = okName and name or '?',
            className = okClass and className or '?',
        })
        table.insert(display, 1, escapeSegment(okName and name or '?'))
        local okParent, parent = pcall(function() return current.Parent end)
        if not okParent then
            break
        end
        current = parent
    end

    return { segments = segments }, table.concat(display, '.')
end

--- Resolves { ref = ... } or { path = { segments = {...} } } to an Instance.
local function resolveTarget(target)
    if type(target) ~= 'table' then
        return nil, 'A target is required.'
    end

    if type(target.ref) == 'string' then
        local instance = instanceForRef(target.ref)
        if instance == nil then
            return nil, 'That instance reference is no longer valid (destroyed, streamed out, or from an older session).'
        end
        return instance
    end

    local path = target.path
    if type(path) ~= 'table' or type(path.segments) ~= 'table' then
        return nil, 'A structured path or ref is required.'
    end

    local current = game
    for _, segment in ipairs(path.segments) do
        if type(segment) ~= 'table' or type(segment.name) ~= 'string' then
            return nil, 'Malformed path segment.'
        end
        local found = nil
        -- Services must be resolved through GetService, not FindFirstChild.
        if current == game then
            local ok, service = pcall(function()
                return game:GetService(segment.name)
            end)
            if ok and service then
                found = service
            end
        end
        if found == nil then
            local ok, child = pcall(function()
                return current:FindFirstChild(segment.name)
            end)
            found = ok and child or nil
        end
        if found == nil then
            return nil, 'No instance named "' .. segment.name .. '" under the requested parent.'
        end
        current = found
    end

    return current
end

--------------------------------------------------------------------------------
-- Serializer
--------------------------------------------------------------------------------

local serialize

local function truncateString(text)
    if #text <= LIMITS.maxStringLength then
        return text
    end
    return string.sub(text, 1, LIMITS.maxStringLength)
        .. '…[truncated ' .. tostring(#text - LIMITS.maxStringLength) .. ' chars]'
end

local function serializeInstance(value)
    local _, display = pathOf(value)
    local okClass, className = pcall(function() return value.ClassName end)
    local okName, name = pcall(function() return value.Name end)
    return {
        __t = 'Instance',
        ref = refFor(value),
        name = okName and name or '?',
        className = okClass and className or '?',
        displayPath = display,
    }
end

local serializers = {
    Vector2 = function(v) return { __t = 'Vector2', x = v.X, y = v.Y } end,
    Vector3 = function(v) return { __t = 'Vector3', x = v.X, y = v.Y, z = v.Z } end,
    CFrame = function(v)
        return {
            __t = 'CFrame',
            position = { v.Position.X, v.Position.Y, v.Position.Z },
            components = { v:GetComponents() },
        }
    end,
    Color3 = function(v)
        return {
            __t = 'Color3',
            r = v.R, g = v.G, b = v.B,
            hex = string.format('#%02X%02X%02X',
                math.floor(v.R * 255 + 0.5),
                math.floor(v.G * 255 + 0.5),
                math.floor(v.B * 255 + 0.5)),
        }
    end,
    BrickColor = function(v)
        return { __t = 'BrickColor', name = v.Name, number = v.Number }
    end,
    UDim = function(v) return { __t = 'UDim', scale = v.Scale, offset = v.Offset } end,
    UDim2 = function(v)
        return {
            __t = 'UDim2',
            xScale = v.X.Scale, xOffset = v.X.Offset,
            yScale = v.Y.Scale, yOffset = v.Y.Offset,
        }
    end,
    Rect = function(v)
        return { __t = 'Rect', minX = v.Min.X, minY = v.Min.Y, maxX = v.Max.X, maxY = v.Max.Y }
    end,
    NumberRange = function(v) return { __t = 'NumberRange', min = v.Min, max = v.Max } end,
    NumberSequence = function(v)
        local keypoints = {}
        for index, keypoint in ipairs(v.Keypoints) do
            if index > 32 then break end
            table.insert(keypoints, { time = keypoint.Time, value = keypoint.Value, envelope = keypoint.Envelope })
        end
        return { __t = 'NumberSequence', keypoints = keypoints }
    end,
    ColorSequence = function(v)
        local keypoints = {}
        for index, keypoint in ipairs(v.Keypoints) do
            if index > 32 then break end
            table.insert(keypoints, {
                time = keypoint.Time,
                value = { keypoint.Value.R, keypoint.Value.G, keypoint.Value.B },
            })
        end
        return { __t = 'ColorSequence', keypoints = keypoints }
    end,
    Enum = function(v) return { __t = 'Enum', name = tostring(v) } end,
    EnumItem = function(v)
        return { __t = 'EnumItem', enumType = tostring(v.EnumType), name = v.Name, value = v.Value }
    end,
    Ray = function(v)
        return {
            __t = 'Ray',
            origin = { v.Origin.X, v.Origin.Y, v.Origin.Z },
            direction = { v.Direction.X, v.Direction.Y, v.Direction.Z },
        }
    end,
    Region3 = function(v)
        local min = v.CFrame.Position - v.Size / 2
        local max = v.CFrame.Position + v.Size / 2
        return { __t = 'Region3', min = { min.X, min.Y, min.Z }, max = { max.X, max.Y, max.Z } }
    end,
    TweenInfo = function(v)
        return {
            __t = 'TweenInfo',
            time = v.Time,
            easingStyle = tostring(v.EasingStyle),
            easingDirection = tostring(v.EasingDirection),
            repeatCount = v.RepeatCount,
            reverses = v.Reverses,
            delayTime = v.DelayTime,
        }
    end,
    DateTime = function(v)
        return {
            __t = 'DateTime',
            unixTimestampMillis = v.UnixTimestampMillis,
            iso = v:ToIsoDate(),
        }
    end,
    Axes = function(v) return { __t = 'Axes', summary = tostring(v) } end,
    Faces = function(v) return { __t = 'Faces', summary = tostring(v) } end,
    PhysicalProperties = function(v)
        return { __t = 'PhysicalProperties', summary = tostring(v), density = v.Density, friction = v.Friction }
    end,
    Font = function(v) return { __t = 'Font', summary = tostring(v.Family), weight = tostring(v.Weight) } end,
    buffer = function(v)
        local ok, length = pcall(function() return buffer.len(v) end)
        return { __t = 'Buffer', length = ok and length or 0 }
    end,
}

--- Converts any Luau value into a JSON-safe, tagged, bounded representation.
-- @param value    the value to serialize
-- @param depth    current recursion depth
-- @param seen     table of in-progress tables, for cycle detection
-- @param counter  single-field table tracking the total node budget
serialize = function(value, depth, seen, counter)
    depth = depth or 0
    seen = seen or {}
    counter = counter or { nodes = 0 }

    counter.nodes = counter.nodes + 1
    if counter.nodes > LIMITS.maxNodes then
        return { __t = 'Truncated', reason = 'node-limit' }
    end

    local valueType = typeof(value)

    if value == nil then
        return nil
    elseif valueType == 'boolean' then
        return value
    elseif valueType == 'number' then
        if value ~= value then
            return { __t = 'Unsupported', reason = 'nan' }
        end
        if value == math.huge or value == -math.huge then
            return { __t = 'Unsupported', reason = tostring(value) }
        end
        return value
    elseif valueType == 'string' then
        return truncateString(value)
    elseif valueType == 'Instance' then
        return serializeInstance(value)
    end

    local specific = serializers[valueType]
    if specific then
        local ok, result = pcall(specific, value)
        if ok then
            return result
        end
        return { __t = 'Unsupported', reason = valueType }
    end

    if valueType == 'table' then
        if seen[value] then
            return { __t = 'Cycle' }
        end
        if depth >= LIMITS.maxDepth then
            return { __t = 'Truncated', reason = 'depth-limit' }
        end
        seen[value] = true

        local isArray = true
        local count = 0
        for key in pairs(value) do
            count = count + 1
            if type(key) ~= 'number' then
                isArray = false
            end
        end

        local out
        if isArray and count == #value then
            out = {}
            for index, item in ipairs(value) do
                if index > LIMITS.maxItems then
                    table.insert(out, { __t = 'Truncated', reason = 'item-limit', omitted = count - LIMITS.maxItems })
                    break
                end
                table.insert(out, serialize(item, depth + 1, seen, counter))
            end
        else
            out = {}
            local emitted = 0
            for key, item in pairs(value) do
                if emitted >= LIMITS.maxItems then
                    out.__truncated = true
                    break
                end
                local serializedValue = serialize(item, depth + 1, seen, counter)
                if serializedValue ~= nil then
                    out[tostring(key)] = serializedValue
                    emitted = emitted + 1
                end
            end
        end

        seen[value] = nil
        return out
    end

    if valueType == 'function' then
        return { __t = 'Unsupported', reason = 'function' }
    end

    -- Unknown userdata: never hand it to JSONEncode directly.
    local ok, text = pcall(tostring, value)
    return { __t = 'Unsupported', reason = valueType, text = ok and truncateString(text) or nil }
end

--------------------------------------------------------------------------------
-- Safe property registry
--------------------------------------------------------------------------------
-- Mirrors src/lib/tools/safe-properties.ts. Keep the two in sync when editing.

local SAFE_PROPERTIES = {
    Instance = { 'Name', 'ClassName', 'Archivable' },
    BasePart = {
        'Anchored', 'CanCollide', 'CanQuery', 'CanTouch', 'CastShadow', 'CFrame', 'CollisionGroup',
        'Color', 'Material', 'Massless', 'Position', 'Orientation', 'Reflectance', 'Size',
        'Transparency', 'AssemblyLinearVelocity', 'AssemblyAngularVelocity', 'AssemblyMass',
    },
    Part = { 'Shape' },
    MeshPart = { 'MeshId', 'TextureID', 'RenderFidelity', 'DoubleSided' },
    Model = { 'PrimaryPart', 'WorldPivot', 'ModelStreamingMode', 'LevelOfDetail' },
    ValueBase = { 'Value' },
    Humanoid = {
        'Health', 'MaxHealth', 'WalkSpeed', 'JumpPower', 'JumpHeight', 'UseJumpPower', 'HipHeight',
        'AutoRotate', 'PlatformStand', 'Sit', 'MoveDirection', 'RigType', 'DisplayName', 'HealthDisplayType',
    },
    Player = {
        'Name', 'DisplayName', 'UserId', 'AccountAge', 'Team', 'TeamColor', 'Neutral',
        'CharacterAppearanceId', 'CameraMinZoomDistance', 'CameraMaxZoomDistance', 'CameraMode',
    },
    Camera = { 'CFrame', 'Focus', 'FieldOfView', 'CameraType', 'CameraSubject', 'ViewportSize' },
    GuiBase2d = { 'AbsolutePosition', 'AbsoluteSize', 'AbsoluteRotation' },
    GuiObject = {
        'Active', 'AnchorPoint', 'BackgroundColor3', 'BackgroundTransparency', 'BorderColor3',
        'BorderSizePixel', 'ClipsDescendants', 'LayoutOrder', 'Position', 'Rotation', 'Size',
        'SizeConstraint', 'Visible', 'ZIndex', 'AbsolutePosition', 'AbsoluteSize',
    },
    ScreenGui = { 'Enabled', 'DisplayOrder', 'IgnoreGuiInset', 'ResetOnSpawn', 'ZIndexBehavior' },
    TextLabel = {
        'Text', 'TextColor3', 'TextSize', 'TextScaled', 'TextWrapped', 'TextTransparency',
        'TextXAlignment', 'TextYAlignment', 'RichText', 'FontFace', 'TextBounds', 'TextFits',
    },
    TextButton = { 'Text', 'TextColor3', 'TextSize', 'TextScaled', 'AutoButtonColor', 'Modal', 'Selected' },
    TextBox = { 'Text', 'PlaceholderText', 'ClearTextOnFocus', 'MultiLine', 'TextEditable' },
    ImageLabel = { 'Image', 'ImageColor3', 'ImageTransparency', 'ImageRectOffset', 'ImageRectSize', 'ScaleType', 'IsLoaded' },
    ImageButton = { 'Image', 'ImageColor3', 'ImageTransparency', 'ScaleType', 'IsLoaded', 'AutoButtonColor' },
    BaseScript = { 'Enabled', 'RunContext' },
    LocalScript = { 'Enabled' },
    ProximityPrompt = {
        'ActionText', 'ObjectText', 'HoldDuration', 'MaxActivationDistance', 'Enabled',
        'RequiresLineOfSight', 'KeyboardKeyCode', 'GamepadKeyCode', 'Exclusivity', 'UIOffset',
    },
    Sound = {
        'SoundId', 'Volume', 'Playing', 'IsPaused', 'IsPlaying', 'Looped', 'PlaybackSpeed',
        'TimePosition', 'TimeLength', 'RollOffMode', 'RollOffMaxDistance', 'RollOffMinDistance',
    },
    Animation = { 'AnimationId' },
    Tool = { 'Grip', 'CanBeDropped', 'Enabled', 'RequiresHandle', 'ToolTip', 'TextureId' },
    Attachment = { 'CFrame', 'Position', 'Orientation', 'WorldCFrame', 'WorldPosition', 'Visible' },
    Weld = { 'C0', 'C1', 'Enabled' },
    Motor6D = { 'C0', 'C1', 'Transform', 'Enabled' },
    Workspace = { 'Gravity', 'StreamingEnabled', 'StreamingTargetRadius', 'FallenPartsDestroyHeight', 'DistributedGameTime' },
    Lighting = { 'Ambient', 'Brightness', 'ClockTime', 'FogEnd', 'FogStart', 'GlobalShadows', 'TimeOfDay', 'ExposureCompensation' },
    Players = { 'MaxPlayers', 'PreferredPlayers', 'RespawnTime', 'CharacterAutoLoads' },
    StarterGui = { 'ResetPlayerGuiOnSpawn', 'ShowDevelopmentGui' },
    SoundService = { 'AmbientReverb', 'DistanceFactor', 'DopplerScale', 'RolloffScale' },
}

--- Classes to consult for an instance, using IsA rather than a hardcoded tree.
local CLASS_ORDER = {
    'Instance', 'BasePart', 'Part', 'MeshPart', 'Model', 'ValueBase', 'Humanoid', 'Player',
    'Camera', 'GuiBase2d', 'GuiObject', 'ScreenGui', 'TextLabel', 'TextButton', 'TextBox',
    'ImageLabel', 'ImageButton', 'BaseScript', 'LocalScript', 'ProximityPrompt', 'Sound',
    'Animation', 'Tool', 'Attachment', 'Weld', 'Motor6D', 'Workspace', 'Lighting', 'Players',
    'StarterGui', 'SoundService',
}

local function safePropertyNames(instance)
    local names = {}
    local seenName = {}
    for _, className in ipairs(CLASS_ORDER) do
        local isA = false
        local ok, result = pcall(function() return instance:IsA(className) end)
        isA = ok and result or false
        if isA then
            for _, property in ipairs(SAFE_PROPERTIES[className] or {}) do
                if not seenName[property] then
                    seenName[property] = true
                    table.insert(names, property)
                end
            end
        end
    end
    return names
end

local function readSafeProperties(instance)
    local out = {}
    local unavailable = {}
    for _, property in ipairs(safePropertyNames(instance)) do
        local ok, value = pcall(function()
            return instance[property]
        end)
        if ok then
            out[property] = serialize(value)
        else
            table.insert(unavailable, property)
        end
    end
    return out, unavailable
end

local function isSafeProperty(instance, property)
    for _, name in ipairs(safePropertyNames(instance)) do
        if name == property then
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- Instance summaries
--------------------------------------------------------------------------------

local function childCount(instance)
    local ok, children = pcall(function() return instance:GetChildren() end)
    return ok and #children or 0
end

local function summarize(instance)
    local path, display = pathOf(instance)
    local okName, name = pcall(function() return instance.Name end)
    local okClass, className = pcall(function() return instance.ClassName end)
    return {
        ref = refFor(instance),
        name = okName and name or '?',
        className = okClass and className or '?',
        path = path,
        displayPath = display,
        childCount = childCount(instance),
    }
end

local function matchesClassFilter(instance, classFilter)
    if classFilter == nil or #classFilter == 0 then
        return true
    end
    for _, className in ipairs(classFilter) do
        local ok, result = pcall(function() return instance:IsA(className) end)
        if ok and result then
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- Script source access
--------------------------------------------------------------------------------

--- Returns source text plus an honest description of where it came from.
local function readScriptSource(instance, maxBytes)
    maxBytes = math.min(maxBytes or LIMITS.maxSourceBytes, LIMITS.maxSourceBytes)

    -- A genuine Source property is only readable for scripts the client owns.
    local okSource, source = pcall(function() return instance.Source end)
    if okSource and type(source) == 'string' and source ~= '' then
        local truncated = #source > maxBytes
        return {
            representation = 'source',
            source = truncated and string.sub(source, 1, maxBytes) or source,
            truncated = truncated,
            totalBytes = #source,
            note = 'Read directly from the Source property.',
        }
    end

    if API.decompile then
        local okDecompile, decompiled = pcall(API.decompile, instance)
        if okDecompile and type(decompiled) == 'string' and decompiled ~= '' then
            local truncated = #decompiled > maxBytes
            return {
                representation = 'decompiled',
                source = truncated and string.sub(decompiled, 1, maxBytes) or decompiled,
                truncated = truncated,
                totalBytes = #decompiled,
                note = 'Best-effort decompiler output. This is NOT guaranteed to match the original source: '
                    .. 'names, formatting and control flow may differ, and the output may be wrong.',
            }
        end
    end

    if API.getscriptbytecode then
        local okBytecode, bytecode = pcall(API.getscriptbytecode, instance)
        if okBytecode and type(bytecode) == 'string' and bytecode ~= '' then
            return {
                representation = 'bytecode',
                source = nil,
                bytecodeBytes = #bytecode,
                truncated = false,
                note = 'Only compiled bytecode is available; this executor cannot decompile it.',
            }
        end
    end

    return {
        representation = 'unavailable',
        source = nil,
        truncated = false,
        note = 'No source representation is available for this script on this client.',
    }
end

--------------------------------------------------------------------------------
-- Tool handlers
--------------------------------------------------------------------------------

-- Forward declaration: handlers below push events through this, and it is
-- assigned once the connection section runs. Declaring it here means those
-- closures capture the local rather than a nil global.
local sendRaw

local handlers = {}

local function fail(code, message)
    return nil, { code = code, message = message }
end

local function requireTarget(args)
    local instance, err = resolveTarget(args)
    if instance == nil then
        return nil, { code = 'INSTANCE_NOT_FOUND', message = err or 'Instance not found.' }
    end
    return instance
end

handlers.ping = function()
    return {
        pong = true,
        clientTime = os.time(),
        bridgeVersion = BRIDGE_VERSION,
        frameRate = math.floor(1 / math.max(RunService.RenderStepped:Wait(), 0.0001)),
    }
end

handlers.get_services = function()
    local names = {
        'Workspace', 'Players', 'Lighting', 'ReplicatedStorage', 'ReplicatedFirst', 'StarterGui',
        'StarterPack', 'StarterPlayer', 'SoundService', 'Teams', 'TextChatService', 'Chat',
        'CollectionService', 'TweenService', 'UserInputService', 'RunService', 'HttpService',
        'MarketplaceService', 'PathfindingService', 'Debris', 'ContentProvider', 'GuiService',
    }
    local services = {}
    for _, name in ipairs(names) do
        local ok, service = pcall(function() return game:GetService(name) end)
        if ok and service then
            table.insert(services, summarize(service))
        end
    end
    return {
        services = services,
        inaccessible = {
            { name = 'ServerScriptService', reason = 'Server-only container; never replicated to a client.' },
            { name = 'ServerStorage', reason = 'Server-only container; never replicated to a client.' },
        },
    }
end

handlers.get_children = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local ok, children = pcall(function() return instance:GetChildren() end)
    if not ok then
        return fail('INSTANCE_NOT_FOUND', 'The children of that instance could not be read.')
    end

    local offset = math.max(tonumber(args.offset) or 0, 0)
    local limit = math.min(math.max(tonumber(args.limit) or 50, 1), 200)

    local filtered = {}
    for _, child in ipairs(children) do
        if matchesClassFilter(child, args.classFilter) then
            table.insert(filtered, child)
        end
    end

    local page = {}
    for index = offset + 1, math.min(offset + limit, #filtered) do
        table.insert(page, summarize(filtered[index]))
    end

    return {
        parent = summarize(instance),
        children = page,
        offset = offset,
        limit = limit,
        returned = #page,
        totalMatching = #filtered,
        totalChildren = #children,
        hasMore = offset + #page < #filtered,
    }
end

handlers.get_descendants = function(args)
    local root, err = requireTarget(args)
    if not root then return nil, err end

    local maxDepth = math.min(math.max(tonumber(args.maxDepth) or 4, 1), 12)
    local maxResults = math.min(math.max(tonumber(args.maxResults) or 200, 1), 500)

    local results = {}
    local truncated = false

    local function walk(instance, depth)
        if depth > maxDepth or truncated then
            return
        end
        local ok, children = pcall(function() return instance:GetChildren() end)
        if not ok then return end
        for _, child in ipairs(children) do
            if #results >= maxResults then
                truncated = true
                return
            end
            if matchesClassFilter(child, args.classFilter) then
                local entry = summarize(child)
                entry.depth = depth
                table.insert(results, entry)
            end
            walk(child, depth + 1)
        end
    end

    walk(root, 1)
    return { root = summarize(root), descendants = results, truncated = truncated, maxDepth = maxDepth }
end

handlers.find_instances = function(args)
    local root = game
    if args.root ~= nil then
        local resolved, err = resolveTarget(args.root)
        if resolved == nil then
            return nil, { code = 'INSTANCE_NOT_FOUND', message = err }
        end
        root = resolved
    end

    local query = tostring(args.query or '')
    local needle = args.exactName and query or string.lower(query)
    local maxResults = math.min(math.max(tonumber(args.maxResults) or 50, 1), 200)
    local maxDepth = math.min(math.max(tonumber(args.maxDepth) or 8, 1), 12)

    local results = {}
    local truncated = false
    local scanned = 0

    local function walk(instance, depth)
        if depth > maxDepth or truncated then return end
        local ok, children = pcall(function() return instance:GetChildren() end)
        if not ok then return end
        for _, child in ipairs(children) do
            scanned = scanned + 1
            if scanned > 40000 then
                truncated = true
                return
            end
            if #results >= maxResults then
                truncated = true
                return
            end
            local okName, name = pcall(function() return child.Name end)
            if okName and matchesClassFilter(child, args.classNames) then
                local hit
                if args.exactName then
                    hit = name == needle
                else
                    hit = string.find(string.lower(name), needle, 1, true) ~= nil
                end
                if hit then
                    table.insert(results, summarize(child))
                end
            end
            walk(child, depth + 1)
        end
    end

    walk(root, 1)
    return { query = query, matches = results, truncated = truncated, scanned = scanned }
end

handlers.inspect_instance = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local path, display = pathOf(instance)
    local okName, name = pcall(function() return instance.Name end)
    local okClass, className = pcall(function() return instance.ClassName end)
    local okParent, parent = pcall(function() return instance.Parent end)

    local result = {
        ref = refFor(instance),
        name = okName and name or '?',
        className = okClass and className or '?',
        path = path,
        displayPath = display,
        parent = (okParent and parent) and summarize(parent) or nil,
        replicated = true,
    }

    local okAttributes, attributes = pcall(function() return instance:GetAttributes() end)
    result.attributes = okAttributes and serialize(attributes) or {}

    local okTags, tags = pcall(function() return CollectionService:GetTags(instance) end)
    result.tags = okTags and tags or {}

    if args.includeProperties ~= false then
        local properties, unavailable = readSafeProperties(instance)
        result.properties = properties
        result.unavailableProperties = unavailable
    end

    local okChildren, children = pcall(function() return instance:GetChildren() end)
    if okChildren then
        result.childCount = #children
        if args.includeChildren ~= false then
            local limit = math.min(math.max(tonumber(args.childLimit) or 25, 1), 200)
            local summary = {}
            for index, child in ipairs(children) do
                if index > limit then break end
                table.insert(summary, summarize(child))
            end
            result.children = summary
            result.childrenTruncated = #children > limit
        end
    else
        result.childCount = 0
    end

    return result
end

handlers.get_attributes = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end
    local ok, attributes = pcall(function() return instance:GetAttributes() end)
    if not ok then
        return fail('INSTANCE_NOT_FOUND', 'Attributes could not be read from that instance.')
    end
    local count = 0
    for _ in pairs(attributes) do count = count + 1 end
    return { instance = summarize(instance), attributes = serialize(attributes), count = count }
end

handlers.get_tags = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end
    local ok, tags = pcall(function() return CollectionService:GetTags(instance) end)
    return { instance = summarize(instance), tags = ok and tags or {}, count = ok and #tags or 0 }
end

handlers.get_property = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local property = tostring(args.property or '')
    if not isSafeProperty(instance, property) then
        return fail(
            'PROPERTY_NOT_ALLOWED',
            'Property "' .. property .. '" is not in the Clovyre safe-property registry for this class.'
        )
    end

    local ok, value = pcall(function() return instance[property] end)
    if not ok then
        return {
            instance = summarize(instance),
            property = property,
            available = false,
            reason = 'The property exists in the registry but could not be read on this instance.',
        }
    end
    return { instance = summarize(instance), property = property, available = true, value = serialize(value) }
end

--- Reads several properties from one instance, keeping per-property outcomes.
local function readRequestedProperties(instance, properties)
    local values, rejected, unreadable = {}, {}, {}
    if #properties == 0 then
        local all, missing = readSafeProperties(instance)
        return all, rejected, missing
    end
    for _, property in ipairs(properties) do
        local name = tostring(property)
        if not isSafeProperty(instance, name) then
            table.insert(rejected, name)
        else
            local ok, value = pcall(function() return instance[name] end)
            if ok then
                values[name] = serialize(value)
            else
                table.insert(unreadable, name)
            end
        end
    end
    return values, rejected, unreadable
end

handlers.get_properties = function(args)
    local properties = type(args.properties) == 'table' and args.properties or {}
    local results = {}
    local notFound = {}

    local function collect(selector, target)
        local instance = resolveTarget(target)
        if instance == nil then
            table.insert(notFound, selector)
            return
        end
        local values, rejected, unreadable = readRequestedProperties(instance, properties)
        table.insert(results, {
            instance = summarize(instance),
            properties = values,
            rejected = rejected,
            unreadable = unreadable,
        })
    end

    for _, ref in ipairs(type(args.refs) == 'table' and args.refs or {}) do
        collect(ref, { ref = ref })
    end
    for _, path in ipairs(type(args.paths) == 'table' and args.paths or {}) do
        collect(path, { displayPath = path })
    end

    if #results == 0 and #notFound > 0 then
        return fail('INSTANCE_NOT_FOUND', 'None of the requested instances could be resolved.')
    end
    return { instances = results, notFound = notFound, requested = properties }
end

--- Compares a serialized property value against the requested criterion.
local function propertyMatches(value, operator, wanted)
    if operator == 'exists' then
        return value ~= nil
    end
    if value == nil then
        return false
    end
    -- Serialized tagged values (Vector3, Color3, ...) compare by their text form,
    -- which is what an agent has to work with anyway.
    local plain = value
    if type(plain) == 'table' then
        plain = plain.text or plain.value or plain.name
    end
    if operator == 'equals' then
        return plain == wanted or tostring(plain) == tostring(wanted)
    elseif operator == 'notEquals' then
        return not (plain == wanted or tostring(plain) == tostring(wanted))
    elseif operator == 'contains' then
        return string.find(string.lower(tostring(plain)), string.lower(tostring(wanted)), 1, true) ~= nil
    elseif operator == 'greaterThan' then
        local a, b = tonumber(plain), tonumber(wanted)
        return a ~= nil and b ~= nil and a > b
    elseif operator == 'lessThan' then
        local a, b = tonumber(plain), tonumber(wanted)
        return a ~= nil and b ~= nil and a < b
    end
    return false
end

handlers.search_properties = function(args)
    local property = tostring(args.property or '')
    if property == '' then
        return fail('INVALID_ARGUMENTS', 'A property name is required.')
    end

    local root = Workspace
    if args.root ~= nil then
        local resolved = resolveTarget({ displayPath = args.root })
        if resolved == nil then
            return fail('INSTANCE_NOT_FOUND', 'The search root could not be resolved.')
        end
        root = resolved
    end

    local operator = tostring(args.operator or 'equals')
    local maxResults = math.min(math.max(tonumber(args.maxResults) or 50, 1), 200)
    local maxDepth = math.min(math.max(tonumber(args.maxDepth) or 8, 1), 16)
    local classFilter = type(args.classNames) == 'table' and args.classNames or {}

    local matches = {}
    local scanned = 0
    local truncated = false

    local function visit(instance, depth)
        if truncated or depth > maxDepth then return end
        local okChildren, children = pcall(function() return instance:GetChildren() end)
        if not okChildren then return end
        for _, child in ipairs(children) do
            if truncated then return end
            scanned = scanned + 1
            if scanned > LIMITS.maxScanNodes then
                truncated = true
                return
            end
            if matchesClassFilter(child, classFilter) and isSafeProperty(child, property) then
                local ok, value = pcall(function() return child[property] end)
                if ok and propertyMatches(serialize(value), operator, args.value) then
                    table.insert(matches, {
                        instance = summarize(child),
                        value = serialize(value),
                    })
                    if #matches >= maxResults then
                        truncated = true
                        return
                    end
                end
            end
            visit(child, depth + 1)
        end
    end

    visit(root, 1)
    return {
        root = summarize(root),
        property = property,
        operator = operator,
        matches = matches,
        matchCount = #matches,
        scanned = scanned,
        truncated = truncated,
    }
end

local REMOTE_CLASSES = {
    RemoteEvent = true,
    RemoteFunction = true,
    UnreliableRemoteEvent = true,
}

handlers.list_remotes = function(args)
    local root = game
    if args.root ~= nil then
        local resolved = resolveTarget({ displayPath = args.root })
        if resolved == nil then
            return fail('INSTANCE_NOT_FOUND', 'The search root could not be resolved.')
        end
        root = resolved
    end

    local maxResults = math.min(math.max(tonumber(args.maxResults) or 200, 1), 500)
    local maxDepth = math.min(math.max(tonumber(args.maxDepth) or 10, 1), 16)

    local remotes = {}
    local scanned = 0
    local truncated = false

    local function visit(instance, depth)
        if truncated or depth > maxDepth then return end
        local okChildren, children = pcall(function() return instance:GetChildren() end)
        if not okChildren then return end
        for _, child in ipairs(children) do
            if truncated then return end
            scanned = scanned + 1
            if scanned > LIMITS.maxScanNodes then
                truncated = true
                return
            end
            local okClass, className = pcall(function() return child.ClassName end)
            if okClass and REMOTE_CLASSES[className] then
                local parent = summarize(child).path
                table.insert(remotes, {
                    instance = summarize(child),
                    className = className,
                    parentPath = parent,
                })
                if #remotes >= maxResults then
                    truncated = true
                    return
                end
            end
            visit(child, depth + 1)
        end
    end

    visit(root, 1)
    return {
        root = summarize(root),
        remotes = remotes,
        count = #remotes,
        scanned = scanned,
        truncated = truncated,
        note = 'Clovyre lists remotes so you can read the game\'s interface to its server. It provides no way to fire one.',
    }
end

handlers.get_ancestors = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local ancestors = {}
    local current = instance
    local guard = 0
    while guard < 64 do
        guard = guard + 1
        local okParent, parent = pcall(function() return current.Parent end)
        if not okParent or parent == nil then break end
        table.insert(ancestors, summarize(parent))
        current = parent
    end

    return { instance = summarize(instance), ancestors = ancestors, depth = #ancestors }
end

handlers.get_tag_index = function(args)
    local samplesPerTag = math.min(math.max(tonumber(args.samplesPerTag) or 3, 0), 10)
    local maxTags = math.min(math.max(tonumber(args.maxTags) or 80, 1), 200)

    local okTags, allTags = pcall(function() return CollectionService:GetAllTags() end)
    if not okTags or type(allTags) ~= 'table' then
        return fail(
            'CAPABILITY_UNAVAILABLE',
            'This client does not expose CollectionService:GetAllTags().'
        )
    end

    local tags = {}
    for index, tag in ipairs(allTags) do
        if index > maxTags then break end
        local okTagged, tagged = pcall(function() return CollectionService:GetTagged(tag) end)
        local entry = { tag = tag, count = 0, samples = {} }
        if okTagged and type(tagged) == 'table' then
            entry.count = #tagged
            for sampleIndex, instance in ipairs(tagged) do
                if sampleIndex > samplesPerTag then break end
                table.insert(entry.samples, summarize(instance))
            end
        end
        table.insert(tags, entry)
    end

    table.sort(tags, function(a, b) return a.count > b.count end)
    return { tags = tags, tagCount = #allTags, truncated = #allTags > maxTags }
end

handlers.get_instance_tree = function(args)
    local root, err = requireTarget(args)
    if not root then return nil, err end

    local maxDepth = math.min(math.max(tonumber(args.maxDepth) or 3, 1), 8)
    local maxNodes = math.min(math.max(tonumber(args.maxNodes) or 200, 1), 600)
    local childLimit = math.min(math.max(tonumber(args.childLimitPerNode) or 25, 1), 100)

    local nodes = 0
    local truncated = false

    local function build(instance, depth)
        nodes = nodes + 1
        if nodes > maxNodes then
            truncated = true
            return nil
        end
        local node = summarize(instance)
        if depth < maxDepth then
            local ok, children = pcall(function() return instance:GetChildren() end)
            if ok then
                local built = {}
                for index, child in ipairs(children) do
                    if index > childLimit then
                        truncated = true
                        break
                    end
                    local childNode = build(child, depth + 1)
                    if childNode == nil then break end
                    table.insert(built, childNode)
                end
                node.children = built
            end
        end
        return node
    end

    local tree = build(root, 0)
    return { tree = tree, truncated = truncated, nodeCount = nodes, maxDepth = maxDepth }
end

handlers.list_scripts = function(args)
    local root = game
    if args.root ~= nil then
        local resolved, err = resolveTarget(args.root)
        if resolved == nil then
            return nil, { code = 'INSTANCE_NOT_FOUND', message = err }
        end
        root = resolved
    end

    local classNames = args.classNames
    if classNames == nil or #classNames == 0 then
        classNames = { 'LocalScript', 'ModuleScript' }
    end

    local maxResults = math.min(math.max(tonumber(args.maxResults) or 100, 1), 500)
    local maxDepth = math.min(math.max(tonumber(args.maxDepth) or 8, 1), 12)

    local scripts = {}
    local truncated = false

    local function walk(instance, depth)
        if depth > maxDepth or truncated then return end
        local ok, children = pcall(function() return instance:GetChildren() end)
        if not ok then return end
        for _, child in ipairs(children) do
            if #scripts >= maxResults then
                truncated = true
                return
            end
            if matchesClassFilter(child, classNames) then
                local entry = summarize(child)
                local okEnabled, enabled = pcall(function() return child.Enabled end)
                entry.enabled = okEnabled and enabled or nil
                entry.sourceAvailability =
                    (pcall(function() return child.Source end) and 'source')
                    or (API.decompile and 'decompile-possible')
                    or (API.getscriptbytecode and 'bytecode-only')
                    or 'unavailable'
                table.insert(scripts, entry)
            end
            walk(child, depth + 1)
        end
    end

    walk(root, 1)
    return {
        scripts = scripts,
        truncated = truncated,
        decompileAvailable = API.decompile ~= nil,
        note = 'Server Scripts are not replicated to clients and never appear in this list.',
    }
end

handlers.inspect_script = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local okIsScript, isScript = pcall(function()
        return instance:IsA('LuaSourceContainer')
    end)
    if not (okIsScript and isScript) then
        return fail('INVALID_ARGUMENTS', 'That instance is not a script.')
    end

    local result = summarize(instance)
    local okEnabled, enabled = pcall(function() return instance.Enabled end)
    result.enabled = okEnabled and enabled or nil

    if args.includeSource == false then
        result.representation = 'not-requested'
        return result
    end

    local source = readScriptSource(instance, tonumber(args.maxSourceBytes))
    result.representation = source.representation
    result.source = source.source
    result.truncated = source.truncated
    result.totalBytes = source.totalBytes
    result.bytecodeBytes = source.bytecodeBytes
    result.note = source.note
    if source.source then
        local _, lineCount = string.gsub(source.source, '\n', '')
        result.lineCount = lineCount + 1
    end
    return result
end

handlers.search_scripts = function(args)
    local root = game
    if args.root ~= nil then
        local resolved, err = resolveTarget(args.root)
        if resolved == nil then
            return nil, { code = 'INSTANCE_NOT_FOUND', message = err }
        end
        root = resolved
    end

    local query = tostring(args.query or '')
    local isPattern = args.isPattern == true
    local caseSensitive = args.caseSensitive == true
    local maxScripts = math.min(math.max(tonumber(args.maxScripts) or 40, 1), 200)
    local maxMatches = math.min(math.max(tonumber(args.maxMatches) or 40, 1), 200)
    local contextLines = math.min(math.max(tonumber(args.contextLines) or 2, 0), 6)

    local needle = caseSensitive and query or string.lower(query)

    local candidates = {}
    local function collect(instance, depth)
        if depth > 10 or #candidates >= maxScripts then return end
        local ok, children = pcall(function() return instance:GetChildren() end)
        if not ok then return end
        for _, child in ipairs(children) do
            if #candidates >= maxScripts then return end
            if matchesClassFilter(child, { 'LocalScript', 'ModuleScript' }) then
                table.insert(candidates, child)
            end
            collect(child, depth + 1)
        end
    end
    collect(root, 1)

    local matches = {}
    local searched = 0
    local truncated = false

    for _, scriptInstance in ipairs(candidates) do
        if #matches >= maxMatches then
            truncated = true
            break
        end
        local source = readScriptSource(scriptInstance, LIMITS.maxSourceBytes)
        if source.source then
            searched = searched + 1
            local lines = {}
            for line in string.gmatch(source.source .. '\n', '([^\n]*)\n') do
                table.insert(lines, line)
            end
            for index, line in ipairs(lines) do
                if #matches >= maxMatches then
                    truncated = true
                    break
                end
                local haystack = caseSensitive and line or string.lower(line)
                local found
                if isPattern then
                    local okFind, position = pcall(string.find, haystack, needle)
                    found = okFind and position ~= nil
                else
                    found = string.find(haystack, needle, 1, true) ~= nil
                end
                if found then
                    local context = {}
                    for offset = -contextLines, contextLines do
                        local target = index + offset
                        if lines[target] then
                            table.insert(context, {
                                line = target,
                                text = truncateString(lines[target]),
                                isMatch = offset == 0,
                            })
                        end
                    end
                    table.insert(matches, {
                        script = summarize(scriptInstance),
                        representation = source.representation,
                        line = index,
                        context = context,
                    })
                end
            end
        end
    end

    return {
        query = query,
        matches = matches,
        scriptsSearched = searched,
        scriptsConsidered = #candidates,
        truncated = truncated,
        note = 'Decompiled representations are best-effort and may not match the original source.',
    }
end

handlers.get_script_dependencies = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local source = readScriptSource(instance, LIMITS.maxSourceBytes)
    if not source.source then
        return {
            script = summarize(instance),
            representation = source.representation,
            dependencies = {},
            note = 'No source representation was available, so dependencies could not be scanned.',
        }
    end

    local maxResults = math.min(math.max(tonumber(args.maxResults) or 50, 1), 200)
    local dependencies = {}
    local seenExpression = {}

    for expression in string.gmatch(source.source, 'require%s*%(([^%)]+)%)') do
        if #dependencies >= maxResults then break end
        local trimmed = (string.gsub(expression, '^%s*(.-)%s*$', '%1'))
        if not seenExpression[trimmed] then
            seenExpression[trimmed] = true
            local entry = { expression = truncateString(trimmed), resolved = false }

            -- Resolve only the simple, statically analysable shapes.
            local names = {}
            for name in string.gmatch(trimmed, '[%a_][%w_]*') do
                table.insert(names, name)
            end
            if #names > 0 then
                local current = nil
                local startIndex = 1
                if names[1] == 'game' then
                    current = game
                    startIndex = 2
                elseif names[1] == 'script' then
                    current = instance
                    startIndex = 2
                end
                if current then
                    local resolvedAll = true
                    for index = startIndex, #names do
                        local step = names[index]
                        local okStep, nextInstance = pcall(function()
                            if step == 'Parent' then return current.Parent end
                            if current == game then
                                local okService, service = pcall(function() return game:GetService(step) end)
                                if okService and service then return service end
                            end
                            return current:FindFirstChild(step)
                        end)
                        if okStep and nextInstance then
                            current = nextInstance
                        else
                            resolvedAll = false
                            break
                        end
                    end
                    if resolvedAll and typeof(current) == 'Instance' then
                        entry.resolved = true
                        entry.instance = summarize(current)
                    end
                end
            end

            if not entry.resolved then
                entry.reason = 'This require target could not be resolved statically (dynamic or non-literal path).'
            end
            table.insert(dependencies, entry)
        end
    end

    return {
        script = summarize(instance),
        representation = source.representation,
        dependencies = dependencies,
        note = 'Best-effort static scan of the available representation. Dynamic requires cannot be resolved.',
    }
end

handlers.get_loaded_modules = function(args)
    if not API.getloadedmodules then
        return fail('CAPABILITY_UNAVAILABLE', 'This executor does not expose getloadedmodules.')
    end
    local ok, modules = pcall(API.getloadedmodules)
    if not ok or type(modules) ~= 'table' then
        return fail('INTERNAL_ERROR', 'getloadedmodules failed on this executor.')
    end

    local maxResults = math.min(math.max(tonumber(args.maxResults) or 100, 1), 500)
    local excludeCoreGui = args.excludeCoreGui ~= false
    local out = {}

    for _, moduleScript in ipairs(modules) do
        if #out >= maxResults then break end
        if typeof(moduleScript) == 'Instance' then
            local _, display = pathOf(moduleScript)
            local skip = excludeCoreGui and string.find(display, 'CoreGui', 1, true) ~= nil
            if not skip then
                table.insert(out, summarize(moduleScript))
            end
        end
    end

    return { modules = out, total = #modules, returned = #out }
end

handlers.get_players = function(args)
    local maxResults = math.min(math.max(tonumber(args.maxResults) or 50, 1), 100)
    local ok, list = pcall(function() return Players:GetPlayers() end)
    if not ok then
        return fail('INTERNAL_ERROR', 'The player list could not be read.')
    end

    local out = {}
    for index, player in ipairs(list) do
        if index > maxResults then break end
        local entry = summarize(player)
        entry.properties = readSafeProperties(player)
        if args.includeCharacters then
            local okCharacter, character = pcall(function() return player.Character end)
            entry.character = (okCharacter and character) and summarize(character) or nil
        end
        entry.isLocalPlayer = player == Players.LocalPlayer
        table.insert(out, entry)
    end

    return { players = out, total = #list, returned = #out }
end

handlers.get_local_player = function()
    local player = Players.LocalPlayer
    if player == nil then
        return fail('INSTANCE_NOT_FOUND', 'There is no LocalPlayer on this client.')
    end

    local result = summarize(player)
    result.properties = readSafeProperties(player)

    local okGui, playerGui = pcall(function() return player:FindFirstChildOfClass('PlayerGui') end)
    result.playerGui = (okGui and playerGui) and summarize(playerGui) or nil

    local okPack, backpack = pcall(function() return player:FindFirstChildOfClass('Backpack') end)
    result.backpack = (okPack and backpack) and summarize(backpack) or nil

    local okCharacter, character = pcall(function() return player.Character end)
    result.character = (okCharacter and character) and summarize(character) or nil

    return result
end

handlers.get_character = function(args)
    local player = Players.LocalPlayer
    if type(args.playerName) == 'string' and args.playerName ~= '' then
        local ok, found = pcall(function() return Players:FindFirstChild(args.playerName) end)
        player = ok and found or nil
    end
    if player == nil then
        return fail('INSTANCE_NOT_FOUND', 'That player is not replicated to this client.')
    end

    local okCharacter, character = pcall(function() return player.Character end)
    if not okCharacter or character == nil then
        return fail('INSTANCE_NOT_FOUND', 'That player has no character on this client right now.')
    end

    local result = summarize(character)
    result.player = summarize(player)

    local okHumanoid, humanoid = pcall(function() return character:FindFirstChildOfClass('Humanoid') end)
    if okHumanoid and humanoid then
        result.humanoid = summarize(humanoid)
        result.humanoid.properties = readSafeProperties(humanoid)
    end

    local okRoot, root = pcall(function() return character:FindFirstChild('HumanoidRootPart') end)
    if okRoot and root then
        result.rootPart = summarize(root)
        result.rootPart.properties = readSafeProperties(root)
    end

    if args.includeDescendants then
        local okChildren, children = pcall(function() return character:GetChildren() end)
        if okChildren then
            local parts = {}
            for index, child in ipairs(children) do
                if index > 100 then break end
                table.insert(parts, summarize(child))
            end
            result.children = parts
        end
    end

    return result
end

handlers.get_camera = function()
    local camera = Workspace.CurrentCamera
    if camera == nil then
        return fail('INSTANCE_NOT_FOUND', 'There is no current camera on this client.')
    end
    local result = summarize(camera)
    result.properties = readSafeProperties(camera)
    return result
end

--- Current camera, or nil on a client that has none yet.
local function currentCamera()
    local ok, camera = pcall(function() return Workspace.CurrentCamera end)
    return ok and camera or nil
end

local function localCharacter()
    local player = Players.LocalPlayer
    local ok, character = pcall(function() return player and player.Character or nil end)
    return ok and character or nil
end

--- Resolves the anchor point for the spatial handlers.
local function anchorPosition(mode, explicit)
    if mode == 'point' then
        if type(explicit) ~= 'table' or #explicit < 3 then
            return nil, 'Provide "point" as [x, y, z] when using point mode.'
        end
        return Vector3.new(explicit[1], explicit[2], explicit[3])
    end
    if mode == 'camera' then
        local camera = currentCamera()
        if camera == nil then return nil, 'This client has no current camera.' end
        return camera.CFrame.Position
    end
    local character = localCharacter()
    if character == nil then return nil, 'The local character is not spawned.' end
    local ok, root = pcall(function()
        return character:FindFirstChild('HumanoidRootPart') or character.PrimaryPart
    end)
    if not ok or root == nil then return nil, 'The character has no root part yet.' end
    return root.Position
end

handlers.raycast = function(args)
    local mode = tostring(args.from or 'camera')
    local maxDistance = math.min(math.max(tonumber(args.maxDistance) or 500, 1), 10000)

    local origin, originError
    if args.origin ~= nil and type(args.origin) == 'table' and #args.origin >= 3 then
        origin = Vector3.new(args.origin[1], args.origin[2], args.origin[3])
    else
        origin, originError = anchorPosition(mode == 'point' and 'camera' or mode, nil)
        if origin == nil then
            return fail('INSTANCE_NOT_FOUND', originError)
        end
    end

    local direction
    if type(args.direction) == 'table' and #args.direction >= 3 then
        direction = Vector3.new(args.direction[1], args.direction[2], args.direction[3])
        if direction.Magnitude > 0 then
            direction = direction.Unit * maxDistance
        end
    else
        local camera = currentCamera()
        if camera == nil then
            return fail('INVALID_ARGUMENTS', 'No direction was given and this client has no camera to take one from.')
        end
        direction = camera.CFrame.LookVector * maxDistance
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    if args.ignoreCharacter ~= false then
        local character = localCharacter()
        params.FilterDescendantsInstances = character and { character } or {}
    end

    local ok, result = pcall(function()
        return Workspace:Raycast(origin, direction, params)
    end)
    if not ok then
        return fail('CAPABILITY_UNAVAILABLE', 'Workspace:Raycast is not available on this client.')
    end
    if result == nil then
        return {
            hit = false,
            origin = serialize(origin),
            direction = serialize(direction),
            maxDistance = maxDistance,
            note = 'The ray reached its maximum distance without hitting anything.',
        }
    end

    return {
        hit = true,
        instance = summarize(result.Instance),
        position = serialize(result.Position),
        normal = serialize(result.Normal),
        distance = (result.Position - origin).Magnitude,
        material = tostring(result.Material),
        origin = serialize(origin),
    }
end

handlers.query_region = function(args)
    local mode = tostring(args.around or 'character')
    local centre, centreError = anchorPosition(mode, args.point)
    if centre == nil then
        return fail('INSTANCE_NOT_FOUND', centreError)
    end

    local radius = math.min(math.max(tonumber(args.radius) or 50, 1), 2000)
    local maxResults = math.min(math.max(tonumber(args.maxResults) or 60, 1), 300)
    local classFilter = type(args.classNames) == 'table' and args.classNames or {}

    local okDescendants, descendants = pcall(function() return Workspace:GetDescendants() end)
    if not okDescendants then
        return fail('INSTANCE_NOT_FOUND', 'The workspace could not be read.')
    end

    local found = {}
    local scanned = 0
    local truncated = false
    for _, instance in ipairs(descendants) do
        scanned = scanned + 1
        if scanned > LIMITS.maxScanNodes then
            truncated = true
            break
        end
        local okPosition, position = pcall(function() return instance.Position end)
        if okPosition and typeof(position) == 'Vector3' then
            if #classFilter == 0 or matchesClassFilter(instance, classFilter) then
                local distance = (position - centre).Magnitude
                if distance <= radius then
                    table.insert(found, {
                        instance = summarize(instance),
                        distance = distance,
                        position = serialize(position),
                    })
                end
            end
        end
    end

    table.sort(found, function(a, b) return a.distance < b.distance end)
    local trimmed = {}
    for index, entry in ipairs(found) do
        if index > maxResults then
            truncated = true
            break
        end
        table.insert(trimmed, entry)
    end

    return {
        centre = serialize(centre),
        radius = radius,
        parts = trimmed,
        count = #trimmed,
        totalWithinRadius = #found,
        scanned = scanned,
        truncated = truncated,
    }
end

handlers.get_stats = function()
    local result = { available = Stats ~= nil }
    if Stats == nil then
        result.note = 'This client does not expose the Stats service.'
        return result
    end

    local function statValue(getter)
        local ok, value = pcall(getter)
        return ok and value or nil
    end

    result.frameRatePerSecond = statValue(function()
        return math.floor(1 / math.max(RunService.RenderStepped:Wait(), 0.0001))
    end)
    result.heartbeatTimeMs = statValue(function() return Stats.HeartbeatTimeMs end)
    result.physicsStepTimeMs = statValue(function() return Stats.PhysicsStepTimeMs end)
    result.dataReceiveKbps = statValue(function() return Stats.DataReceiveKbps end)
    result.dataSendKbps = statValue(function() return Stats.DataSendKbps end)
    result.totalMemoryMb = statValue(function() return Stats:GetTotalMemoryUsageMb() end)
    result.instanceCount = statValue(function() return Stats.InstanceCount end)
    result.movingPrimitivesCount = statValue(function() return Stats.MovingPrimitivesCount end)
    result.primitivesCount = statValue(function() return Stats.PrimitivesCount end)
    result.ping = statValue(function()
        return Stats.Network.ServerStatsItem['Data Ping']:GetValue()
    end)
    return result
end

handlers.get_teams = function()
    if Teams == nil then
        return { available = false, teams = {}, note = 'This client does not expose the Teams service.' }
    end
    local okTeams, teamList = pcall(function() return Teams:GetTeams() end)
    if not okTeams then
        return { available = false, teams = {}, note = 'The Teams service could not be read.' }
    end

    local teams = {}
    for _, team in ipairs(teamList) do
        local entry = { instance = summarize(team), members = {} }
        local okName, name = pcall(function() return team.Name end)
        entry.name = okName and name or '?'
        local okColour, colour = pcall(function() return team.TeamColor end)
        entry.teamColor = okColour and tostring(colour) or nil
        local okPlayers, members = pcall(function() return team:GetPlayers() end)
        if okPlayers then
            for _, player in ipairs(members) do
                local okPlayerName, playerName = pcall(function() return player.Name end)
                table.insert(entry.members, okPlayerName and playerName or '?')
            end
        end
        table.insert(teams, entry)
    end
    return { available = true, teams = teams, count = #teams }
end

handlers.get_leaderstats = function(args)
    local wanted = args.playerName ~= nil and tostring(args.playerName) or nil
    local maxPlayers = math.min(math.max(tonumber(args.maxPlayers) or 50, 1), 100)

    local okPlayers, players = pcall(function() return Players:GetPlayers() end)
    if not okPlayers then
        return fail('INSTANCE_NOT_FOUND', 'The player list could not be read.')
    end

    local rows = {}
    for _, player in ipairs(players) do
        if #rows >= maxPlayers then break end
        local okName, name = pcall(function() return player.Name end)
        name = okName and name or '?'
        if wanted == nil or name == wanted then
            local row = { player = name, stats = {}, hasLeaderstats = false }
            local okStats, leaderstats = pcall(function()
                return player:FindFirstChild('leaderstats')
            end)
            if okStats and leaderstats ~= nil then
                row.hasLeaderstats = true
                local okChildren, children = pcall(function() return leaderstats:GetChildren() end)
                if okChildren then
                    for _, stat in ipairs(children) do
                        local okStatName, statName = pcall(function() return stat.Name end)
                        local okValue, value = pcall(function() return stat.Value end)
                        if okStatName then
                            row.stats[statName] = okValue and serialize(value) or nil
                        end
                    end
                end
            end
            table.insert(rows, row)
        end
    end

    if wanted ~= nil and #rows == 0 then
        return fail('INSTANCE_NOT_FOUND', 'No player named "' .. wanted .. '" is in this server.')
    end
    return { players = rows, count = #rows }
end

handlers.get_backpack = function(args)
    local player = Players.LocalPlayer
    if player == nil then
        return fail('INSTANCE_NOT_FOUND', 'There is no local player on this client.')
    end
    local includeProperties = args.includeProperties == true

    local function describeTool(tool)
        local entry = { instance = summarize(tool) }
        if includeProperties then
            entry.properties = readSafeProperties(tool)
        end
        return entry
    end

    local carried = {}
    local okBackpack, backpack = pcall(function()
        return player:FindFirstChildOfClass('Backpack')
    end)
    if okBackpack and backpack ~= nil then
        local okChildren, children = pcall(function() return backpack:GetChildren() end)
        if okChildren then
            for _, child in ipairs(children) do
                local okClass, className = pcall(function() return child.ClassName end)
                if okClass and className == 'Tool' then
                    table.insert(carried, describeTool(child))
                end
            end
        end
    end

    local equipped = nil
    local character = localCharacter()
    if character ~= nil then
        local okEquipped, tool = pcall(function()
            return character:FindFirstChildOfClass('Tool')
        end)
        if okEquipped and tool ~= nil then
            equipped = describeTool(tool)
        end
    end

    return { backpack = carried, backpackCount = #carried, equipped = equipped }
end

handlers.get_lighting = function()
    if Lighting == nil then
        return { available = false, note = 'This client does not expose the Lighting service.' }
    end

    local result = { available = true, lighting = readSafeProperties(Lighting), effects = {} }
    local okChildren, children = pcall(function() return Lighting:GetChildren() end)
    if okChildren then
        for index, child in ipairs(children) do
            if index > 60 then break end
            table.insert(result.effects, {
                instance = summarize(child),
                properties = readSafeProperties(child),
            })
        end
    end
    return result
end

handlers.get_sounds = function(args)
    local includeStopped = args.includeStopped == true
    local maxResults = math.min(math.max(tonumber(args.maxResults) or 60, 1), 200)

    local roots = { Workspace }
    if SoundService ~= nil then table.insert(roots, SoundService) end
    local player = Players.LocalPlayer
    local okGui, playerGui = pcall(function()
        return player and player:FindFirstChildOfClass('PlayerGui') or nil
    end)
    if okGui and playerGui ~= nil then table.insert(roots, playerGui) end

    local sounds = {}
    local scanned = 0
    local truncated = false

    for _, root in ipairs(roots) do
        if truncated then break end
        local okDescendants, descendants = pcall(function() return root:GetDescendants() end)
        if okDescendants then
            for _, instance in ipairs(descendants) do
                scanned = scanned + 1
                if scanned > LIMITS.maxScanNodes then
                    truncated = true
                    break
                end
                local okClass, className = pcall(function() return instance.ClassName end)
                if okClass and className == 'Sound' then
                    local okPlaying, isPlaying = pcall(function() return instance.IsPlaying end)
                    if includeStopped or (okPlaying and isPlaying) then
                        local function read(name)
                            local ok, value = pcall(function() return instance[name] end)
                            return ok and value or nil
                        end
                        table.insert(sounds, {
                            instance = summarize(instance),
                            playing = okPlaying and isPlaying or false,
                            soundId = read('SoundId'),
                            volume = read('Volume'),
                            timePosition = read('TimePosition'),
                            looped = read('Looped'),
                        })
                        if #sounds >= maxResults then
                            truncated = true
                            break
                        end
                    end
                end
            end
        end
    end

    return { sounds = sounds, count = #sounds, scanned = scanned, truncated = truncated }
end

handlers.get_animations = function(args)
    local character
    if args.playerName ~= nil then
        local okPlayer, player = pcall(function()
            return Players:FindFirstChild(tostring(args.playerName))
        end)
        if not okPlayer or player == nil then
            return fail('INSTANCE_NOT_FOUND', 'No player named "' .. tostring(args.playerName) .. '" is in this server.')
        end
        local okCharacter, found = pcall(function() return player.Character end)
        character = okCharacter and found or nil
    else
        character = localCharacter()
    end

    if character == nil then
        return fail('INSTANCE_NOT_FOUND', 'That character is not spawned.')
    end

    local okHumanoid, humanoid = pcall(function()
        return character:FindFirstChildOfClass('Humanoid')
    end)
    if not okHumanoid or humanoid == nil then
        return fail('INSTANCE_NOT_FOUND', 'That character has no Humanoid.')
    end

    local okAnimator, animator = pcall(function()
        return humanoid:FindFirstChildOfClass('Animator')
    end)
    local source = (okAnimator and animator) or humanoid

    local okTracks, tracks = pcall(function() return source:GetPlayingAnimationTracks() end)
    if not okTracks then
        return fail('CAPABILITY_UNAVAILABLE', 'This client does not expose GetPlayingAnimationTracks.')
    end

    local playing = {}
    for index, track in ipairs(tracks) do
        if index > 60 then break end
        local function read(name)
            local ok, value = pcall(function() return track[name] end)
            return ok and value or nil
        end
        local okAnimation, animation = pcall(function() return track.Animation end)
        table.insert(playing, {
            name = read('Name'),
            animationId = (okAnimation and animation) and select(2, pcall(function()
                return animation.AnimationId
            end)) or nil,
            isPlaying = read('IsPlaying'),
            speed = read('Speed'),
            weight = read('WeightCurrent'),
            timePosition = read('TimePosition'),
            looped = read('Looped'),
            priority = tostring(read('Priority') or ''),
        })
    end

    return { character = summarize(character), tracks = playing, count = #playing }
end

handlers.get_workspace_summary = function(args)
    local maxClasses = math.min(math.max(tonumber(args.maxClasses) or 25, 1), 60)

    local result = {
        workspace = summarize(Workspace),
        properties = readSafeProperties(Workspace),
    }

    local ok, children = pcall(function() return Workspace:GetChildren() end)
    if ok then
        result.topLevelChildCount = #children
        local histogram = {}
        for index, child in ipairs(children) do
            if index > 5000 then break end
            local okClass, className = pcall(function() return child.ClassName end)
            if okClass then
                histogram[className] = (histogram[className] or 0) + 1
            end
        end
        local classes = {}
        for className, count in pairs(histogram) do
            table.insert(classes, { className = className, count = count })
        end
        table.sort(classes, function(a, b) return a.count > b.count end)
        local trimmed = {}
        for index, entry in ipairs(classes) do
            if index > maxClasses then break end
            table.insert(trimmed, entry)
        end
        result.topLevelClasses = trimmed
        result.distinctTopLevelClasses = #classes
    end

    return result
end

handlers.get_logs = function(args)
    local maxResults = math.min(math.max(tonumber(args.maxResults) or 100, 1), 300)
    local levelRank = { trace = 0, debug = 1, info = 2, warn = 3, error = 4 }
    local minRank = levelRank[args.minLevel or 'debug'] or 1

    local out = {}
    for index = #logBuffer, 1, -1 do
        if #out >= maxResults then break end
        local entry = logBuffer[index]
        if (levelRank[entry.level] or 2) >= minRank then
            table.insert(out, entry)
        end
    end

    local result = { logs = out, captured = #logBuffer, source = 'clovyre-bridge' }

    local getLogHistory = globalFn('getlogs') or globalFn('getlogshistory')
    if getLogHistory then
        local ok, history = pcall(getLogHistory)
        if ok and type(history) == 'table' then
            local clientOutput = {}
            for index = math.max(#history - maxResults, 1), #history do
                local entry = history[index]
                if type(entry) == 'table' and entry.Message then
                    table.insert(clientOutput, {
                        message = truncateString(tostring(entry.Message)),
                        type = tostring(entry.Type or 'output'),
                    })
                end
            end
            result.clientOutput = clientOutput
        end
    end

    return result
end

handlers.get_connections = function(args)
    if not API.getconnections then
        return fail('CAPABILITY_UNAVAILABLE', 'This executor does not expose getconnections.')
    end

    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local signalName = tostring(args.signal or '')
    local okSignal, signal = pcall(function() return instance[signalName] end)
    if not okSignal or signal == nil then
        return fail('INVALID_ARGUMENTS', 'That instance has no signal named "' .. signalName .. '".')
    end

    local okConnections, connections = pcall(API.getconnections, signal)
    if not okConnections or type(connections) ~= 'table' then
        return fail('INTERNAL_ERROR', 'getconnections failed for that signal.')
    end

    local maxResults = math.min(math.max(tonumber(args.maxResults) or 25, 1), 100)
    local out = {}
    for index, connection in ipairs(connections) do
        if index > maxResults then break end
        local entry = { index = index }
        pcall(function() entry.enabled = connection.Enabled end)
        pcall(function() entry.foreignState = connection.ForeignState end)
        pcall(function() entry.luaConnection = connection.LuaConnection end)
        pcall(function()
            if connection.Function then
                local details = debug and debug.info and debug.info(connection.Function, 'sln')
                entry.functionInfo = details and tostring(details) or 'function'
            end
        end)
        table.insert(out, entry)
    end

    return { instance = summarize(instance), signal = signalName, connections = out, total = #connections }
end

handlers.get_gc_summary = function(args)
    if not API.getgc then
        return fail('CAPABILITY_UNAVAILABLE', 'This executor does not expose getgc.')
    end

    local nameFilter = tostring(args.nameFilter or '')
    if #nameFilter < 2 then
        return fail('INVALID_ARGUMENTS', 'A nameFilter of at least 2 characters is required.')
    end

    local kind = args.kind == 'table' and 'table' or 'function'
    local maxResults = math.min(math.max(tonumber(args.maxResults) or 25, 1), 100)
    local needle = string.lower(nameFilter)

    local ok, objects = pcall(API.getgc, args.includeMetatables == true)
    if not ok or type(objects) ~= 'table' then
        return fail('INTERNAL_ERROR', 'getgc failed on this executor.')
    end

    local matches = {}
    local scanned = 0

    for _, object in pairs(objects) do
        if #matches >= maxResults then break end
        scanned = scanned + 1
        if scanned > 200000 then break end

        if kind == 'function' and type(object) == 'function' then
            local okInfo, name, source, line = pcall(function()
                if debug and debug.info then
                    return debug.info(object, 'n'), debug.info(object, 's'), debug.info(object, 'l')
                end
                return nil, nil, nil
            end)
            local label = okInfo and tostring(name or '') or ''
            local sourceLabel = okInfo and tostring(source or '') or ''
            if string.find(string.lower(label .. ' ' .. sourceLabel), needle, 1, true) then
                table.insert(matches, {
                    kind = 'function',
                    name = label ~= '' and label or nil,
                    source = sourceLabel ~= '' and truncateString(sourceLabel) or nil,
                    line = okInfo and line or nil,
                })
            end
        elseif kind == 'table' and type(object) == 'table' then
            local keys = {}
            local okIterate = pcall(function()
                local count = 0
                for key in pairs(object) do
                    count = count + 1
                    if count > 40 then break end
                    table.insert(keys, tostring(key))
                end
            end)
            if okIterate then
                local joined = string.lower(table.concat(keys, ' '))
                if string.find(joined, needle, 1, true) then
                    local preview = {}
                    for index, key in ipairs(keys) do
                        if index > 20 then break end
                        table.insert(preview, key)
                    end
                    table.insert(matches, { kind = 'table', keys = preview, keyCount = #keys })
                end
            end
        end
    end

    return {
        kind = kind,
        nameFilter = nameFilter,
        matches = matches,
        scanned = scanned,
        note = 'Filtered and capped. Clovyre never returns an unfiltered garbage-collector dump.',
    }
end

handlers.inspect_environment = function(args)
    if not API.getsenv then
        return fail('CAPABILITY_UNAVAILABLE', 'This executor does not expose getsenv.')
    end

    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local okIsScript, isScript = pcall(function() return instance:IsA('LuaSourceContainer') end)
    if not (okIsScript and isScript) then
        return fail('INVALID_ARGUMENTS', 'inspect_environment requires a script instance.')
    end

    local okEnv, environment = pcall(API.getsenv, instance)
    if not okEnv or type(environment) ~= 'table' then
        return fail(
            'INTERNAL_ERROR',
            'getsenv could not read that script environment. The script may not be running on this client.'
        )
    end

    local maxKeys = math.min(math.max(tonumber(args.maxKeys) or 50, 1), 200)
    local entries = {}
    local count = 0

    for key, value in pairs(environment) do
        count = count + 1
        if #entries < maxKeys then
            local valueType = typeof(value)
            local entry = { key = tostring(key), type = valueType }
            if valueType == 'string' or valueType == 'number' or valueType == 'boolean' then
                entry.value = serialize(value)
            elseif valueType == 'Instance' then
                entry.value = serializeInstance(value)
            elseif valueType == 'table' then
                local keyCount = 0
                pcall(function()
                    for _ in pairs(value) do keyCount = keyCount + 1 end
                end)
                entry.summary = 'table with ' .. tostring(keyCount) .. ' keys'
            else
                entry.summary = valueType
            end
            table.insert(entries, entry)
        end
    end

    return {
        script = summarize(instance),
        entries = entries,
        totalKeys = count,
        truncated = count > #entries,
    }
end

--- Resolves the PlayerGui, which most GUI handlers start from.
local function playerGuiRoot()
    local player = Players.LocalPlayer
    local ok, gui = pcall(function()
        return player and player:FindFirstChildOfClass('PlayerGui') or nil
    end)
    return ok and gui or nil
end

--- True when an element and every ancestor up to the root is visible/enabled.
local function guiEffectivelyVisible(instance)
    local current = instance
    local guard = 0
    while current ~= nil and guard < 64 do
        guard = guard + 1
        local okVisible, visible = pcall(function() return current.Visible end)
        if okVisible and visible == false then return false end
        local okEnabled, enabled = pcall(function() return current.Enabled end)
        if okEnabled and enabled == false then return false end
        local okParent, parent = pcall(function() return current.Parent end)
        if not okParent then return true end
        current = parent
    end
    return true
end

local function guiText(instance)
    local ok, text = pcall(function() return instance.Text end)
    if ok and type(text) == 'string' then return text end
    local okContent, content = pcall(function() return instance.ContentText end)
    if okContent and type(content) == 'string' then return content end
    return nil
end

--- Absolute Y then X, so results read in roughly the order a person sees them.
local function guiScreenOrder(a, b)
    return (a.y == b.y) and (a.x < b.x) or (a.y < b.y)
end

local function guiPosition(instance)
    local ok, position = pcall(function() return instance.AbsolutePosition end)
    if ok and position then return position.X, position.Y end
    return 0, 0
end

handlers.find_gui_elements = function(args)
    local root = playerGuiRoot()
    if root == nil then
        return fail('INSTANCE_NOT_FOUND', 'There is no PlayerGui on this client.')
    end

    local query = args.query ~= nil and string.lower(tostring(args.query)) or nil
    local wantedText = args.text ~= nil and string.lower(tostring(args.text)) or nil
    local visibleOnly = args.visibleOnly ~= false
    local classFilter = type(args.classNames) == 'table' and args.classNames or {}
    local maxResults = math.min(math.max(tonumber(args.maxResults) or 50, 1), 200)

    if query == nil and wantedText == nil and #classFilter == 0 then
        return fail('INVALID_ARGUMENTS', 'Provide "query", "text" or "classNames" to search for.')
    end

    local okDescendants, descendants = pcall(function() return root:GetDescendants() end)
    if not okDescendants then
        return fail('INSTANCE_NOT_FOUND', 'The GUI tree could not be read.')
    end

    local matches = {}
    local truncated = false
    for index, instance in ipairs(descendants) do
        if index > LIMITS.maxScanNodes then
            truncated = true
            break
        end
        local okName, name = pcall(function() return instance.Name end)
        local text = guiText(instance)
        local nameHit = query ~= nil and okName
            and string.find(string.lower(name), query, 1, true) ~= nil
        local textHit = wantedText ~= nil and text ~= nil
            and string.find(string.lower(text), wantedText, 1, true) ~= nil
        local classHit = #classFilter > 0 and matchesClassFilter(instance, classFilter)

        local hit = nameHit or textHit or classHit
        -- With only a class filter given, the class alone decides.
        if #classFilter > 0 and not matchesClassFilter(instance, classFilter) then
            hit = false
        end

        if hit and (not visibleOnly or guiEffectivelyVisible(instance)) then
            local x, y = guiPosition(instance)
            table.insert(matches, {
                instance = summarize(instance),
                text = text,
                visible = guiEffectivelyVisible(instance),
                x = x,
                y = y,
            })
            if #matches >= maxResults then
                truncated = true
                break
            end
        end
    end

    table.sort(matches, guiScreenOrder)
    return { matches = matches, count = #matches, truncated = truncated }
end

handlers.get_screen_text = function(args)
    local root = playerGuiRoot()
    if root == nil then
        return fail('INSTANCE_NOT_FOUND', 'There is no PlayerGui on this client.')
    end

    local visibleOnly = args.visibleOnly ~= false
    local includeEmpty = args.includeEmpty == true
    local maxResults = math.min(math.max(tonumber(args.maxResults) or 150, 1), 400)

    local okDescendants, descendants = pcall(function() return root:GetDescendants() end)
    if not okDescendants then
        return fail('INSTANCE_NOT_FOUND', 'The GUI tree could not be read.')
    end

    local entries = {}
    local truncated = false
    for index, instance in ipairs(descendants) do
        if index > LIMITS.maxScanNodes then
            truncated = true
            break
        end
        local text = guiText(instance)
        if text ~= nil and (includeEmpty or text ~= '') then
            if not visibleOnly or guiEffectivelyVisible(instance) then
                local x, y = guiPosition(instance)
                table.insert(entries, {
                    text = text,
                    path = summarize(instance).displayPath,
                    ref = refFor(instance),
                    x = x,
                    y = y,
                })
                if #entries >= maxResults then
                    truncated = true
                    break
                end
            end
        end
    end

    table.sort(entries, guiScreenOrder)

    local lines = {}
    for _, entry in ipairs(entries) do
        table.insert(lines, entry.text)
    end

    return {
        entries = entries,
        count = #entries,
        truncated = truncated,
        -- The joined form is what an agent usually wants to read.
        text = table.concat(lines, '\n'),
        note = 'Clovyre cannot capture pixels. This is the text the GUI holds, in rough screen order.',
    }
end

handlers.get_gui_tree = function(args)
    local root
    if args.root ~= nil then
        local resolved, err = resolveTarget(args.root)
        if resolved == nil then
            return nil, { code = 'INSTANCE_NOT_FOUND', message = err }
        end
        root = resolved
    else
        local player = Players.LocalPlayer
        local okGui, playerGui = pcall(function()
            return player and player:FindFirstChildOfClass('PlayerGui') or nil
        end)
        root = okGui and playerGui or nil
        if root == nil then
            return fail('INSTANCE_NOT_FOUND', 'There is no PlayerGui on this client.')
        end
    end

    local maxDepth = math.min(math.max(tonumber(args.maxDepth) or 6, 1), 12)
    local maxNodes = math.min(math.max(tonumber(args.maxNodes) or 250, 1), 800)
    local visibleOnly = args.visibleOnly == true
    local includeText = args.includeText ~= false

    local nodes = 0
    local truncated = false

    -- Reads only the handful of GUI properties that answer layout questions,
    -- so a deep interface stays inside the payload limit.
    local function describe(instance)
        local node = {
            ref = refFor(instance),
            name = (pcall(function() return instance.Name end) and instance.Name) or '?',
            className = (pcall(function() return instance.ClassName end) and instance.ClassName) or '?',
        }

        pcall(function()
            if instance:IsA('GuiObject') then
                node.visible = instance.Visible
                node.zIndex = instance.ZIndex
                node.absolutePosition = { instance.AbsolutePosition.X, instance.AbsolutePosition.Y }
                node.absoluteSize = { instance.AbsoluteSize.X, instance.AbsoluteSize.Y }
                node.backgroundTransparency = instance.BackgroundTransparency
            elseif instance:IsA('ScreenGui') or instance:IsA('BillboardGui') or instance:IsA('SurfaceGui') then
                node.enabled = instance.Enabled
            end
        end)

        if includeText then
            pcall(function()
                if instance:IsA('TextLabel') or instance:IsA('TextButton') or instance:IsA('TextBox') then
                    node.text = truncateString(instance.Text)
                    node.textVisible = instance.TextTransparency < 1
                end
            end)
            pcall(function()
                if instance:IsA('ImageLabel') or instance:IsA('ImageButton') then
                    node.image = instance.Image
                end
            end)
        end

        return node
    end

    local function isHidden(instance)
        local okVisible, hidden = pcall(function()
            if instance:IsA('GuiObject') then return instance.Visible == false end
            if instance:IsA('ScreenGui') then return instance.Enabled == false end
            return false
        end)
        return okVisible and hidden or false
    end

    local function build(instance, depth)
        nodes = nodes + 1
        if nodes > maxNodes then
            truncated = true
            return nil
        end

        local node = describe(instance)
        if depth < maxDepth then
            local okChildren, children = pcall(function() return instance:GetChildren() end)
            if okChildren then
                local built = {}
                for _, child in ipairs(children) do
                    if not (visibleOnly and isHidden(child)) then
                        local childNode = build(child, depth + 1)
                        if childNode == nil then break end
                        table.insert(built, childNode)
                    end
                end
                if #built > 0 then
                    node.children = built
                end
            end
        end
        return node
    end

    local roots = {}
    if args.root == nil and args.includeCoreGui == true and API.gethui then
        local okHui, hui = pcall(API.gethui)
        if okHui and hui then
            table.insert(roots, hui)
        end
    end
    table.insert(roots, root)

    local trees = {}
    for _, entry in ipairs(roots) do
        local tree = build(entry, 0)
        if tree then table.insert(trees, tree) end
    end

    return {
        roots = trees,
        nodeCount = nodes,
        truncated = truncated,
        visibleOnly = visibleOnly,
        note = 'Only GUI replicated to this client is visible. CoreGui is excluded unless requested and supported.',
    }
end

--------------------------------------------------------------------------------
-- Watchers
--------------------------------------------------------------------------------

local watches = {}
local watchCounter = 0

local function pushEvent(eventName, data)
    sendRaw({ protocolVersion = PROTOCOL_VERSION, type = 'event', event = eventName, data = data })
end

local function reportWatchState()
    local list = {}
    for watchId, watch in pairs(watches) do
        table.insert(list, { watchId = watchId, target = watch.target, kinds = watch.kinds })
    end
    pushEvent('watch_state', { watches = list })
end

local function stopWatch(watchId)
    local watch = watches[watchId]
    if not watch then return false end
    for _, connection in ipairs(watch.connections) do
        pcall(function() connection:Disconnect() end)
    end
    watches[watchId] = nil
    return true
end

--- Blocks the calling coroutine until `predicate` returns true or time runs out.
--- Polling only happens as a fallback for conditions with no signal; the signal
--- path resumes immediately, which is the whole point of the tool.
local function awaitSignal(signal, timeoutSeconds, onFire)
    local finished = false
    local outcome = nil
    local connection

    if signal ~= nil then
        local okConnect, connected = pcall(function()
            return signal:Connect(function(...)
                if finished then return end
                local produced = onFire(...)
                if produced ~= nil then
                    outcome = produced
                    finished = true
                end
            end)
        end)
        connection = okConnect and connected or nil
    end

    local deadline = os.clock() + timeoutSeconds
    while not finished and os.clock() < deadline do
        RunService.Heartbeat:Wait()
    end

    if connection ~= nil then
        pcall(function() connection:Disconnect() end)
    end
    return outcome
end

handlers.wait_for = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local condition = tostring(args.condition or 'propertyChanged')
    local timeoutSeconds = math.min(math.max(tonumber(args.timeoutSeconds) or 10, 1), 25)
    local startedAt = os.clock()

    local function elapsed()
        return os.clock() - startedAt
    end

    if condition == 'propertyChanged' then
        local property = args.property
        if type(property) ~= 'string' or property == '' then
            return fail('INVALID_ARGUMENTS', 'Waiting on a property requires a "property" name.')
        end
        if not isSafeProperty(instance, property) then
            return fail(
                'PROPERTY_NOT_ALLOWED',
                'Property "' .. property .. '" is not in the Clovyre safe-property registry for this class.'
            )
        end

        local function currentValue()
            local ok, value = pcall(function() return instance[property] end)
            return ok and serialize(value) or nil
        end

        local before = currentValue()

        -- When a specific value is requested and it is already set, the wait is
        -- already satisfied; blocking for a change that happened before the call
        -- would be a bug, not a wait.
        if args.hasEquals == true and propertyMatches(before, 'equals', args.equals) then
            return {
                timedOut = false,
                condition = condition,
                instance = summarize(instance),
                property = property,
                value = before,
                waitedSeconds = 0,
                note = 'The property already held the requested value.',
            }
        end

        local okSignal, signal = pcall(function()
            return instance:GetPropertyChangedSignal(property)
        end)

        local result = awaitSignal(okSignal and signal or nil, timeoutSeconds, function()
            local value = currentValue()
            if args.hasEquals == true and not propertyMatches(value, 'equals', args.equals) then
                return nil
            end
            return { value = value }
        end)

        if result == nil then
            return {
                timedOut = true,
                condition = condition,
                instance = summarize(instance),
                property = property,
                value = currentValue(),
                previousValue = before,
                waitedSeconds = elapsed(),
            }
        end
        return {
            timedOut = false,
            condition = condition,
            instance = summarize(instance),
            property = property,
            previousValue = before,
            value = result.value,
            waitedSeconds = elapsed(),
        }
    elseif condition == 'childAdded' then
        local wantedName = args.childName ~= nil and tostring(args.childName) or nil

        if wantedName ~= nil then
            local okExisting, existing = pcall(function()
                return instance:FindFirstChild(wantedName)
            end)
            if okExisting and existing ~= nil then
                return {
                    timedOut = false,
                    condition = condition,
                    instance = summarize(instance),
                    child = summarize(existing),
                    waitedSeconds = 0,
                    note = 'A child with that name was already present.',
                }
            end
        end

        local okSignal, signal = pcall(function() return instance.ChildAdded end)
        local result = awaitSignal(okSignal and signal or nil, timeoutSeconds, function(child)
            if child == nil then return nil end
            if wantedName ~= nil then
                local okName, name = pcall(function() return child.Name end)
                if not okName or name ~= wantedName then return nil end
            end
            return { child = summarize(child) }
        end)

        if result == nil then
            return {
                timedOut = true,
                condition = condition,
                instance = summarize(instance),
                waitedSeconds = elapsed(),
            }
        end
        return {
            timedOut = false,
            condition = condition,
            instance = summarize(instance),
            child = result.child,
            waitedSeconds = elapsed(),
        }
    elseif condition == 'attributeChanged' then
        local attribute = args.attribute
        if type(attribute) ~= 'string' or attribute == '' then
            return fail('INVALID_ARGUMENTS', 'Waiting on an attribute requires an "attribute" name.')
        end

        local function currentAttribute()
            local ok, value = pcall(function() return instance:GetAttribute(attribute) end)
            return ok and serialize(value) or nil
        end

        local before = currentAttribute()
        if args.hasEquals == true and propertyMatches(before, 'equals', args.equals) then
            return {
                timedOut = false,
                condition = condition,
                instance = summarize(instance),
                attribute = attribute,
                value = before,
                waitedSeconds = 0,
                note = 'The attribute already held the requested value.',
            }
        end

        local okSignal, signal = pcall(function()
            return instance:GetAttributeChangedSignal(attribute)
        end)

        local result = awaitSignal(okSignal and signal or nil, timeoutSeconds, function()
            local value = currentAttribute()
            if args.hasEquals == true and not propertyMatches(value, 'equals', args.equals) then
                return nil
            end
            return { value = value }
        end)

        if result == nil then
            return {
                timedOut = true,
                condition = condition,
                instance = summarize(instance),
                attribute = attribute,
                value = currentAttribute(),
                previousValue = before,
                waitedSeconds = elapsed(),
            }
        end
        return {
            timedOut = false,
            condition = condition,
            instance = summarize(instance),
            attribute = attribute,
            previousValue = before,
            value = result.value,
            waitedSeconds = elapsed(),
        }
    end

    return fail('INVALID_ARGUMENTS', 'Unknown wait condition "' .. condition .. '".')
end

handlers.watch_start = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local count = 0
    for _ in pairs(watches) do count = count + 1 end
    if count >= 32 then
        return fail('RATE_LIMITED', 'At most 32 watchers may be active at once. Stop one first.')
    end

    local kinds = args.kinds
    if type(kinds) ~= 'table' or #kinds == 0 then kinds = { 'property' } end

    local property = args.property
    local attribute = args.attribute
    local _, displayPath = pathOf(instance)

    watchCounter = watchCounter + 1
    local watchId = 'w' .. tostring(watchCounter)
    local connections = {}

    for _, kind in ipairs(kinds) do
        if kind == 'property' then
            if type(property) ~= 'string' or property == '' then
                return fail('INVALID_ARGUMENTS', 'Watching a property requires a "property" name.')
            end
            if not isSafeProperty(instance, property) then
                return fail(
                    'PROPERTY_NOT_ALLOWED',
                    'Property "' .. property .. '" is not in the Clovyre safe-property registry for this class.'
                )
            end
            local okSignal, signal = pcall(function()
                return instance:GetPropertyChangedSignal(property)
            end)
            if okSignal and signal then
                table.insert(connections, signal:Connect(function()
                    local okValue, value = pcall(function() return instance[property] end)
                    pushEvent('watch', {
                        watchId = watchId,
                        kind = 'property',
                        target = displayPath,
                        at = os.time(),
                        detail = { property = property, value = okValue and serialize(value) or nil },
                    })
                end))
            end
        elseif kind == 'attribute' then
            local okSignal, signal = pcall(function()
                if type(attribute) == 'string' and attribute ~= '' then
                    return instance:GetAttributeChangedSignal(attribute)
                end
                return instance.AttributeChanged
            end)
            if okSignal and signal then
                table.insert(connections, signal:Connect(function(changedName)
                    local key = changedName or attribute
                    local okValue, value = pcall(function() return instance:GetAttribute(key) end)
                    pushEvent('watch', {
                        watchId = watchId,
                        kind = 'attribute',
                        target = displayPath,
                        at = os.time(),
                        detail = { attribute = key, value = okValue and serialize(value) or nil },
                    })
                end))
            end
        elseif kind == 'childAdded' then
            table.insert(connections, instance.ChildAdded:Connect(function(child)
                pushEvent('watch', {
                    watchId = watchId,
                    kind = 'childAdded',
                    target = displayPath,
                    at = os.time(),
                    detail = { child = summarize(child) },
                })
            end))
        elseif kind == 'childRemoved' then
            table.insert(connections, instance.ChildRemoved:Connect(function(child)
                local okName, name = pcall(function() return child.Name end)
                pushEvent('watch', {
                    watchId = watchId,
                    kind = 'childRemoved',
                    target = displayPath,
                    at = os.time(),
                    detail = { name = okName and name or '?' },
                })
            end))
        end
    end

    if #connections == 0 then
        return fail('INVALID_ARGUMENTS', 'None of the requested watch kinds could be connected on this instance.')
    end

    watches[watchId] = {
        target = displayPath,
        kinds = kinds,
        connections = connections,
        label = args.label,
    }
    reportWatchState()

    return {
        watchId = watchId,
        target = displayPath,
        kinds = kinds,
        connected = #connections,
        note = 'Changes are buffered on the Clovyre server. Poll clovyre_get_watch_events to read them.',
    }
end

handlers.watch_stop = function(args)
    if args.all == true then
        local stopped = 0
        for watchId in pairs(watches) do
            if stopWatch(watchId) then stopped = stopped + 1 end
        end
        reportWatchState()
        return { stopped = stopped, all = true }
    end

    local watchId = tostring(args.watchId or '')
    local stopped = stopWatch(watchId)
    reportWatchState()
    if not stopped then
        return fail('INVALID_ARGUMENTS', 'No watcher with id "' .. watchId .. '" is active.')
    end
    return { stopped = 1, watchId = watchId }
end

--------------------------------------------------------------------------------
-- Remote spy
--------------------------------------------------------------------------------
-- Observation only. There is deliberately no handler that FIRES a remote: this
-- reports what the client already sends, and adds no capability to send more.

local remoteSpy = {
    active = false,
    original = nil,
    nameFilter = nil,
    includeArguments = true,
    maxArgumentBytes = 2000,
    captureStack = true,
}

--------------------------------------------------------------------------------
-- Call-site attribution
--------------------------------------------------------------------------------

--- This chunk's own source name, so the bridge can skip its own stack frames.
local OWN_SOURCE = nil
do
    local ok, source = pcall(function() return debug.info(1, 's') end)
    OWN_SOURCE = ok and source or nil
end

--- True when debug.info is usable on this executor.
local function hasDebugInfo()
    return type(debug) == 'table' and type(debug.info) == 'function'
end

--[[
    Walks the Luau call stack and reports who actually made the call.

    getcallingscript() names the script but not the place inside it, which is the
    part that matters when one script fires the same remote from a dozen sites.
    debug.info gives source, line and function name per level, so the stack is
    walked from just above the hook until a frame appears that is not this
    bridge's own code -- that frame is the real caller.

    Everything is wrapped in pcall: debug.info is restricted or absent on some
    executors, and losing attribution must never cost the observation itself.
--]]
local function captureCallSite(maxFrames)
    maxFrames = math.min(math.max(maxFrames or 8, 1), 24)
    if not hasDebugInfo() then
        return nil, {}
    end

    local frames = {}
    local primary = nil

    for level = 2, 28 do
        local ok, source, line, name = pcall(function()
            return debug.info(level, 'sln')
        end)
        if not ok or source == nil then
            break
        end
        if OWN_SOURCE == nil or source ~= OWN_SOURCE then
            local frame = {
                source = source,
                line = (type(line) == 'number' and line >= 0) and line or nil,
                name = (type(name) == 'string' and name ~= '') and name or nil,
            }
            table.insert(frames, frame)
            if primary == nil then
                primary = frame
            end
            if #frames >= maxFrames then
                break
            end
        end
    end

    return primary, frames
end

--[[
    Remembers where an observed call came from, so its code can be fetched later.

    Only a bounded window is kept. Holding every call site would pin script
    instances in memory for the life of the session, and the interesting call is
    almost always a recent one.
--]]
local CALL_SITE_LIMIT = 300
local callSites = {}
local callSiteOrder = {}
local callSiteCounter = 0

local function rememberCallSite(entry)
    callSiteCounter = callSiteCounter + 1
    local callId = 'rc' .. tostring(callSiteCounter)
    callSites[callId] = entry
    table.insert(callSiteOrder, callId)
    if #callSiteOrder > CALL_SITE_LIMIT then
        local oldest = table.remove(callSiteOrder, 1)
        callSites[oldest] = nil
    end
    return callId
end

local function forgetCallSites()
    callSites = {}
    callSiteOrder = {}
end

handlers.remote_spy_start = function(args)
    if not (API.hookmetamethod and API.getnamecallmethod) then
        return fail(
            'CAPABILITY_UNAVAILABLE',
            'This executor does not expose hookmetamethod and getnamecallmethod, which the remote spy needs.'
        )
    end
    if remoteSpy.active then
        return { active = true, alreadyRunning = true, note = 'The remote spy is already running.' }
    end

    remoteSpy.includeArguments = args.includeArguments ~= false
    remoteSpy.nameFilter = (type(args.nameFilter) == 'string' and args.nameFilter ~= '')
        and string.lower(args.nameFilter) or nil
    remoteSpy.maxArgumentBytes = math.min(math.max(tonumber(args.maxArgumentBytes) or 2000, 64), 20000)
    remoteSpy.captureStack = args.captureStack ~= false
    -- Ids are only meaningful within one run of the spy.
    forgetCallSites()

    local okHook, hookError = pcall(function()
        remoteSpy.original = API.hookmetamethod(game, '__namecall', function(self, ...)
            local method = API.getnamecallmethod()

            if remoteSpy.active and (method == 'FireServer' or method == 'InvokeServer') then
                local okClass, className = pcall(function() return self.ClassName end)
                if okClass and (className == 'RemoteEvent' or className == 'RemoteFunction'
                    or className == 'UnreliableRemoteEvent') then
                    local _, display = pathOf(self)
                    local include = true
                    if remoteSpy.nameFilter then
                        include = string.find(string.lower(display), remoteSpy.nameFilter, 1, true) ~= nil
                    end

                    if include then
                        local packed = table.pack(...)
                        local serializedArgs = nil
                        local truncated = false

                        if remoteSpy.includeArguments then
                            local list = {}
                            for index = 1, packed.n do
                                table.insert(list, serialize(packed[index]))
                            end
                            local okEncode, encoded = pcall(function()
                                return HttpService:JSONEncode(list)
                            end)
                            if okEncode and #encoded > remoteSpy.maxArgumentBytes then
                                truncated = true
                                list = { { __t = 'Truncated', reason = 'argument-size', bytes = #encoded } }
                            end
                            serializedArgs = list
                        end

                        local callerScript = nil
                        local callerInstance = nil
                        if API.getcallingscript then
                            local okCaller, caller = pcall(API.getcallingscript)
                            if okCaller and caller then
                                callerInstance = caller
                                local _, callerPath = pathOf(caller)
                                callerScript = callerPath
                            end
                        end

                        -- Attribution runs inside the hook because the stack only
                        -- exists here; it is deliberately cheap and never throws.
                        local primary, frames = nil, {}
                        if remoteSpy.captureStack then
                            primary, frames = captureCallSite(8)
                        end

                        local callId = rememberCallSite({
                            script = callerInstance,
                            scriptPath = callerScript,
                            source = primary and primary.source or nil,
                            line = primary and primary.line or nil,
                            functionName = primary and primary.name or nil,
                            remote = display,
                            method = method,
                            at = os.time(),
                        })

                        -- Never block or alter the call being observed.
                        task.spawn(function()
                            pushEvent('remote_call', {
                                callId = callId,
                                remote = display,
                                className = className,
                                method = method,
                                args = serializedArgs,
                                argCount = packed.n,
                                callerScript = callerScript,
                                callerSource = primary and primary.source or nil,
                                callerLine = primary and primary.line or nil,
                                callerFunction = primary and primary.name or nil,
                                stack = frames,
                                truncated = truncated,
                                at = os.time(),
                            })
                        end)
                    end
                end
            end

            return remoteSpy.original(self, ...)
        end)
    end)

    if not okHook then
        return fail('INTERNAL_ERROR', 'The remote spy hook could not be installed: ' .. tostring(hookError))
    end

    remoteSpy.active = true
    pushEvent('remote_spy_state', { active = true })

    return {
        active = true,
        includeArguments = remoteSpy.includeArguments,
        nameFilter = args.nameFilter,
        note = 'Observing outgoing FireServer and InvokeServer calls. Clovyre cannot fire remotes.',
    }
end

--[[
    Returns the code around a recorded call site.

    Two ways in: a callId from clovyre_get_remote_calls, or an explicit script
    plus line. The source comes from the Source property when the client owns the
    script and from the decompiler otherwise, and the result always says which --
    decompiled output is a best-effort reconstruction, not the original text, and
    reading it as though it were the original is how people draw wrong conclusions.
--]]
handlers.get_calling_code = function(args)
    local contextLines = math.min(math.max(tonumber(args.contextLines) or 20, 0), 200)
    local maxBytes = math.min(math.max(tonumber(args.maxBytes) or 60000, 1024), LIMITS.maxSourceBytes)

    local instance = nil
    local line = tonumber(args.line)
    local site = nil

    if args.callId ~= nil then
        site = callSites[tostring(args.callId)]
        if site == nil then
            return fail(
                'INSTANCE_NOT_FOUND',
                'That callId is not in the client\'s call-site window. Only the most recent '
                    .. tostring(CALL_SITE_LIMIT) .. ' observed calls keep their origin.'
            )
        end
        instance = site.script
        line = line or site.line
    else
        local resolved, err = requireTarget(args)
        if not resolved then return nil, err end
        instance = resolved
    end

    if instance == nil then
        return {
            resolved = false,
            callId = args.callId,
            callSite = site and {
                remote = site.remote,
                method = site.method,
                source = site.source,
                line = site.line,
                functionName = site.functionName,
                scriptPath = site.scriptPath,
            } or nil,
            note = 'The call was attributed to a chunk with no script instance behind it, '
                .. 'which usually means the caller was executor code rather than a game script.',
        }
    end

    local read = readScriptSource(instance, maxBytes)

    local result = {
        resolved = true,
        callId = args.callId,
        instance = summarize(instance),
        representation = read.representation,
        truncated = read.truncated,
        totalBytes = read.totalBytes,
        note = read.note,
        line = line,
        callSite = site and {
            remote = site.remote,
            method = site.method,
            source = site.source,
            line = site.line,
            functionName = site.functionName,
        } or nil,
    }

    if type(read.source) ~= 'string' then
        result.available = false
        result.reason = 'No readable source: the Source property is empty and no decompiler is available.'
        return result
    end

    -- Split into lines so a window can be taken around the call.
    local lines = {}
    for text in string.gmatch(read.source .. '\n', '(.-)\n') do
        table.insert(lines, text)
    end
    result.available = true
    result.lineCount = #lines

    if line == nil or contextLines == 0 then
        result.source = read.source
        result.window = nil
        if line == nil then
            result.note = (result.note or '') .. ' No line number was attributed, so the whole script is returned.'
        end
        return result
    end

    local from = math.max(1, line - contextLines)
    local to = math.min(#lines, line + contextLines)
    local window = {}
    for index = from, to do
        table.insert(window, {
            line = index,
            text = lines[index],
            isCallSite = index == line,
        })
    end

    result.window = window
    result.windowFrom = from
    result.windowTo = to
    -- A decompiled line number rarely lines up with the original, so say so
    -- rather than letting the caret imply a precision that is not there.
    if read.representation == 'decompiled' then
        result.lineAccuracy = 'approximate'
        result.note = (result.note or '')
            .. ' Line numbers come from the running bytecode, so they point into the decompiled '
            .. 'text only approximately.'
    else
        result.lineAccuracy = 'exact'
    end
    return result
end

handlers.remote_spy_stop = function()
    if not remoteSpy.active then
        return { active = false, note = 'The remote spy was not running.' }
    end
    -- The hook stays installed (unhooking a metamethod is not reliably supported
    -- across executors) but it stops recording and simply forwards every call.
    remoteSpy.active = false
    pushEvent('remote_spy_state', { active = false })
    return {
        active = false,
        note = 'Recording stopped. Buffered calls remain readable with clovyre_get_remote_calls.',
    }
end

--------------------------------------------------------------------------------
-- Privileged handlers
--------------------------------------------------------------------------------

local executeInFlight = false

handlers.execute_luau = function(args)
    if not API.loadstring then
        return fail(
            'CAPABILITY_UNAVAILABLE',
            'This executor exposes neither loadstring nor load, so Clovyre cannot compile Luau at runtime.'
        )
    end
    if executeInFlight then
        return fail('RATE_LIMITED', 'Another Luau execution is already running on this client.')
    end

    local code = tostring(args.code or '')
    if #code == 0 then
        return fail('INVALID_ARGUMENTS', 'No code was supplied.')
    end
    if #code > 20000 then
        return fail('INVALID_ARGUMENTS', 'The chunk exceeds the 20000 character limit.')
    end

    executeInFlight = true

    local chunk, compileError = API.loadstring(code, '=clovyre_execute')
    if not chunk then
        executeInFlight = false
        return {
            ok = false,
            phase = 'compile',
            error = truncateString(tostring(compileError or 'The chunk failed to compile.')),
        }
    end

    -- The chunk runs in the executor's own environment. This is not a sandbox;
    -- the toggle only controls whether Clovyre hands over its resolved globals.
    if args.exposeExecutorGlobals ~= true and typeof(setfenv) == 'function' then
        local restricted = setmetatable({}, { __index = function(_, key)
            local blocked = {
                getgenv = true, syn = true, hookfunction = true, hookmetamethod = true,
                getrawmetatable = true, setreadonly = true, getgc = true, getloadedmodules = true,
                decompile = true, getscriptbytecode = true, getsenv = true, getconnections = true,
            }
            if blocked[key] then
                return nil
            end
            return (getfenv and getfenv(0) or _G)[key]
        end })
        pcall(setfenv, chunk, restricted)
    end

    local startClock = os.clock()
    local results = table.pack(pcall(chunk))
    local durationMs = math.floor((os.clock() - startClock) * 1000)
    executeInFlight = false

    if not results[1] then
        local message = tostring(results[2] or 'The chunk raised an error.')
        return {
            ok = false,
            phase = 'runtime',
            error = truncateString(message),
            traceback = (debug and debug.traceback) and truncateString(tostring(debug.traceback())) or nil,
            durationMs = durationMs,
        }
    end

    if args.resultMode == 'summary' then
        local summary = {}
        for index = 2, results.n do
            table.insert(summary, typeof(results[index]))
        end
        return { ok = true, returnTypes = summary, returnCount = results.n - 1, durationMs = durationMs }
    end

    local returned = {}
    for index = 2, results.n do
        table.insert(returned, serialize(results[index]))
    end
    return {
        ok = true,
        returned = returned,
        returnCount = results.n - 1,
        durationMs = durationMs,
        environmentNote = args.exposeExecutorGlobals == true
            and 'Executor globals were exposed to this chunk.'
            or 'Clovyre masked well-known executor globals for this chunk. This is a convenience filter, not a sandbox.',
    }
end

--- Converts a JSON-tagged value back into a Luau value for mutation tools.
local function deserializeValue(value)
    if type(value) ~= 'table' then
        return value
    end
    local tag = value.__t
    if tag == nil then
        return value
    end
    if tag == 'Vector3' then return Vector3.new(value.x, value.y, value.z) end
    if tag == 'Vector2' then return Vector2.new(value.x, value.y) end
    if tag == 'Color3' then return Color3.new(value.r, value.g, value.b) end
    if tag == 'UDim' then return UDim.new(value.scale, value.offset) end
    if tag == 'UDim2' then return UDim2.new(value.xScale, value.xOffset, value.yScale, value.yOffset) end
    if tag == 'NumberRange' then return NumberRange.new(value.min, value.max) end
    if tag == 'BrickColor' then return BrickColor.new(value.name) end
    if tag == 'CFrame' and type(value.components) == 'table' then
        return CFrame.new(table.unpack(value.components))
    end
    if tag == 'EnumItem' then
        local ok, enumItem = pcall(function()
            return Enum[value.enumType][value.name]
        end)
        if ok then return enumItem end
    end
    if tag == 'Instance' and type(value.ref) == 'string' then
        return instanceForRef(value.ref)
    end
    return nil
end

handlers.set_property = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local property = tostring(args.property or '')
    if not isSafeProperty(instance, property) then
        return fail('PROPERTY_NOT_ALLOWED', 'Property "' .. property .. '" is not writable through Clovyre.')
    end

    local previousOk, previous = pcall(function() return instance[property] end)
    local newValue = deserializeValue(args.value)

    local ok, writeError = pcall(function()
        instance[property] = newValue
    end)
    if not ok then
        return fail('INTERNAL_ERROR', 'The property could not be written: ' .. tostring(writeError))
    end

    return {
        instance = summarize(instance),
        property = property,
        previous = previousOk and serialize(previous) or nil,
        current = serialize(instance[property]),
        note = 'This changed local client state only. The Roblox server remains authoritative.',
    }
end

handlers.set_properties = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local requested = type(args.properties) == 'table' and args.properties or {}
    if #requested == 0 then
        return fail('INVALID_ARGUMENTS', 'No properties were supplied.')
    end

    -- Each write reports its own outcome. One rejected property should not throw
    -- away the writes that did land, and the caller needs to know which is which.
    local results = {}
    local written, failed = 0, 0

    for _, entry in ipairs(requested) do
        local property = tostring(entry.property or '')
        if not isSafeProperty(instance, property) then
            failed = failed + 1
            table.insert(results, {
                property = property,
                ok = false,
                code = 'PROPERTY_NOT_ALLOWED',
                message = 'Property "' .. property .. '" is not writable through Clovyre.',
            })
        else
            local previousOk, previous = pcall(function() return instance[property] end)
            local ok, writeError = pcall(function()
                instance[property] = deserializeValue(entry.value)
            end)
            if ok then
                written = written + 1
                local currentOk, current = pcall(function() return instance[property] end)
                table.insert(results, {
                    property = property,
                    ok = true,
                    previous = previousOk and serialize(previous) or nil,
                    current = currentOk and serialize(current) or nil,
                })
            else
                failed = failed + 1
                table.insert(results, {
                    property = property,
                    ok = false,
                    code = 'INTERNAL_ERROR',
                    message = tostring(writeError),
                })
            end
        end
    end

    return {
        instance = summarize(instance),
        results = results,
        written = written,
        failed = failed,
        note = 'This changed local client state only. The Roblox server remains authoritative.',
    }
end

handlers.clone_instance = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local okArchivable, archivable = pcall(function() return instance.Archivable end)
    if okArchivable and archivable == false then
        return fail(
            'INVALID_ARGUMENTS',
            'This instance has Archivable false, so Roblox will not clone it.'
        )
    end

    local parent = nil
    if args.parentRef ~= nil or args.parentPath ~= nil then
        parent = resolveTarget({ ref = args.parentRef, displayPath = args.parentPath })
        if parent == nil then
            return fail('INSTANCE_NOT_FOUND', 'The requested parent could not be resolved.')
        end
    else
        local okParent, existing = pcall(function() return instance.Parent end)
        parent = okParent and existing or nil
    end

    local okClone, clone = pcall(function() return instance:Clone() end)
    if not okClone or clone == nil then
        return fail('INTERNAL_ERROR', 'The instance could not be cloned.')
    end

    if args.name ~= nil then
        pcall(function() clone.Name = tostring(args.name) end)
    end

    local okParented, parentError = pcall(function() clone.Parent = parent end)
    if not okParented then
        pcall(function() clone:Destroy() end)
        return fail('INTERNAL_ERROR', 'The clone could not be parented: ' .. tostring(parentError))
    end

    return {
        source = summarize(instance),
        clone = summarize(clone),
        parent = parent and summarize(parent) or nil,
        note = 'The copy exists on this client only. The Roblox server knows nothing about it.',
    }
end

handlers.set_tag = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local tag = tostring(args.tag or '')
    if tag == '' then
        return fail('INVALID_ARGUMENTS', 'A tag name is required.')
    end

    local add = args.add ~= false
    local ok, tagError = pcall(function()
        if add then
            CollectionService:AddTag(instance, tag)
        else
            CollectionService:RemoveTag(instance, tag)
        end
    end)
    if not ok then
        return fail('INTERNAL_ERROR', 'The tag could not be changed: ' .. tostring(tagError))
    end

    local okTags, tags = pcall(function() return CollectionService:GetTags(instance) end)
    return {
        instance = summarize(instance),
        tag = tag,
        added = add,
        tags = okTags and tags or nil,
        note = 'Tags set here exist on this client only.',
    }
end

handlers.set_camera = function(args)
    local camera = currentCamera()
    if camera == nil then
        return fail('INSTANCE_NOT_FOUND', 'This client has no current camera.')
    end

    local changed = {}

    if args.cameraType ~= nil then
        local ok = pcall(function()
            camera.CameraType = Enum.CameraType[tostring(args.cameraType)]
        end)
        if ok then table.insert(changed, 'CameraType') end
    end

    if args.fieldOfView ~= nil then
        local ok = pcall(function() camera.FieldOfView = tonumber(args.fieldOfView) end)
        if ok then table.insert(changed, 'FieldOfView') end
    end

    local targetPosition = nil
    if args.lookAtRef ~= nil or args.lookAtPath ~= nil then
        local target = resolveTarget({ ref = args.lookAtRef, displayPath = args.lookAtPath })
        if target == nil then
            return fail('INSTANCE_NOT_FOUND', 'The instance to look at could not be resolved.')
        end
        local okPosition, position = pcall(function() return target.Position end)
        if not okPosition or typeof(position) ~= 'Vector3' then
            return fail('INVALID_ARGUMENTS', 'That instance has no position to look at.')
        end
        targetPosition = position
    elseif type(args.lookAt) == 'table' and #args.lookAt >= 3 then
        targetPosition = Vector3.new(args.lookAt[1], args.lookAt[2], args.lookAt[3])
    end

    local originPosition = nil
    if type(args.position) == 'table' and #args.position >= 3 then
        originPosition = Vector3.new(args.position[1], args.position[2], args.position[3])
    end

    if originPosition ~= nil or targetPosition ~= nil then
        local from = originPosition or camera.CFrame.Position
        local ok = pcall(function()
            if targetPosition ~= nil then
                camera.CFrame = CFrame.new(from, targetPosition)
            else
                camera.CFrame = CFrame.new(from) * (camera.CFrame - camera.CFrame.Position)
            end
        end)
        if ok then table.insert(changed, 'CFrame') end
    end

    if #changed == 0 then
        return fail('INVALID_ARGUMENTS', 'Nothing to change: supply a position, a look target, a field of view or a camera type.')
    end

    return {
        camera = summarize(camera),
        changed = changed,
        cframe = serialize(camera.CFrame),
        fieldOfView = camera.FieldOfView,
        cameraType = tostring(camera.CameraType),
        note = 'The camera is local. A game with its own camera script will usually take control back on the next frame.',
    }
end

handlers.set_attribute = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local attribute = tostring(args.attribute or '')
    local ok, writeError = pcall(function()
        instance:SetAttribute(attribute, deserializeValue(args.value))
    end)
    if not ok then
        return fail('INTERNAL_ERROR', 'The attribute could not be written: ' .. tostring(writeError))
    end

    return {
        instance = summarize(instance),
        attribute = attribute,
        current = serialize(instance:GetAttribute(attribute)),
        note = 'This changed local client state only. The Roblox server remains authoritative.',
    }
end

handlers.create_instance = function(args)
    local parent, err = resolveTarget(args.parent)
    if parent == nil then
        return fail('INSTANCE_NOT_FOUND', err or 'The parent instance was not found.')
    end

    local ok, created = pcall(function()
        local instance = Instance.new(tostring(args.className))
        if type(args.name) == 'string' and args.name ~= '' then
            instance.Name = args.name
        end
        instance.Parent = parent
        return instance
    end)
    if not ok then
        return fail('INVALID_ARGUMENTS', 'The instance could not be created: ' .. tostring(created))
    end

    return {
        created = summarize(created),
        parent = summarize(parent),
        note = 'Created on this client only. It does not exist on the Roblox server.',
    }
end

handlers.destroy_instance = function(args)
    local instance, err = requireTarget(args)
    if not instance then return nil, err end

    local snapshot = summarize(instance)
    local ok, destroyError = pcall(function() instance:Destroy() end)
    if not ok then
        return fail('INTERNAL_ERROR', 'The instance could not be destroyed: ' .. tostring(destroyError))
    end

    return {
        destroyed = snapshot,
        note = 'Destroyed on this client only, and irreversible for this session. The server is unaffected.',
    }
end

handlers.reparent_instance = function(args)
    local instance, instanceError = resolveTarget(args.instance)
    if instance == nil then
        return fail('INSTANCE_NOT_FOUND', instanceError or 'The instance was not found.')
    end
    local newParent, parentError = resolveTarget(args.newParent)
    if newParent == nil then
        return fail('INSTANCE_NOT_FOUND', parentError or 'The new parent was not found.')
    end

    local previousParent = instance.Parent
    local ok, writeError = pcall(function() instance.Parent = newParent end)
    if not ok then
        return fail('INTERNAL_ERROR', 'The instance could not be reparented: ' .. tostring(writeError))
    end

    return {
        instance = summarize(instance),
        previousParent = previousParent and summarize(previousParent) or nil,
        newParent = summarize(newParent),
        note = 'Reparented on this client only. The Roblox server remains authoritative.',
    }
end

--------------------------------------------------------------------------------
-- Connection
--------------------------------------------------------------------------------

-- Tear down a previous run before starting a new one.
if type(genv.ClovyreDisconnect) == 'function' then
    pcall(genv.ClovyreDisconnect)
    task.wait(0.2)
end

local bridge = {
    socket = nil,
    connected = false,
    stopped = false,
    generation = (genv.__ClovyreGeneration or 0) + 1,
    cancelled = {},
    heartbeatThread = nil,
    clientId = nil,
    clientLabel = nil,
}

--- Stable identity for this executor, kept in getgenv so it survives re-running
--- the script. The server hashes it into a client id: the same key reclaims the
--- same slot (re-running replaces one connection rather than stacking another),
--- while a second person on another machine brings a different key and joins the
--- session as an additional client instead of evicting the first.
local function getClientKey()
    local existing = genv.__ClovyreClientKey
    if type(existing) == 'string' and #existing >= 8 then
        return existing
    end
    local ok, generated = pcall(function()
        return HttpService:GenerateGUID(false)
    end)
    if not ok or type(generated) ~= 'string' or #generated < 8 then
        -- GenerateGUID is the good path; this is only so a stripped HttpService
        -- still yields something stable for the life of the executor session.
        generated = string.format('%d-%d', os.time(), math.random(1, 1e9))
    end
    genv.__ClovyreClientKey = generated
    return generated
end
genv.__ClovyreGeneration = bridge.generation

local function isCurrentGeneration()
    return genv.__ClovyreGeneration == bridge.generation and not bridge.stopped
end

sendRaw = function(payload)
    if not bridge.connected or bridge.socket == nil then
        return false
    end
    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(payload)
    end)
    if not ok then
        warnLog('A message could not be encoded and was dropped.')
        return false
    end
    if #encoded > LIMITS.maxPayloadBytes then
        return false, encoded
    end
    local sent = pcall(function()
        bridge.socket:Send(encoded)
    end)
    return sent
end

local function sendResult(id, ok, payload, errorPayload, durationMs, truncated)
    local message = {
        protocolVersion = PROTOCOL_VERSION,
        type = 'result',
        id = id,
        ok = ok,
        durationMs = durationMs,
        truncated = truncated or false,
    }
    if ok then
        message.result = payload
    else
        message.error = errorPayload
    end

    local delivered, encoded = sendRaw(message)
    if not delivered and encoded then
        -- The payload was too large; answer with a structured error instead of
        -- letting the command time out silently.
        sendRaw({
            protocolVersion = PROTOCOL_VERSION,
            type = 'result',
            id = id,
            ok = false,
            error = {
                code = 'PAYLOAD_TOO_LARGE',
                message = 'The result was ' .. tostring(#encoded)
                    .. ' bytes, over the ' .. tostring(LIMITS.maxPayloadBytes)
                    .. ' byte limit. Narrow the request with lower limits or a more specific target.',
            },
        })
    end
end

local function dispatchCommand(message)
    local toolName = tostring(message.tool or '')
    local shortName = string.gsub(toolName, '^clovyre_', '')
    local handler = handlers[shortName]

    if handler == nil then
        sendResult(message.id, false, nil, {
            code = 'INVALID_ARGUMENTS',
            message = 'This Clovyre bridge does not implement "' .. toolName .. '".',
        }, 0)
        return
    end

    task.spawn(function()
        local startClock = os.clock()
        local ok, result, handlerError = pcall(handler, message.arguments or {})
        local durationMs = math.floor((os.clock() - startClock) * 1000)

        if bridge.cancelled[message.id] then
            bridge.cancelled[message.id] = nil
            return
        end

        if not ok then
            sendResult(message.id, false, nil, {
                code = 'INTERNAL_ERROR',
                message = truncateString('The bridge raised an error: ' .. tostring(result)),
            }, durationMs)
            return
        end

        if result == nil and handlerError ~= nil then
            sendResult(message.id, false, nil, handlerError, durationMs)
            return
        end

        sendResult(message.id, true, result, nil, durationMs)
    end)
end

local function handleMessage(raw)
    local ok, message = pcall(function()
        return HttpService:JSONDecode(raw)
    end)
    if not ok or type(message) ~= 'table' then
        warnLog('Received a frame that was not valid JSON.')
        return
    end

    local messageType = message.type

    if messageType == 'hello_ack' then
        setConsoleOutput(message.logging)
        bridge.clientId = message.clientId
        bridge.clientLabel = message.clientLabel
        info('Session ' .. tostring(message.sessionId) .. ' is live as client ' .. tostring(message.clientId) .. '.')
        LIMITS.maxPayloadBytes = math.min(tonumber(message.maxPayloadBytes) or LIMITS.maxPayloadBytes, 2 * 1024 * 1024)
    elseif messageType == 'settings_update' then
        setConsoleOutput(message.logging)
    elseif messageType == 'command' then
        dispatchCommand(message)
    elseif messageType == 'cancel_command' then
        bridge.cancelled[message.id] = true
    elseif messageType == 'heartbeat_ack' then
        -- Nothing to do; the round trip itself is the signal.
    elseif messageType == 'session_revoked' then
        warnLog('The session was revoked: ' .. tostring(message.reason))
        bridge.stopped = true
        pcall(function() bridge.socket:Close() end)
    elseif messageType == 'session_expired' then
        warnLog('The session expired.')
        bridge.stopped = true
        pcall(function() bridge.socket:Close() end)
    elseif messageType == 'error' then
        warnLog('Server error ' .. tostring(message.code) .. ': ' .. tostring(message.message))
    end
end

local function collectMetadata()
    local player = Players.LocalPlayer
    local metadata = {
        placeId = game.PlaceId,
        jobId = game.JobId,
        clientVersion = tostring(version and version() or 'unknown'),
        luaVersion = tostring(_VERSION),
    }

    local okUniverse, universeId = pcall(function() return game.GameId end)
    metadata.universeId = okUniverse and universeId or nil

    local okName, gameName = pcall(function()
        return game:GetService('MarketplaceService'):GetProductInfo(game.PlaceId).Name
    end)
    metadata.gameName = okName and gameName or nil

    if player then
        metadata.localPlayer = {
            name = player.Name,
            displayName = player.DisplayName,
            userId = player.UserId,
            accountAge = player.AccountAge,
        }
    end

    if API.identifyexecutor then
        local okExecutor, executorName, executorVersion = pcall(API.identifyexecutor)
        if okExecutor and executorName then
            metadata.executor = tostring(executorName)
                .. (executorVersion and (' ' .. tostring(executorVersion)) or '')
        end
    end

    return metadata
end

local function startHeartbeat()
    bridge.heartbeatThread = task.spawn(function()
        while isCurrentGeneration() and bridge.connected do
            task.wait(15)
            if not (isCurrentGeneration() and bridge.connected) then
                break
            end
            sendRaw({ protocolVersion = PROTOCOL_VERSION, type = 'heartbeat', sentAt = os.time() })
        end
    end)
end

local function connectOnce()
    local ok, socket = pcall(wsConnect, WS_URL)
    if not ok or socket == nil then
        return false, tostring(socket)
    end

    bridge.socket = socket
    bridge.connected = true

    socket.OnMessage:Connect(function(raw)
        if not isCurrentGeneration() then return end
        local handled = pcall(handleMessage, raw)
        if not handled then
            warnLog('A message handler raised an error.')
        end
    end)

    socket.OnClose:Connect(function()
        bridge.connected = false
    end)

    local sent = sendRaw({
        protocolVersion = PROTOCOL_VERSION,
        type = 'hello',
        sessionId = config.SessionId,
        token = config.RobloxToken,
        capabilities = buildCapabilities(),
        metadata = collectMetadata(),
        bridgeVersion = BRIDGE_VERSION,
        clientKey = getClientKey(),
    })
    if not sent then
        bridge.connected = false
        return false, 'The hello frame could not be sent.'
    end

    startHeartbeat()
    return true
end

genv.ClovyreDisconnect = function()
    bridge.stopped = true
    bridge.connected = false

    -- Drop every watcher; leaving connections behind would keep firing into a
    -- socket that is about to close.
    for watchId in pairs(watches) do
        stopWatch(watchId)
    end
    remoteSpy.active = false
    if bridge.socket then
        pcall(function()
            bridge.socket:Send(HttpService:JSONEncode({
                protocolVersion = PROTOCOL_VERSION,
                type = 'goodbye',
                reason = 'ClovyreDisconnect() was called.',
            }))
        end)
        pcall(function() bridge.socket:Close() end)
    end
    bridge.socket = nil
    genv.ClovyreConnected = false
    info('Disconnected.')
    return true
end

task.spawn(function()
    local attempt = 0

    while isCurrentGeneration() do
        local ok, connectError = connectOnce()

        if ok then
            attempt = 0
            genv.ClovyreConnected = true
            info('Connected to ' .. BASE_URL .. ' as session ' .. config.SessionId .. '.')
            while isCurrentGeneration() and bridge.connected do
                task.wait(1)
            end
            genv.ClovyreConnected = false
            if not isCurrentGeneration() then
                break
            end
            warnLog('Connection lost; reconnecting.')
        else
            warnLog('Connection failed: ' .. tostring(connectError))
        end

        if bridge.stopped then
            break
        end

        attempt = attempt + 1
        if attempt > 8 then
            warnLog('Giving up after 8 reconnect attempts. Run the loadstring again to retry.')
            break
        end

        -- Exponential backoff, capped, with jitter so many clients do not sync up.
        local delay = math.min(2 ^ attempt, 60) + math.random() * 2
        info(string.format('Reconnecting in %.1f seconds (attempt %d).', delay, attempt))
        task.wait(delay)
    end

    genv.ClovyreConnected = false
end)

info('Clovyre bridge v' .. BRIDGE_VERSION .. ' starting. Call getgenv().ClovyreDisconnect() to stop.')

return {
    version = BRIDGE_VERSION,
    disconnect = genv.ClovyreDisconnect,
}
