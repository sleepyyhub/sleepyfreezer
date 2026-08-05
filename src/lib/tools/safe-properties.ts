/**
 * Curated safe-property registry.
 *
 * Clovyre never enumerates every property on an instance. Each class contributes a
 * hand-picked list of properties that are cheap to read, useful for inspection, and
 * free of asset payloads. The Roblox bridge reads them through pcall and omits any
 * property that errors or is not present on the concrete class.
 */

export const INSTANCE_PROPERTIES = ['Name', 'ClassName', 'Archivable'] as const;

/**
 * Properties keyed by class name. Lookup walks the class hierarchy on the client,
 * so a `Part` receives BasePart plus Instance entries.
 */
export const SAFE_PROPERTIES: Readonly<Record<string, readonly string[]>> = Object.freeze({
  Instance: INSTANCE_PROPERTIES,

  BasePart: [
    'Anchored',
    'CanCollide',
    'CanQuery',
    'CanTouch',
    'CastShadow',
    'CFrame',
    'CollisionGroup',
    'Color',
    'Material',
    'Massless',
    'Position',
    'Orientation',
    'Reflectance',
    'Size',
    'Transparency',
    'AssemblyLinearVelocity',
    'AssemblyAngularVelocity',
    'AssemblyMass',
  ],
  Part: ['Shape'],
  MeshPart: ['MeshId', 'TextureID', 'RenderFidelity', 'DoubleSided'],

  Model: ['PrimaryPart', 'WorldPivot', 'ModelStreamingMode', 'LevelOfDetail'],
  Folder: [],
  Configuration: [],

  ValueBase: ['Value'],
  StringValue: ['Value'],
  IntValue: ['Value'],
  NumberValue: ['Value'],
  BoolValue: ['Value'],
  ObjectValue: ['Value'],
  CFrameValue: ['Value'],
  Vector3Value: ['Value'],
  Color3Value: ['Value'],
  BrickColorValue: ['Value'],
  RayValue: ['Value'],

  Humanoid: [
    'Health',
    'MaxHealth',
    'WalkSpeed',
    'JumpPower',
    'JumpHeight',
    'UseJumpPower',
    'HipHeight',
    'AutoRotate',
    'PlatformStand',
    'Sit',
    'MoveDirection',
    'RigType',
    'DisplayName',
    'HealthDisplayType',
  ],
  HumanoidRootPart: [],

  Player: [
    'Name',
    'DisplayName',
    'UserId',
    'AccountAge',
    'Team',
    'TeamColor',
    'Neutral',
    'CharacterAppearanceId',
    'CameraMinZoomDistance',
    'CameraMaxZoomDistance',
    'CameraMode',
  ],

  Camera: ['CFrame', 'Focus', 'FieldOfView', 'CameraType', 'CameraSubject', 'ViewportSize'],

  GuiBase2d: ['AbsolutePosition', 'AbsoluteSize', 'AbsoluteRotation'],
  GuiObject: [
    'Active',
    'AnchorPoint',
    'BackgroundColor3',
    'BackgroundTransparency',
    'BorderColor3',
    'BorderSizePixel',
    'ClipsDescendants',
    'LayoutOrder',
    'Position',
    'Rotation',
    'Size',
    'SizeConstraint',
    'Visible',
    'ZIndex',
    'AbsolutePosition',
    'AbsoluteSize',
  ],
  ScreenGui: ['Enabled', 'DisplayOrder', 'IgnoreGuiInset', 'ResetOnSpawn', 'ZIndexBehavior'],
  Frame: ['Style'],
  TextLabel: [
    'Text',
    'TextColor3',
    'TextSize',
    'TextScaled',
    'TextWrapped',
    'TextTransparency',
    'TextXAlignment',
    'TextYAlignment',
    'RichText',
    'FontFace',
    'TextBounds',
    'TextFits',
  ],
  TextButton: [
    'Text',
    'TextColor3',
    'TextSize',
    'TextScaled',
    'AutoButtonColor',
    'Modal',
    'Selected',
  ],
  TextBox: ['Text', 'PlaceholderText', 'ClearTextOnFocus', 'MultiLine', 'TextEditable'],
  // Image metadata only. Clovyre never downloads or decodes image content.
  ImageLabel: [
    'Image',
    'ImageColor3',
    'ImageTransparency',
    'ImageRectOffset',
    'ImageRectSize',
    'ScaleType',
    'IsLoaded',
  ],
  ImageButton: [
    'Image',
    'ImageColor3',
    'ImageTransparency',
    'ScaleType',
    'IsLoaded',
    'AutoButtonColor',
  ],

  LuaSourceContainer: [],
  BaseScript: ['Enabled', 'RunContext'],
  Script: ['Enabled', 'RunContext'],
  LocalScript: ['Enabled'],
  ModuleScript: [],

  RemoteEvent: [],
  UnreliableRemoteEvent: [],
  RemoteFunction: [],
  BindableEvent: [],
  BindableFunction: [],

  ProximityPrompt: [
    'ActionText',
    'ObjectText',
    'HoldDuration',
    'MaxActivationDistance',
    'Enabled',
    'RequiresLineOfSight',
    'KeyboardKeyCode',
    'GamepadKeyCode',
    'Exclusivity',
    'UIOffset',
  ],

  Sound: [
    'SoundId',
    'Volume',
    'Playing',
    'IsPaused',
    'IsPlaying',
    'Looped',
    'PlaybackSpeed',
    'TimePosition',
    'TimeLength',
    'RollOffMode',
    'RollOffMaxDistance',
    'RollOffMinDistance',
  ],

  Animation: ['AnimationId'],
  AnimationTrack: [],
  Animator: [],

  Tool: ['Grip', 'CanBeDropped', 'Enabled', 'RequiresHandle', 'ToolTip', 'TextureId'],

  Attachment: ['CFrame', 'Position', 'Orientation', 'WorldCFrame', 'WorldPosition', 'Visible'],
  Weld: ['C0', 'C1', 'Enabled'],
  Motor6D: ['C0', 'C1', 'Transform', 'Enabled'],

  Workspace: [
    'Gravity',
    'StreamingEnabled',
    'StreamingTargetRadius',
    'FallenPartsDestroyHeight',
    'DistributedGameTime',
  ],
  Lighting: [
    'Ambient',
    'Brightness',
    'ClockTime',
    'FogEnd',
    'FogStart',
    'GlobalShadows',
    'TimeOfDay',
    'ExposureCompensation',
  ],
  Players: ['MaxPlayers', 'PreferredPlayers', 'RespawnTime', 'CharacterAutoLoads'],
  Teams: [],
  ReplicatedStorage: [],
  ReplicatedFirst: [],
  StarterGui: ['ResetPlayerGuiOnSpawn', 'ShowDevelopmentGui'],
  SoundService: ['AmbientReverb', 'DistanceFactor', 'DopplerScale', 'RolloffScale'],
  TextChatService: ['ChatVersion'],
});

