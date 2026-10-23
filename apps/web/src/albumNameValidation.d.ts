export interface AlbumNameValidation {
  valid: boolean;
  name: string;
  reason: "empty" | "too_long" | "control_character" | null;
}

export function validateAlbumName(value: string): AlbumNameValidation;
