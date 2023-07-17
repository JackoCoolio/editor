{
  description = "an editor written in zig";

  inputs = {
    zig.url = "github:mitchellh/zig-overlay";
    zls.url = "github:zigtools/zls";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    zig,
    zls
  } @ inputs: let
    overlays = [
      (final: prev: {
        zigpkgs = inputs.zig.packages.${prev.system};
      })
    ];
    systems = builtins.attrNames inputs.zig.packages;
  in
    flake-utils.lib.eachSystem systems (system:
      let
        pkgs = import nixpkgs { inherit overlays system; };
        deps = {
          build =
            (with pkgs; [ zigpkgs.master ]) ++
            (with pkgs.python311Packages; [ python requests ]);
          dev = deps.build ++ [ zls.packages.${system}.default ];
        };
      in {
        packages.editor = pkgs.stdenvNoCC.mkDerivation {
          name = "editor";
          src = self;
          dontConfigure = true;
          buildPhase = ''
            CACHE_DIR=$(mktemp -d)
            mkdir -p $out
            zig build install --global-cache-dir $CACHE_DIR -p $out
            rm -rf $CACHE_DIR
          '';
          dontInstall = true;
          buildInputs = deps.build;
        };

        packages.default = self.packages.${system}.editor;

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = deps.dev;
        };
      });
}