/**
 * Ancestry used to resolve inherited safe properties. Kept small and explicit;
 * unknown classes simply fall back to the Instance list.
 */
export const CLASS_PARENTS: Readonly<Record<string, string>> = Object.freeze({
  Part: 'BasePart',
  MeshPart: 'BasePart',
  WedgePart: 'BasePart',
  TrussPart: 'BasePart',
  CornerWedgePart: 'BasePart',
  SpawnLocation: 'BasePart',
  Seat: 'BasePart',
  VehicleSeat: 'BasePart',
  UnionOperation: 'BasePart',
  BasePart: 'Instance',
  Model: 'Instance',
  Folder: 'Instance',
  Configuration: 'Instance',
  Workspace: 'Model',
  StringValue: 'ValueBase',
  IntValue: 'ValueBase',
  NumberValue: 'ValueBase',
  BoolValue: 'ValueBase',
  ObjectValue: 'ValueBase',
  CFrameValue: 'ValueBase',
  Vector3Value: 'ValueBase',
  Color3Value: 'ValueBase',
  BrickColorValue: 'ValueBase',
  RayValue: 'ValueBase',
  ValueBase: 'Instance',
  Humanoid: 'Instance',
  HumanoidRootPart: 'Part',
  Player: 'Instance',
  Camera: 'Instance',
  GuiBase2d: 'Instance',
  GuiObject: 'GuiBase2d',
  ScreenGui: 'GuiBase2d',
  Frame: 'GuiObject',
  TextLabel: 'GuiObject',
  TextButton: 'GuiObject',
  TextBox: 'GuiObject',
  ImageLabel: 'GuiObject',
  ImageButton: 'GuiObject',
  ScrollingFrame: 'GuiObject',
  LuaSourceContainer: 'Instance',
  BaseScript: 'LuaSourceContainer',
  Script: 'BaseScript',
  LocalScript: 'BaseScript',
  ModuleScript: 'LuaSourceContainer',
  RemoteEvent: 'Instance',
  UnreliableRemoteEvent: 'Instance',
  RemoteFunction: 'Instance',
  BindableEvent: 'Instance',
  BindableFunction: 'Instance',
  ProximityPrompt: 'Instance',
  Sound: 'Instance',
  Animation: 'Instance',
  AnimationTrack: 'Instance',
  Animator: 'Instance',
  Tool: 'Model',
  Attachment: 'Instance',
  Weld: 'Instance',
  Motor6D: 'Weld',
  Lighting: 'Instance',
  Players: 'Instance',
  Teams: 'Instance',
  ReplicatedStorage: 'Instance',
  ReplicatedFirst: 'Instance',
  StarterGui: 'Instance',
  SoundService: 'Instance',
  TextChatService: 'Instance',
});

/** Resolves the full safe-property list for a class, including inherited entries. */
export function safePropertiesFor(className: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  let current: string | undefined = className;
  let guard = 0;

  while (current && guard < 16) {
    guard += 1;
    for (const property of SAFE_PROPERTIES[current] ?? []) {
      if (!seen.has(property)) {
        seen.add(property);
        out.push(property);
      }
    }
    current = CLASS_PARENTS[current];
  }

  for (const property of INSTANCE_PROPERTIES) {
    if (!seen.has(property)) {
      seen.add(property);
      out.push(property);
    }
  }
  return out;
}

/** True when a property may be read (or written, for mutation tools) on a class. */
export function isSafeProperty(className: string, property: string): boolean {
  return safePropertiesFor(className).includes(property);
}

/** Every property name in the registry, used by the docs page and tool schemas. */
export function allSafePropertyNames(): string[] {
  const names = new Set<string>();
  for (const list of Object.values(SAFE_PROPERTIES)) {
    for (const property of list) names.add(property);
  }
  return [...names].sort();
}
