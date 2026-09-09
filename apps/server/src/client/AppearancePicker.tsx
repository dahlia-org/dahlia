import type { Appearance } from "../appearance-model";
export type { Appearance } from "../appearance-model";
import { useId, type CSSProperties } from "react";
import { MenuIcon } from "./Sidebar";
import { uiText } from "./api";

export const appearanceColors = {
  neutral: ["#626066", "Neutral", "標準"],
  red: ["#ef4444", "Red", "赤"],
  orange: ["#f97316", "Orange", "オレンジ"],
  yellow: ["#eab308", "Yellow", "黄"],
  green: ["#22c55e", "Green", "緑"],
  blue: ["#1683ee", "Blue", "青"],
  purple: ["#b82aca", "Purple", "紫"],
  pink: ["#f52568", "Pink", "ピンク"],
} as const;

// Keys match Desktop's ProjectIcon raw values.
export const appearanceIcons = {
  vault: ["Vault", "保管庫", ""],
  folder: ["Folder", "フォルダ", ""],
  "dollarsign.circle": ["Finance", "金融", "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0ZM12 6v12M15 8H10a2 2 0 0 0 0 4h4a2 2 0 0 1 0 4H9"],
  "book.closed": ["Book", "本", "M5 3h14v18H7a2 2 0 0 1-2-2V3ZM5 17h14M8 3v14"],
  graduationcap: ["Education", "教育", "m2 8 10-5 10 5-10 5L2 8ZM6 10v7q6 5 12 0v-7M22 8v8"],
  pencil: ["Writing", "執筆", "m16 3 5 5-13 13H3v-5L16 3ZM13 6l5 5"],
  tag: ["Tag", "タグ", "M3 3h8l10 10-8 8L3 11V3ZM7 7h.01"],
  curlybraces: ["Code", "コード", "M9 3H7v6l-3 3 3 3v6h2M15 3h2v6l3 3-3 3v6h-2"],
  terminal: ["Terminal", "ターミナル", "M3 4h18v16H3V4Zm3 4 4 4-4 4M13 16h5"],
  "music.note": ["Music", "音楽", "M10 18V5l10-2v13M10 5v4l10-2M10 18a3 2 0 1 1-6 0 3 2 0 0 1 6 0ZM20 16a3 2 0 1 1-6 0 3 2 0 0 1 6 0Z"],
  popcorn: ["Entertainment", "娯楽", "M5 9h14l-2 12H7L5 9ZM5 9a3 3 0 0 1 1-5 3 3 0 0 1 6-1 3 3 0 0 1 5 2 2 2 0 0 1 2 4M9 10l1 10M15 10l-1 10"],
  paintbrush: ["Painting", "絵画", "m15 3 6 6-10 9-5-5 9-10ZM6 13q-5 0-3 8 8 2 8-3"],
  paintpalette: ["Art", "アート", "M12 3a9 9 0 1 0 0 18h2a2 2 0 0 0 0-4 2 2 0 0 1 0-4h4c5 0 3-10-6-10ZM7 8h.01M12 6h.01M17 8h.01M5 13h.01"],
  stethoscope: ["Medical", "医療", "M5 3v2M11 3v2M3 4v5a5 5 0 0 0 10 0V4M8 14v2a5 5 0 0 0 10 0v-3M21 10a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"],
  asterisk: ["Spark", "ひらめき", "M12 3v18M4 7l16 10M4 17 20 7"],
  "camera.macro": ["Wellness", "ウェルネス", "M12 21v-9M12 17q-8 0-8-6 8 0 8 6Zm0 0q8 0 8-6-8 0-8 6ZM12 12Q4 7 8 3l4 3 4-3q4 4-4 9Z"],
  briefcase: ["Work", "仕事", "M3 7h18v14H3V7ZM8 7V3h8v4M3 12q9 5 18 0M10 14h4"],
  "chart.bar": ["Analytics", "分析", "M3 13h4v8H3v-8ZM10 8h4v13h-4V8ZM17 3h4v18h-4V3Z"],
  medal: ["Award", "表彰", "M8 12 3 3h6l3 6 3-6h6l-5 9M18 16a6 6 0 1 1-12 0 6 6 0 0 1 12 0ZM12 13v6M10 16h4"],
  dumbbell: ["Fitness", "フィットネス", "M5 5h3v14H5V5ZM16 5h3v14h-3V5ZM2 8h3v8H2V8ZM19 8h3v8h-3V8ZM8 10h8v4H8"],
  notebook: ["Notes", "ノート", "M5 3h15v18H5V3ZM2 7h5M2 12h5M2 17h5M10 8h6M10 12h6M10 16h4"],
  scales: ["Balance", "バランス", "M12 3v18M7 21h10M4 7h16M5 7l-3 8h6L5 7ZM19 7l-3 8h6l-3-8"],
  "globe.desk": ["Workspace", "ワークスペース", "M17 9a6 6 0 1 1-12 0 6 6 0 0 1 12 0ZM17 2a10 10 0 0 1-14 14M11 19v3M6 22h10M5 9h12M11 3q-4 6 0 12 4-6 0-12"],
  airplane: ["Travel", "旅行", "m22 2-8 20-3-9-9-3 20-8ZM11 13 22 2"],
  globe: ["Global", "グローバル", "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0ZM3 12h18M12 3q-8 9 0 18 8-9 0-18"],
  wrench: ["Tools", "ツール", "M14 3a6 6 0 0 0-7 8l-5 6 5 5 6-6a6 6 0 0 0 8-7l-4 4-5-5 4-4-2-1Z"],
  pawprint: ["Animals", "動物", "M6 15q6-9 12 0c6 9-3 4-6 4s-12 5-6-4ZM6 9a2 3 0 1 1-4 0 2 3 0 0 1 4 0ZM11 5a2 3 0 1 1-4 0 2 3 0 0 1 4 0ZM17 5a2 3 0 1 1-4 0 2 3 0 0 1 4 0ZM22 9a2 3 0 1 1-4 0 2 3 0 0 1 4 0Z"],
  flask: ["Science", "科学", "M8 3h8M9 3v7L3 20q0 1 2 1h14q2 0 2-1l-6-10V3M6 15h12"],
  brain: ["Ideas", "アイデア", "M12 5q-5-6-7 1-6 3-2 8-2 6 5 6 4 4 4-1V5Zm0 0q5-6 7 1 6 3 2 8 2 6-5 6-4 4-4-1M5 6q5 0 3 5M3 14q6-3 5 6M19 6q-5 0-3 5M21 14q-6-3-5 6"],
  heart: ["Favorite", "お気に入り", "M12 21 3 12C-4 2 9-1 12 6 15-1 28 2 21 12l-9 9Z"],
  pottedplant: ["Plant", "植物", "M20 3Q2 1 3 13q3 11 14 5 5-6 3-15ZM6 7q7 3 14 14"],
} as const;



