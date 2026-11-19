import assert from "node:assert/strict";
import test from "node:test";
import { stripLaunchTicket } from "../src/composables/useAppsCenterController.ts";

test("stripLaunchTicket removes single-use __li_ticket while preserving path, extra query params, and hash", () => {
  assert.equal(
    stripLaunchTicket("/apps/network-pulse/?__li_ticket=deadbeef01"),
    "/apps/network-pulse/",
  );
  assert.equal(
    stripLaunchTicket("/apps/network-pulse/?tab=latency&__li_ticket=deadbeef01#top"),
    "/apps/network-pulse/?tab=latency#top",
  );
  assert.equal(
    stripLaunchTicket("/apps/network-pulse/"),
    "/apps/network-pulse/",
  );
  assert.equal(stripLaunchTicket(""), "");
});
