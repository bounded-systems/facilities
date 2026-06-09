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

          # prx (ld-loader, pinned v0.8.4) — same recipe as claude-box: prx is a
          # `bun --compile` binary, so patchelf corrupts it; invoke the nix glibc
          # loader directly on the untouched binary.
          prxBin = pkgs.fetchurl {
            url = "https://github.com/bounded-systems/prx/releases/download/v0.8.4/prx-aarch64-linux";
            sha256 = "0k0sdmc3s0vxnc2qdzgd53ynmn97lql9gcazja0zbb3kjs9hawir";
          };
          prxLibs = pkgs.lib.makeLibraryPath [ pkgs.glibc pkgs.stdenv.cc.cc.lib ];
          prx = pkgs.runCommand "prx-0.8.4" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
            install -Dm755 ${prxBin} $out/libexec/prx
            makeWrapper ${pkgs.glibc}/lib/ld-linux-aarch64.so.1 $out/bin/prx \
              --add-flags "--library-path ${prxLibs}" \
              --add-flags "$out/libexec/prx" \
              --set LD_LIBRARY_PATH "${prxLibs}"
          '';
          keeperdRoot = pkgs.buildEnv {
            name = "prx-keeperd-root";
            paths = [ prx pkgs.git pkgs.openssh pkgs.gh pkgs.cacert pkgs.coreutils pkgs.bashInteractive ];
            pathsToLink = [ "/bin" "/etc" "/share" ];
          };

          # bd — the beads CLI (Go release binary, gastownhall/beads v1.0.3,
          # linux_arm64). A normal ELF (not a bun blob), so autoPatchelf is safe
          # here — it relinks against the image's nix libs (no-op if static).
          bd = pkgs.stdenv.mkDerivation {
            pname = "bd";
            version = "1.0.3";
            src = pkgs.fetchurl {
              url = "https://github.com/gastownhall/beads/releases/download/v1.0.3/beads_1.0.3_linux_arm64.tar.gz";
              sha256 = "0by17cf87jgb0g6i8g83xzgyz3sbcbkmgfdgzj44hy9f05srqfi4";
            };
            sourceRoot = "."; # flat tarball — loose files, no top-level dir
            nativeBuildInputs = [ pkgs.autoPatchelfHook ];
            buildInputs = [ pkgs.stdenv.cc.cc.lib ];
            installPhase = "install -Dm755 bd $out/bin/bd";
          };
          beadsdRoot = pkgs.buildEnv {
            name = "prx-beadsd-root";
            # beadsd = `prx beads serve`; bd is the single-writer it wraps; dolt
            # is the client that connects to the dolt-box.
            paths = [ prx bd pkgs.dolt pkgs.git pkgs.cacert pkgs.coreutils pkgs.bashInteractive ];
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
          # keeperd-box (prx-anj): the git-write daemon, `prx keeper serve`.
          # SECRETS ARE RUNTIME, NEVER BAKED — the provenance signing key
          # (`PRX_PROVENANCE_KEY=ed25519:<b64>`) and the git push credential come
          # in via `podman --secret` at run; the keeper repo clone mounts at /work
          # and the socket dir (/run) is shared into the pod (prx-asr).
          keeperd-image = pkgs.dockerTools.buildLayeredImage {
            name = "prx-keeperd";
            tag = "dev";
            contents = [ keeperdRoot ];
            extraCommands = ''
              mkdir -p etc tmp run work home/keeper
              chmod 1777 tmp
              cat > etc/passwd <<EOF
              root:x:0:0:root:/root:/bin/bash
              keeper:x:1000:1000:keeper:/home/keeper:/bin/bash
              EOF
              cat > etc/group <<EOF
              root:x:0:
              keeper:x:1000:
              EOF
            '';
            config = {
              Entrypoint = [ "prx" ];
              Cmd = [ "keeper" "serve" "--socket" "/run/keeperd.sock" ];
              WorkingDir = "/work"; # the keeper repo clone (mounted at run)
              User = "keeper"; # ocap: non-root; no keys baked in
              Volumes = { "/run" = { }; }; # socket dir, shared into the pod
              Env = [
                "HOME=/home/keeper"
                "PATH=/bin"
                "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                "LANG=C.UTF-8"
              ];
            };
          };

          # beadsd-box (prx-634): the beads daemon, `prx beads serve`. bd is the
          # single-writer; dolt is the client. CONNECTS to the dolt-box over the
          # pod (DSN/adopt) rather than `bd dolt start` spawning its own — wired
          # at run (prx-asr). Beads clone mounts /work; socket shared via /run.
          beadsd-image = pkgs.dockerTools.buildLayeredImage {
            name = "prx-beadsd";
            tag = "dev";
            contents = [ beadsdRoot ];
            extraCommands = ''
              mkdir -p etc tmp run work home/beads
              chmod 1777 tmp
              cat > etc/passwd <<EOF
              root:x:0:0:root:/root:/bin/bash
              beads:x:1000:1000:beads:/home/beads:/bin/bash
              EOF
              cat > etc/group <<EOF
              root:x:0:
              beads:x:1000:
              EOF
            '';
            config = {
              Entrypoint = [ "prx" ];
              Cmd = [ "beads" "serve" "--socket" "/run/beadsd.sock" "--cwd" "/work" ];
              WorkingDir = "/work";
              User = "beads"; # ocap: non-root
              Volumes = { "/run" = { }; };
              Env = [
                "HOME=/home/beads"
                "PATH=/bin"
                "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                "LANG=C.UTF-8"
              ];
            };
          };

          default = self.packages.${system}.dolt-image;
        })) // {
        # Expose under the darwin host so `nix build .#…-image` resolves and
        # offloads to the Linux builder (same trick as claude-box).
        aarch64-darwin = {
          dolt-image = self.packages.aarch64-linux.dolt-image;
          keeperd-image = self.packages.aarch64-linux.keeperd-image;
          beadsd-image = self.packages.aarch64-linux.beadsd-image;
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
