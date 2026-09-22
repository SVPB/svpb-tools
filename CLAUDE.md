Prefer using Swift when considering creating programs.

## Running the tests in a Linux container on a Mac

CI runs the suite on Linux (`swift:6.3-noble`, plus `librsvg2-bin`), because that is where
SVGPDFKit rasterises through `rsvg-convert` rather than CoreGraphics. Reproducing that
locally under Docker Desktop needs two things that are not obvious:

1. **Preload the `fineres.so` shim, or `swift test` hangs part way through.** Docker
   Desktop's VM kernel reports `clock_getres(CLOCK_MONOTONIC)` as 1 ms, and
   swift-corelibs-foundation derives CoreFoundation's timebase from it
   (`__CFTSRRate` in `CFDate.c`), so every CFRunLoop deadline is computed in the past:
   the one-shot timer meant to end a bounded run fires immediately and never again,
   while the loop sleeps in an untimed `ppoll`. `RunLoop.run(mode:before:)` then never
   returns, which hangs XCTest's teardown — the test process sits in `do_sys_poll`,
   burning no CPU, with nothing wrong in the test itself. It is
   [swift-corelibs-foundation#5485](https://github.com/swiftlang/swift-corelibs-foundation/pull/5485),
   fixed on main and in no released toolchain.

   SVGPDFKit carries the workaround as `Scripts/fineres.c` — an `LD_PRELOAD` shim that
   reports the 1 ns resolution `CFDate.c` assumes, and changes nothing else. It ships in
   the tagged checkout, so it is already inside the repository:

   ```
   clang -shared -fPIC -o /tmp/fineres.so .build/checkouts/SVGPDFKit/Scripts/fineres.c
   LD_PRELOAD=/tmp/fineres.so swift test
   ```

   Delete this section when a toolchain ships the fix. Nothing in the conversion path
   depends on the broken deadline — `RsvgSubprocess` waits with `waitpid(2)` — so a hang
   here is the container, not the pipeline.

2. **Build to a scratch path outside the working tree, or mount the repo at `/build`.**
   `.build/aarch64-unknown-linux-gnu` holds a module cache stamped with the absolute path
   it was built at. `dev.sh` mounts the repository at `/build`; a container that mounts it
   anywhere else fails with `missing required module 'SwiftShims'` until that cache is
   thrown away.

Both are handled for you by **`Scripts/linux-tests.sh`**, which builds
`test.dockerfile` and runs the suite in it. Arguments reach `swift test`:

```
Scripts/linux-tests.sh                              # the whole suite
Scripts/linux-tests.sh --filter EngravedPageSize     # one suite
```

The build tree lives in the `tng_linux_build` volume, so runs are incremental;
`docker volume rm tng_linux_build` starts clean.

Reading a converted PDF's page geometry works on one backend only: CoreGraphics writes
uncompressed page dictionaries, while librsvg's cairo backend writes PDF 1.5 with its
objects inside compressed `/ObjStm` streams. `Tests/AppTests/PageSizes.swift` is where that
lives — assert the page a document *declares* and the converter's diagnostics, which hold
on both, and use `pdfPageSizesOrSkip` for the end-to-end media-box check.
