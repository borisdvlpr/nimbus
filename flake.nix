{
  description = "Development environment for the nimbus project";

  inputs = {
    # The package set. `nixos-unstable` tracks recent versions.
    # To pin to a stable release instead, swap the ref, e.g.:
    #   "github:NixOS/nixpkgs/nixos-25.11"
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # helper: produce an attribute set keyed by each system name.
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              ansible        # ansible-core plus the bundled community collections
              ansible-lint   # static analysis for playbooks and roles
            ];

            shellHook = ''
              echo "Welcome to nimbus!"
            '';
          };
        });
    };
}
