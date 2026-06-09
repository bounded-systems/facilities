{
  # prx service fleet — pinned OCI images for the podman pod (epic prx-zj8).
  # Generalizes claude-box's pattern (pinned nix dockerTools image) to the
  # daemons: dolt (here), then beadsd, then keeperd. Each runs as a long-lived
  # container in one podman pod; claude-box joins the pod → doors are local.
  #
  # NOTE (bd↔dolt coupling): bd normally OWNS its dolt server (`bd dolt start`);
  # two servers on one data dir collide. The pod model runs ONE dolt server
  # (this image) and has beadsd CONNECT to it (DSN/adopt) rather than spawn —
  # that connect-vs-spawn wiring is the beadsd-image slice, not this one.
  description = "prx service fleet — pinned OCI images (dolt, …) for the podman pod";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/bb813de6d2241bcb1b5af2d3059f560c66329967";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-linux" ];
      forEach = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; config.allowUnfree = true; };

      user = "dolt";
      uid = 1000;
      dataDir = "/var/lib/dolt"; # the DB lives here; mount a named volume
      port = "3306"; # dolt speaks the MySQL wire protocol
    in
    {
      packages = (forEach (system:
        let
          pkgs = pkgsFor system;
          root = pkgs.buildEnv {
            name = "prx-dolt-root";
            paths = [ pkgs.dolt pkgs.coreutils pkgs.bashInteractive pkgs.cacert ];
            pathsToLink = [ "/bin" "/etc" "/share" ];
          };
        in
        {
          # `nix build .#dolt-image` → result tarball → `podman load -i result`
          dolt-image = pkgs.dockerTools.buildLayeredImage {
            name = "prx-dolt";
            tag = "dev";
            contents = [ root ];
            extraCommands = ''
              mkdir -p etc tmp var/lib/dolt
              chmod 1777 tmp
              cat > etc/passwd <<EOF
              root:x:0:0:root:/root:/bin/bash
              ${user}:x:${toString uid}:${toString uid}:${user}:${dataDir}:/bin/bash
              EOF
              cat > etc/group <<EOF
              root:x:0:
              ${user}:x:${toString uid}:
              EOF
            '';
            config = {
              # `--host 0.0.0.0` so it's reachable from sibling pod containers.
              Entrypoint = [ "dolt" "sql-server" "--host" "0.0.0.0" "--port" port "--data-dir" dataDir ];
              WorkingDir = dataDir;
              User = user; # ocap: non-root
              ExposedPorts = { "${port}/tcp" = { }; };
              Volumes = { "${dataDir}" = { }; }; # state → named volume
              Env = [
                "HOME=${dataDir}"
                "PATH=/bin"
                "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                "LANG=C.UTF-8"
              ];
            };
          };
          default = self.packages.${system}.dolt-image;
        })) // {
        # Expose under the darwin host so `nix build .#dolt-image` resolves and
        # offloads to the Linux builder (same trick as claude-box).
        aarch64-darwin = {
          dolt-image = self.packages.aarch64-linux.dolt-image;
          default = self.packages.aarch64-linux.dolt-image;
        };
      };

      # The pinned standalone Linux builder (reused from claude-box) — boot with
      # `nix run .#linux-builder`, wire once into /etc/nix/machines.
      apps.aarch64-darwin.linux-builder =
        let pkgs = nixpkgs.legacyPackages.aarch64-darwin;
        in { type = "app"; program = nixpkgs.lib.getExe pkgs.darwin.linux-builder; };
    };
}
