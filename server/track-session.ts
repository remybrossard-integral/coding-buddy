#!/usr/bin/env bun
/**
 * Records the start of a coding session — called from the react hook the first
 * time it runs under a session id.
 *
 * Usage:
 *   bun run server/track-session.ts
 */

import { incrementEvent, trackActiveDay } from "./achievements";

function main(): void {
  trackActiveDay();
  const events = incrementEvent("sessions", 1);
  console.log(`Sessions: ${events.sessions} (days active: ${events.days_active})`);
}

main();
