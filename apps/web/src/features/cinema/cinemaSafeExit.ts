// Never dismiss the current player as saved when the corresponding
// progress write failed. Historical errors for OTHER disks/films do not
// block leaving this film. Do not swallow the explicit failure.
export async function confirmCinemaExit({
  save,
  hasUnsaved,
  onLeave,
  onFailure,
}: {
  save: () => Promise<unknown>;
  hasUnsaved: () => boolean;
  onLeave: () => void;
  onFailure: () => void;
}): Promise<boolean> {
  try {
    await save();
  } catch {
    onFailure();
    return false;
  }
  if (hasUnsaved()) {
    onFailure();
    return false;
  }
  onLeave();
  return true;
}
