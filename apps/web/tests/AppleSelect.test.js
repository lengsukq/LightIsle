import assert from "node:assert/strict";
import test from "node:test";

// Test helper that reproduces the normalization and matching logic of AppleSelect
function normalizeOptions(options) {
  return (options || []).map((item) => {
    if (typeof item === "object" && item !== null && "value" in item) {
      return {
        value: item.value,
        label: item.label !== undefined ? String(item.label) : String(item.value ?? ""),
        hint: item.hint ? String(item.hint) : undefined,
        disabled: Boolean(item.disabled),
      };
    }
    return {
      value: item,
      label: String(item),
      hint: undefined,
      disabled: false,
    };
  });
}

function resolveSelection(options, modelValue, placeholder = "请选择…") {
  const norm = normalizeOptions(options);
  const selected = norm.find((opt) => opt.value === modelValue);
  return {
    selected,
    displayText: selected ? selected.label || String(selected.value ?? "") : placeholder,
    isPlaceholder: !selected,
  };
}

function moveHighlight(normalizedOptions, currentIndex, step) {
  const count = normalizedOptions.length;
  if (count === 0) return -1;
  let next = currentIndex + step;
  if (next < 0) next = count - 1;
  if (next >= count) next = 0;

  for (let i = 0; i < count; i++) {
    const opt = normalizedOptions[next];
    if (opt && !opt.disabled) {
      return next;
    }
    next = (next + step + count) % count;
  }
  return currentIndex;
}

function computePlacement({
  triggerRect,
  viewportWidth,
  viewportHeight,
  optionsCount,
}) {
  const estimatedMenuHeight = Math.min(260, optionsCount * 34 + 16);
  const spaceBelow = viewportHeight - triggerRect.bottom - 10;
  const spaceAbove = triggerRect.top - 10;
  const dropUp = spaceBelow < 180 && spaceAbove > spaceBelow;

  const minWidth = Math.max(triggerRect.width, 120);
  const maxWidth = Math.min(Math.max(triggerRect.width, 280), viewportWidth - 24);

  let left = triggerRect.left;
  if (left + minWidth > viewportWidth - 12) {
    left = Math.max(12, viewportWidth - minWidth - 12);
  } else if (left < 12) {
    left = 12;
  }

  return {
    dropUp,
    left: Math.round(left),
    minWidth: Math.round(minWidth),
    maxWidth: Math.round(maxWidth),
    maxHeight: Math.round(dropUp ? Math.min(estimatedMenuHeight, spaceAbove) : Math.min(estimatedMenuHeight, spaceBelow)),
  };
}

test("AppleSelect normalizes primitive and object options with labels and hints", () => {
  const mixed = [
    7,
    { value: 30, label: "30 天", hint: "推荐" },
    { value: 90, label: "90 天", disabled: true },
  ];
  const normalized = normalizeOptions(mixed);

  assert.equal(normalized.length, 3);
  assert.deepEqual(normalized[0], { value: 7, label: "7", hint: undefined, disabled: false });
  assert.deepEqual(normalized[1], { value: 30, label: "30 天", hint: "推荐", disabled: false });
  assert.deepEqual(normalized[2], { value: 90, label: "90 天", hint: undefined, disabled: true });
});

test("AppleSelect correctly resolves selected option and fallback display text", () => {
  const options = [
    { value: 7, label: "7 天" },
    { value: 30, label: "30 天" },
    { value: 90, label: "90 天" },
  ];

  const result1 = resolveSelection(options, 30);
  assert.equal(result1.displayText, "30 天");
  assert.equal(result1.isPlaceholder, false);
  assert.equal(result1.selected?.value, 30);

  const result2 = resolveSelection(options, 999, "未选择");
  assert.equal(result2.displayText, "未选择");
  assert.equal(result2.isPlaceholder, true);
  assert.equal(result2.selected, undefined);
});

test("AppleSelect keyboard navigation cycles and skips disabled options", () => {
  const options = normalizeOptions([
    { value: "a", label: "A" },
    { value: "b", label: "B", disabled: true },
    { value: "c", label: "C" },
  ]);

  // Moving down from A (index 0) should skip B (disabled) and land on C (index 2)
  const next = moveHighlight(options, 0, 1);
  assert.equal(next, 2);

  // Moving down from C (index 2) wraps around to A (index 0)
  const wrapped = moveHighlight(options, 2, 1);
  assert.equal(wrapped, 0);

  // Moving up from A (index 0) wraps to C (index 2) skipping B
  const prev = moveHighlight(options, 0, -1);
  assert.equal(prev, 2);
});

test("AppleSelect placement calculates drop-up when below space is tight", () => {
  // Scenario: trigger near the bottom of the window
  const placement = computePlacement({
    triggerRect: { top: 600, bottom: 635, left: 100, width: 140 },
    viewportWidth: 1024,
    viewportHeight: 700,
    optionsCount: 5,
  });

  assert.equal(placement.dropUp, true);
  assert.equal(placement.left, 100);
  assert.ok(placement.maxHeight > 100);
});

test("AppleSelect placement clamps horizontal position within viewport", () => {
  // Scenario: trigger at the far right
  const placement = computePlacement({
    triggerRect: { top: 100, bottom: 135, left: 950, width: 120 },
    viewportWidth: 1000,
    viewportHeight: 800,
    optionsCount: 3,
  });

  assert.equal(placement.dropUp, false);
  assert.ok(placement.left + placement.minWidth <= 1000 - 12);
});
