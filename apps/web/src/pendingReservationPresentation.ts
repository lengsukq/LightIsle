// A root's name alone is never proof that a historical reservation belongs
// to the currently mounted physical generation.
export function reservationRootLabel(
  item: { rootID: string; rootGeneration: number },
  roots: Array<{ rootID: string; generation: number; name: string; online: boolean }>,
  rootsKnown: boolean,
): string {
  if (!rootsKnown) return `${item.rootID.slice(0, 8)} · 硬盘状态未知`;
  const root = roots.find((value) => value.rootID === item.rootID);
  if (!root) return `${item.rootID.slice(0, 8)} · 原硬盘未登记，请检查原盘`;
  if (root.generation !== item.rootGeneration) return `${root.name} · 旧绑定，请检查原盘`;
  return `${root.name} · ${root.online ? "在线" : "离线"}`;
}
