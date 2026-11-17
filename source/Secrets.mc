import Toybox.Lang;

// Only for the optional calorie deficit mode (docs/deficit-mode.md). Leave both empty to use the face with your
// watch alone: then nothing is ever fetched and the background service never runs.
//
// If you do fill these in, keep them out of any public repo: a token here lets anyone read your food log. Either
// keep your fork private, or tell git to ignore your local edit:
//     git update-index --skip-worktree source/Secrets.mc
(:background)
module Secrets {
    const INTAKE_URL = "";      // e.g. "https://your-server.example.com/intake"
    const READ_TOKEN = "";      // your server's read-only token
}
