{
  description = "an editor written in zig";

  inputs = {
    zig.url = "github:mitchellh/zig-overlay";
    zls.url = "github:zigtools/zls/0.13.0";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      perSystem = { config, self', inputs', pkgs, system, ... }:
      let
        zig-bin = inputs'.zig.packages."0.13.0";
        zls-bin = inputs'.zls.packages.default;
        deps = {
          build =
            [ zig-bin ] ++
            (with pkgs.python311Packages; [ python requests ]);
          dev = deps.build ++ [ zls-bin pkgs.gdb ];
        };
      in {
        # Per-system attributes can be defined here. The self' and inputs'
        # module parameters provide easy access to attributes of the same
        # system.

        # Equivalent to  inputs'.nixpkgs.legacyPackages.hello;
        packages.editor = pkgs.stdenvNoCC.mkDerivation {
          name = "editor";
          src = self';
          dontConfigure = true;
          buildPhase = ''
            CACHE_DIR=$(mktemp -d)
            mkdir -p $out
            zig build install --global-cache-dir "$CACHE_DIR" -p $out
            rm -rf "$CACHE_DIR"
          '';
          dontInstall = true;
          buildInputs = deps.build;
        };

        packages.default = self'.packages.editor;

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = deps.dev;
        };
      };
      flake = {
        # The usual flake attributes can be defined here, including system-
        # agnostic ones like nixosModule and system-enumerating ones, although
        # those are more easily expressed in perSystem.

      };
    };
}
