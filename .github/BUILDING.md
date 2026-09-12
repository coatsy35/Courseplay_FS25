# Manual Builds and Releases

Both workflows produce `FS25_Courseplay.zip`, with `modDesc.xml` at the archive
root. Runtime files and the licence are included; tests, development helpers and
GitHub configuration are excluded. Both workflows are manual only.

GitHub requires the workflow definitions on the default branch (`main`) before
the **Run workflow** buttons become available.

## Development ZIP

1. Open **Actions > Build Development ZIP > Run workflow**.
2. Select the development branch in **Use workflow from**, then run it.
3. Download `FS25_Courseplay.zip` from the completed run's artifacts.

The download is the installable ZIP, without an extra wrapper archive. Downloads
are retained for 30 days. The selected branch must contain these build files.
This workflow does not create a release or change `main`.

## Live Release

1. Merge the tested changes into `main` and set the intended four-part version
   in `modDesc.xml` (for example, `8.1.0.4`).
2. Open **Actions > Publish Live Release > Run workflow** and select `main`.
3. Run it to publish the version tag, release notes and `FS25_Courseplay.zip`.

The release is marked Latest and uses the exact `main` commit selected when the
run was dispatched. Other branches are rejected. An existing version tag causes
the run to fail; releases are never silently replaced. Nothing is published just
because a branch is pushed or merged.

These packaging checks do not replace the Lua tests or in-game validation. Use
the same modified mod ZIP on every multiplayer participant's machine.

## Local Verification

```powershell
python -m unittest discover -s .github/scripts -p test_build_mod.py -v
python .github/scripts/build_mod.py
```

The local output is `dist/FS25_Courseplay.zip`; the existing game-test ZIP is not
overwritten.
