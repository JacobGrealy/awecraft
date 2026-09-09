class_name Build

# Build stamp shown on the title screen (menu.gd version_label:
# "AweCraft[" + Build.ID + "]") and in the crash dialog (debug.gd).
# build_windows.sh rewrites this const to "<stamp> <git-short-sha>" (stamp =
# the same YYYYMMDD-HHMM used for the exported filenames) right before
# exporting and restores this file afterwards (git checkout, EXIT trap) so
# the working tree always reads "dev". Dev / local-tree runs show "dev".
# A shipped build therefore always displays the exact stamp of the artifact
# running - if the title screen does not match the build you were told to
# fetch, you are running an old exe.
const ID := "dev"
