{
  description = "Chorus UI — QML frontend for the chorus_core module";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    # Core module — the sibling `core/` in this repo, pinned to GitHub so this
    # flake builds standalone. For local dev against the sibling dir:
    #   nix build --override-input chorus_core path:../core '.#lgx-portable'
    chorus_core.url = "github:hackyguru/chorus?dir=core";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
