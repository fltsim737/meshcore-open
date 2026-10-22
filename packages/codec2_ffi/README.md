# codec2_ffi

The [Codec2](https://github.com/drowe67/codec2) speech codec, built from
source and loaded through `dart:ffi`. MeshCore Open uses it to fit voice clips
into a few LoRa packets: 700 bit/s mode (28 bits per 40 ms frame) and
1300 bit/s mode (52 bits per frame), both at 8 kHz mono.

## Vendored source

`src/codec2/` holds the speech-codec subset of Codec2 1.2.0, licensed under the
GNU LGPL 2.1 (see `src/codec2/COPYING`). The library is built as a separate
shared object (`libcodec2_ffi.so`) and linked dynamically.

The `codebook*.c` files are generated: upstream's CMake build produces them
with its `generate_codebook` tool, which cannot run when cross-compiling for
Android. They were generated once by building Codec2 1.2.0 on Linux x86-64:

```sh
cmake -S codec2-1.2.0 -B build -DCMAKE_BUILD_TYPE=Release
make -C build codec2
cp build/src/codebook*.c src/codec2/   # only the six the speech modes use
cp build/codec2/version.h src/codec2/codec2/
```

The FreeDV modem files are left out.

Microsoft's C compiler has no variable-length arrays, which Codec2 uses in
its speech code. `src/codec2/vla.h` turns them into `_alloca` allocations
there and leaves them unchanged elsewhere; the declarations were rewritten
to use it (and `levinson_durbin` in `lpc.c` to index one flat array).
Building with `-DCODEC2_FORCE_ALLOCA` uses the `_alloca` form with gcc; it
encodes Codec2's sample speech bit for bit as the reference `c2enc` does.
