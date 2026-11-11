import assert from "node:assert/strict";
import test from "node:test";
import { reservationRootLabel } from "../src/pendingReservationPresentation.ts";

test("reservation display distinguishes offline, unknown and old physical roots", () => {
  const item = {rootID:"1234567890abcdef",rootGeneration:3};
  const root = {rootID:item.rootID,generation:3,name:"照片盘",online:true};
  assert.equal(reservationRootLabel(item, [root], true), "照片盘 · 在线");
  assert.equal(reservationRootLabel(item, [{...root,online:false}], true), "照片盘 · 离线");
  assert.equal(reservationRootLabel(item, [{...root,generation:4}], true), "照片盘 · 旧绑定，请检查原盘");
  assert.equal(reservationRootLabel(item, [], true), "12345678 · 原硬盘未登记，请检查原盘");
  assert.equal(reservationRootLabel(item, [], false), "12345678 · 硬盘状态未知");
});
