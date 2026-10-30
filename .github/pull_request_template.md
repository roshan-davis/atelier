<!-- Title: "<Area>: <what changes for Rosh>", e.g. "Develop > Tone Curve: drag points off the graph to delete them". Rules: AGENTS.md > Pull requests. -->

**Agent:** <!-- Claude / Codex / Antigravity (all that worked on it), with a session or thread link if there is one -->

## Summary

<!-- One or two sentences: what changes for Rosh and why. -->

## Changes

<!-- One bullet per change: what Rosh sees and where, then the technical note if useful.
     Group under Features / Fixes / Under the hood when there are more than a few.
     Call out anything that changes existing photos or data, what was left out, and known issues. -->

-

## How to test

```
cd ~/RoshProjects/Atelier/App
git status
git fetch origin
git checkout <branch>
git pull
```

Then in Xcode: Product > Run (⌘R), and:

1.

## Checklist

<!-- Tick what was done; strike through (~~like this~~) what doesn't apply. -->

- [ ] PRD (`Requirements/Atelier-PRD.md`) updated
- [ ] Help page updated and `Scripts/help/build_help_index.py` reports no problems
- [ ] `PreviewCache.version` bumped (rendering changed)
- [ ] `LayoutSnapshots.swift` covers new screens, and I looked at the snapshots for the latest commit
- [ ] `AtelierCoreTests` added or updated
