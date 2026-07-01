{ config, lib, pkgs, ... }:

let
  cfg = config.yeti;
  defaults = config.yetiDefaults;    

  # option types

  imageType = lib.types.submodule {
    options = {
      fingerprint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Image fingerprint. Use this OR alias.";
      };
      alias = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Image alias. Combine with `server` for a remote pull,
          or use alone for a local alias already cached in the project.
        '';
      };
      server = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Remote image server URL (e.g. https://images.linuxcontainers.org).";
      };
      protocol = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Remote protocol; defaults to simplestreams when omitted.";
      };
    };
  };

  # A device is `type: <str>` plus arbitrary string-typed extra keys
  # (network, pool, path, source, parent, nictype, size, ...).
  deviceType = lib.types.submodule {
    freeformType = lib.types.attrsOf lib.types.str;
    options = {
      type = lib.mkOption {
        type = lib.types.str;
        description = "Device type: nic, disk, gpu, proxy, unix-char, ...";
      };
    };
  };

  resourceType = lib.types.submodule ({ name, ... }: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Instance name; defaults to the attribute key.";
      };
      type = lib.mkOption {
        type = lib.types.enum [ "container" "virtual-machine" ];
        default = "container";
      };
      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      # `ephemeral` is defined here only so users get a clear assertion if
      # they try to set it. The actual escape hatch is `forceEphemeral`
      # below - see its description and the assertion message in `config`.
      ephemeral = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        visible = false;
      };
      forceEphemeral = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Set to true to mark this instance as ephemeral, acknowledging
          the implication: when the instance stops, the next NixOS
          rebuild will re-create it from scratch.

          This is rarely the intent for declaratively-managed
          infrastructure, but it can be useful for short-lived workloads
          that should reappear after a host reboot.

          Use this option instead of `ephemeral = true` (which is
          rejected with an explanatory error). The deliberate name
          difference is there to make sure the caveat is read at least
          once.
        '';
      };
      autostart = lib.mkOption {
        type = lib.types.bool;
        default = defaults.autostart;
        description = ''
          Whether to start the instance immediately after creation
          (equivalent to `incus launch` rather than `incus create`).

          Default value comes from `yetiDefaults.autostart`, which
          is `true` out of the box but can be overridden module-wide.

          Only affects the initial create. The reconciler does not
          stop or start existing instances on subsequent runs, so a
          manual `incus stop` is respected and won't be undone by the
          next rebuild. For "start on daemon restart" behavior, use
          incus's own `boot.autostart` config key in `config` or a
          profile.
        '';
      };      
      image = lib.mkOption {
        type = imageType;
        description = "Image source. Required for instance creation.";
      };
      profiles = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
      };
      # Note: this is the user-visible `config` option for the instance,
      # different from the module-level `config` argument above.
      config = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
        default = null;
        description = ''
          Instance config keys (limits.cpu, boot.autostart, user.*, ...).
          Values are strings; the reconciler compares as strings.
        '';
      };
      devices = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf deviceType);
        default = null;
      };
    };
  });

  # spec generation

  # Drop keys whose value is null so they don't show up in the YAML.
  dropNulls = lib.filterAttrs (_: v: v != null);

  # The reconciler dispatches on `kind`, but in the flake context the only
  # supported value is "instance" - inject it here rather than exposing it
  # as a user-visible option. The project is similarly injected from the
  # outer attrset key.
  #
  # Also translate the module-only `forceEphemeral` into the spec's
  # `ephemeral` field, and drop the module-only key from the output.
  serializeResource = project: res:
    let
      stripped = builtins.removeAttrs res [ "forceEphemeral" ];
      withEphemeral =
        if res.forceEphemeral
        then stripped // { ephemeral = true; }
        else stripped;
    in
    dropNulls (withEphemeral // {
      kind = "instance";
      project = project;      
      image = dropNulls res.image;
    });

  # Flatten yeti.<project>.<instance> into a single list of resource specs.
  specData = {
    resources = lib.concatLists (lib.mapAttrsToList (project: instances:
      lib.mapAttrsToList (_: res: serializeResource project res) instances
    ) cfg);
  };
    
  yamlFormat = pkgs.formats.yaml { };
  specFile = yamlFormat.generate "spec.yaml" specData;

  pythonEnv = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
