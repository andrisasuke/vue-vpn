# Stats icon reference masks

These four small grayscale masks are independent visual-test fixtures derived
from the user-provided screenshots on November 3, 2026:

- `Screenshot 2026-11-03 at 10.43.26.png` → CPU
- `Screenshot 2026-11-03 at 10.43.20.png` → RAM
- `Screenshot 2026-11-03 at 10.43.15.png` → SSD
- `Screenshot 2026-11-03 at 10.54.35.png` → Network

The screenshots were background-normalized, cropped to their visible silhouette,
and resized to a 256 × 256 normalized mask. The fixtures are test inputs only;
they are not bundled UI assets and do not come from a website or third-party
library. The production renderer is never used to generate these masks.
