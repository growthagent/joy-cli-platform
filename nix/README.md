# Using a published joy-cli-platform release with Nix

`nix build .` and `nix build .#platform` produce an unpacked published platform.
`nix build .#bundle` produces its original `.tar.zst` archive. Both use the URL and
SHA-256 in `release.json`, and do not rebuild this checkout's Rust hosts. The
archive includes every supported platform target. Until the first release,
`release.json` holds a placeholder and these outputs do not build.

The platform imports a separate HTTP package. Its archive is also pinned, so a
consumer can compile inside a Nix sandbox without downloading Roc packages during
the build. `platform.dependencyReplacements` supplies the corresponding compiler
arguments, and `platform.compiler` the compiler tested with these packages.

## Downstream application

Create this `flake.nix` in your application directory:

```nix
{
  inputs.joy-cli-platform.url = "github:niclas-ahden/joy-cli-platform";

  outputs = { joy-cli-platform, ... }:
    let
      system = "x86_64-linux";
      pkgs = joy-cli-platform.inputs.nixpkgs.legacyPackages.${system};
      platform = joy-cli-platform.packages.${system}.platform;
    in {
      packages.${system}.default = pkgs.runCommand "hello" {
        nativeBuildInputs = [ platform.compiler ];
      } ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" "$out/bin"
        cp ${pkgs.replaceVars ./main.roc {
          platformUrl = platform.release.url;
        }} main.roc
        roc build main.roc --output=hello \
          --replace-dep '${platform.release.url}' ${platform}/main.roc \
          ${platform.dependencyReplacements} || test "$?" -eq 2
        ./hello
        cp hello "$out/bin/hello"
      '';
    };
}
```

Create `main.roc` as a template whose platform URL Nix fills in:

```roc
app [main!] { pf: platform "@platformUrl@" }

import pf.Stdout

main! = |_args| Stdout.line!("Hello from joy-cli-platform!")
```

Run `nix build` and then `./result/bin/hello`. Commit `flake.lock` to pin the
joy-cli-platform flake and its inputs. For another host, change `system` to
`aarch64-linux` or `aarch64-darwin`. Intel macOS uses `x86_64-darwin` and
`joy-cli-platform.inputs.nixpkgs-x86-darwin` for `pkgs`.

The `--replace-dep` arguments replace the published URLs with unpacked Nix store
paths. An absolute store path cannot be used directly in a Roc platform header.
The shell accepts Roc exit code 2 because older platform releases can compile
successfully with warnings. Running and copying the executable still verifies
that a usable binary was produced.

The repository's `checks.consumer` builds and runs the same kind of application.
Run `nix flake check` to exercise it locally. CI does not run it.

## Updating the release

The release workflow updates `release.json` in its release follow-up PR alongside
the examples. To update it manually, use Python, GNU tar, and zstd:

```sh
python3 scripts/update_nix_release.py --version VERSION --url RELEASE_BUNDLE_URL
nix flake check
```

The updater hashes the published archive and the direct package downloads named
in its `main.roc`, rather than using the current checkout's package declarations.
It also records the Roc commit that built the release (`compiler` in `release.json`),
defaulting to the `roc-src` commit in `flake.nix`. Pass `--compiler` to override it.
If a future dependency introduces its own package imports, extend the pins and
replacement arguments before publishing it through this flake.
