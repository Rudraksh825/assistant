import init from './001_init.js';
import uiGaps from './002_ui_gaps.js';
import safety from './003_safety.js';
import places from './030_places.js';

// Append only. A migration's position is its version (PRAGMA user_version); never edit one that has shipped.
export const migrations: string[] = [init, uiGaps, safety, places];
