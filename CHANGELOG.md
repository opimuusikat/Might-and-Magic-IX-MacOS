# Changelog

One section per builder version, newest first. The heading must be `## <version>` and match
`BUILDER_VERSION` in `src/manifest.sh`: the MM9 Native Updater shows the section for its own
version on its welcome page. Keep each line short and in plain words, one fix per line.

To ship a fix: change the code, add a line here, bump `BUILDER_VERSION`, run `dev/make_updater.sh`
(and the installer script), then publish a GitHub release with a higher tag.

## 1.1

- Fixes go here, one per line. Replace this line with what changed in 1.1.
