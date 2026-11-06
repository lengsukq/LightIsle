export function confirmCinemaExit(options: {
  save: () => Promise<unknown>;
  hasUnsaved: () => boolean;
  onLeave: () => void;
  onFailure: () => void;
}): Promise<boolean>;
