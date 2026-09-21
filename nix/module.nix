{ folioPackages }:
{
  config,
  lib,
  pkgs,
  ...
}:
# Runs the Folio server and bridge as one unprivileged user, on that user's
# Claude login (log in once with `claude` as that user). The tablet reaches
# both over a path you choose: set `listen` to TCP on a private interface, or
# put a tunnel in front of the unix sockets.
let
  cfg = config.services.folio;
  pkgsFolio = folioPackages pkgs.stdenv.hostPlatform.system;
  home = cfg.stateDir;
in
{
  options.services.folio = {
    enable = lib.mkEnableOption "the Folio server and bridge";
    user = lib.mkOption {
      type = lib.types.str;
      default = "folio";
      description = "The user both run as; its Claude login is in its home.";
    };
    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/folio";
      description = "The user's home: the repo clone, the notes mirror, the bridge's token and jobs.";
    };
    claude = lib.mkOption {
      type = lib.types.package;
      default = pkgs.claude-code;
      description = "The Claude Code package that provides `claude`.";
    };
    serverListen = lib.mkOption {
      type = lib.types.str;
      default = "unix:/run/folio-server/app.sock";
      description = "tcp:host:port or unix:/path for the server.";
    };
    bridgeListen = lib.mkOption {
      type = lib.types.str;
      default = "unix:/run/folio-bridge/bridge.sock";
      description = "tcp:host:port or unix:/path for the bridge.";
    };
    builderRules = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Rules the builder must follow, from the deployment (`--core`). A build
        can change the repository, not this file.
      '';
    };
    gitSshCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "ssh -i /var/lib/folio/.ssh/deploy -o IdentitiesOnly=yes";
      description = "How the server pushes versions: a deploy key with write access to the repo.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.folio = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = "folio";
      inherit home;
      createHome = true;
      shell = pkgs.bashInteractive;
    };
    systemd.tmpfiles.rules = [
      "d /run/folio-server 0750 ${cfg.user} folio -"
      "d /run/folio-bridge 0750 ${cfg.user} folio -"
      "d ${home}/notes 0750 ${cfg.user} folio -"
      "d ${home}/bridge 0700 ${cfg.user} folio -"
      "d ${home}/server 0700 ${cfg.user} folio -"
    ];

    systemd.services.folio-server = {
      description = "Folio server: agent-built versions, and the notes mirror";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = with pkgs; [
        openssh
        bash
        coreutils
        findutils
        gnugrep
        gnused
        gitMinimal
        nix
      ];
      environment = {
        HOME = home;
      }
      // lib.optionalAttrs (cfg.gitSshCommand != null) { GIT_SSH_COMMAND = cfg.gitSshCommand; };
      # the token the tablet sends (FOLIO_SERVER_TOKEN in its folio.env)
      preStart = ''
        t=${home}/server/token
        [ -s $t ] || (umask 077; head -c 32 /dev/urandom | base64 | tr -d '/+=\n' > $t)
      '';
      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe pkgsFolio.folio-server)
            "--listen"
            cfg.serverListen
            "--token-file"
            "${home}/server/token"
            "--repo"
            "${home}/folio"
            "--claude"
            (lib.getExe' cfg.claude "claude")
            "--notes"
            "${home}/notes"
            "--rmc"
            (lib.getExe pkgsFolio.rmc)
            "--rsvg"
            (lib.getExe' pkgs.librsvg "rsvg-convert")
          ]
          ++ lib.optionals (cfg.builderRules != null) [
            "--core"
            "${cfg.builderRules}"
          ]
        );
        User = cfg.user;
        Group = "folio";
        PrivateTmp = true;
        UMask = "0007";
        Restart = "always";
      };
    };

    systemd.services.folio-bridge = {
      description = "Folio bridge: the Messages API over claude -p";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment.HOME = home;
      # the token the tablet sends; copy it into the tablet's folio.env
      preStart = ''
        t=${home}/bridge/token
        [ -s $t ] || (umask 077; head -c 32 /dev/urandom | base64 | tr -d '/+=\n' > $t)
      '';
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          (lib.getExe pkgsFolio.folio-bridge)
          "--listen"
          cfg.bridgeListen
          "--token-file"
          "${home}/bridge/token"
          "--claude"
          (lib.getExe' cfg.claude "claude")
          "--workdir"
          "${home}/bridge"
          "--jobs-dir"
          "${home}/bridge/jobs"
          "--effort"
          "medium"
        ];
        User = cfg.user;
        Group = "folio";
        UMask = "0007";
        Restart = "always";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "full";
      };
    };
  };
}
