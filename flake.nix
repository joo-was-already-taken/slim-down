{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zls = {
      url = "github:zigtools/zls/0.15.x";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.zig-overlay.follows = "zig-overlay";
    };
  };

  outputs = { self, flake-parts, ... }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } ({ ... }: {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      perSystem = { pkgs, system, ... }: let
        zig = inputs.zig-overlay.packages.${system}."0.15.2";
        zls = inputs.zls.packages.${system}.zls;
      in rec {
        packages.default = packages.slim-down;
        packages.slim-down = pkgs.callPackage ./nix/package.nix {
          inherit zig;
          gitCommit = self.shortRev or self.dirtyShortRev;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            zig
            zls
            pkgs.zon2nix
          ];
        };
      };
    });
}