in {
  options.yetiDefaults = lib.mkOption {
    type = lib.types.submodule {
      options = {
        autostart = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Default value for `yeti.<project>.<instance>.autostart`
            when an individual resource doesn't set it.

            `true` (the default) means newly-created instances are
            started immediately, mirroring `incus launch`. Flip this
            to `false` if your typical workflow is "create stopped,
            start later"; individual resources can still override
            this with their own `autostart` setting either way.
          '';
        };
      };
    };
    default = { };
    description = ''
      Module-wide defaults applied to resources that don't specify
      the corresponding option themselves. Kept as a sibling of
      `yeti` rather than nested under it, so every key inside
      `yeti.<…>` is unambiguously a project name.
    '';
  };

  options.yeti = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf resourceType);    
    default = { };
    description = ''
      Incus resources to reconcile on this machine, organised as
      `yeti.<project>.<instance>`. The outer attribute name is the
      incus project, the inner attribute name is the instance name
      (overridable via the `name` option inside the resource).

      This two-level structure exists so that the same instance name
      can appear in different projects without an attrset key clash.

      Resources are translated into a YAML spec at build time and
      applied by the `incus-yeti.service` systemd unit, which
      runs as a dedicated `incus-yeti` user in the `incus-admin` group.

      The service re-runs whenever the generated spec changes (i.e.
      whenever you change these options and rebuild).
    '';
    example = lib.literalExpression ''
      {
        default = {
          web-1 = {
            image.alias = "debian/12";
            image.server = "https://images.linuxcontainers.org";
            profiles = [ "default" ];
            config."limits.cpu" = "2";
          };
        };
        dev = {
          web-1 = {              # same instance name, different project
            image.alias = "debian/12";
            image.server = "https://images.linuxcontainers.org";
          };
        };
      }      
    '';
  };

  config = lib.mkIf (specData.resources != [ ]) {  
    assertions = [
      {
        assertion = config.virtualisation.incus.enable or false;
        message = ''
          Defining `yeti` resources requires `virtualisation.incus.enable = true;`
          - the reconciler runs as a member of the `incus-admin` group,
          which is created by the incus service.
        '';
      }
    ] ++ lib.concatLists (lib.mapAttrsToList (project: instances:
      lib.mapAttrsToList (instName: res: {      
        assertion = res.ephemeral != true;
        message = ''
          yeti.${project}.${instName}.ephemeral = true is not supported via the NixOS module.
  
          An ephemeral incus instance disappears when it stops, but the
          reconciler runs on every NixOS rebuild and would silently
          re-create it each time. That's usually not what's intended.
  
          If you understand the implication and actually want this
          behavior (e.g. a short-lived workload that should reappear
          after each host reboot), set `forceEphemeral = true`
          on this resource instead of `ephemeral = true`.
  
          Otherwise, for one-off ephemeral workloads, run the reconciler
          standalone with a hand-written spec:
  
              nix run github:observer/yeti -- spec.yaml
        '';
      }) instances
    ) cfg);

    users.users.incus-yeti = {
      isSystemUser = true;
      group = "incus-yeti";
      extraGroups = [ "incus-admin" ];
      description = "incus-yeti service account";
    };
    users.groups.incus-yeti = { };

    systemd.services.incus-yeti = {
      description = "Apply incus resource spec via yeti";
      after = [ "incus.service" ];
      requires = [ "incus.service" ];
      wantedBy = [ "multi-user.target" ];

      # `incus` must be in PATH for the subprocess calls inside the script.
      path = [ pkgs.incus ];

      # Restart (i.e. re-run the oneshot) whenever the spec changes.
      restartTriggers = [ specFile ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "incus-yeti";
        Group = "incus-yeti";
        ExecStart = "${pythonEnv}/bin/python3 ${./yeti} ${specFile}";

        # Light sandbox; the script only reads the spec, calls `incus query`,
        # and writes nothing of its own.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        LockPersonality = true;
      };
    };
  };
}
