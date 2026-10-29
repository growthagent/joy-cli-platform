{
  description = "joy-cli-platform: the Roc platform ./joy runs on, and its development environment";

  nixConfig = {
    extra-substituters = [ "https://niclas-ahden.cachix.org" ];
    extra-trusted-public-keys = [ "niclas-ahden.cachix.org-1:FdGli1vBk0cTuVJV27Tau/JvlbW+Ly3pRwFByyqdke0=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # nixos-unstable no longer supports Intel macOS.
    nixpkgs-x86-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    # The Roc compiler revision, keep the `?dir=src` at the end
    roc-src.url = "github:roc-lang/roc/0c440e5f316f70438af984f2b548da69ab721de9?dir=src";
    roc-nix = {
      url = "github:niclas-ahden/roc-nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.roc-src.follows = "roc-src";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-x86-darwin,
      roc-nix,
      roc-src,
      rust-overlay,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs supportedSystems;
      rustToolchainConfig = (builtins.fromTOML (builtins.readFile ./rust-toolchain.toml)).toolchain;

      # scripts/build.py cross-compiles the host with `zig cc` for the musl
      # targets, so those work from any host. The macOS targets need an Apple
      # SDK for the bundled C dependencies, so only ship their standard
      # libraries where they can actually be built.
      muslRustTargets = [
        "x86_64-unknown-linux-musl"
        "aarch64-unknown-linux-musl"
      ];
      darwinRustTargets = [
        "x86_64-apple-darwin"
        "aarch64-apple-darwin"
      ];
      rustTargetsFor =
        system: muslRustTargets ++ lib.optionals (lib.hasSuffix "-darwin" system) darwinRustTargets;
      pkgsFor =
        system:
        import (if system == "x86_64-darwin" then nixpkgs-x86-darwin else nixpkgs) {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };
      releaseFor =
        system:
        import ./nix/release.nix {
          pkgs = pkgsFor system;
          compiler = roc-nix.packages.${system}.roc;
        };
    in
    {
      formatter = forAllSystems (system: (pkgsFor system).nixfmt);

      packages = forAllSystems (system: (releaseFor system).packages);
      checks = forAllSystems (system: (releaseFor system).checks);

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          rustToolchain = pkgs.rust-bin.fromRustupToolchain (
            rustToolchainConfig // { targets = rustTargetsFor system; }
          );
        in
        {
          default = pkgs.mkShell {
            packages = [
              roc-nix.packages.${system}.roc
              pkgs.python3
              rustToolchain
              pkgs.simple-http-server
              pkgs.zig_0_16
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.valgrind ];

            # ci/regenerate_glue.sh reads the glue spec of the pinned compiler.
            ROC_GLUE_SPEC = "${roc-src}/glue/src/RustGlue.roc";
          };
        }
      );
    };
}
