# ddist
Missing:
  * Create snapshot
  * Delete snapshot on success
  * Create shell script

**These will all be finished tomorrow.**

```
ddist - dart executable packaging tool

© Tobechukwu Osakwe 2018. All rights reserved.

usage: ddist [options...] <filename>

Options:
    --[no-]build-runner    Invoke `pub run build_runner build` before packaging.
                           (defaults to on)

    --dry-run              Do not actually create the tarball on disk.
    --[no-]gzip            Apply GZIP compression to the created tarball.
                           (defaults to on)

-h, --help                 Print this usage information.
    --[no-]test            Invoke `pub run test` before packaging.
                           (defaults to on)

    --[no-]version-file    Add a VERSION file to the output tarball.
                           (defaults to on)

    --[no-]verbose         Enable verbose output.
-d, --dir                  The directory to save the tarball in.
                           (defaults to "dist")

    --name                 The file path to install <filename> to.
                           (defaults to "bin/main.dart")

    --pubspec              The path to `pubspec.yaml`.
                           (defaults to "pubspec.yaml")

-c, --copy                 Globs to copy. Append `:<path>` to copy into <path>.
                           (defaults to "README.md", "LICENSE")

-x, --execute              Dart script(s) to be invoked before running.
    --sdk                  Standard Dart libraries to be bundled with the tarball.
                           (defaults to "_http", "_internal", "async", "collection", "convert", "core", "internal", "io", "isolate", "math", "typed_data")
```