// Child appearance is always derived, including when an old record contains a value.
export function collectionAppearance(collection: { icon?: string | null; color?: string | null } | undefined, fallbackIcon: Appearance["icon"] = "folder"): Appearance {
  const icon = collection?.icon;
  const color = collection?.color;
  return {
    icon: icon && icon in appearanceIcons ? icon as Appearance["icon"] : fallbackIcon,
    color: color && color in appearanceColors ? color as Appearance["color"] : "neutral",
  };
}

export function projectAppearance(project: { parentProjectId?: string | null; icon?: string | null; color?: string | null } | undefined, parent?: { icon?: string | null; color?: string | null }): Appearance {
  return collectionAppearance(project?.parentProjectId ? parent : project);
}

export function AppearanceIcon({ appearance, size = 18 }: { appearance: Appearance; size?: number }) {
  const aliases = { film: "popcorn", "cross.case": "stethoscope", puzzlepiece: "asterisk", leaf: "pottedplant" } as const;
  const icon = appearance.icon in aliases ? aliases[appearance.icon as keyof typeof aliases] : appearance.icon as keyof typeof appearanceIcons;
  const { color } = appearance;
  return <span className="appearance-icon" style={{ color: color === "neutral" ? "currentColor" : appearanceColors[color][0], width: size, height: size }}>
    {icon === "folder" || icon === "vault" ? <MenuIcon name={icon} /> : <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={appearanceIcons[icon][2]} /></svg>}
  </span>;
}

export function AppearancePicker({ value, onChange, disabled = false }: { value: Appearance; onChange: (value: Appearance) => void; disabled?: boolean }) {
  const id = useId();
  return <div className="appearance-picker">
    <fieldset disabled={disabled}><legend>{uiText("Color", "色")}</legend><div className="appearance-colors">
      {Object.entries(appearanceColors).map(([color, [hex, en, ja]]) => <button type="button" key={color} aria-label={uiText(en, ja)} aria-pressed={value.color === color}
        style={{ "--appearance-color": hex } as CSSProperties} onClick={() => onChange({ ...value, color: color as Appearance["color"] })}><span /></button>)}
    </div></fieldset>
    <fieldset disabled={disabled}><legend id={id}>{uiText("Icon", "アイコン")}</legend><div className="appearance-icons" aria-labelledby={id}>
      {Object.entries(appearanceIcons).map(([icon, [en, ja]]) => <button type="button" key={icon} aria-label={uiText(en, ja)} title={uiText(en, ja)} aria-pressed={value.icon === icon}
        onClick={() => onChange({ ...value, icon: icon as Appearance["icon"] })}><AppearanceIcon appearance={{ ...value, icon: icon as Appearance["icon"] }} size={22} /></button>)}
    </div></fieldset>
  </div>;
}
