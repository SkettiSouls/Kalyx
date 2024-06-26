{ config, lib, pkgs, writeText, ... }:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    mkMerge
    ;
  cfg = config.kalyx.virtualisation;
in
rec {
  options.kalyx.virtualisation = {
    enable = mkEnableOption "virtualisation";

    cpuarch = mkOption { type = types.enum [ "intel" "amd" ]; };

    acspatch = mkEnableOption "acspatch";

    hostcpus = mkOption {
      type = types.str;
    };

    virtcpus = mkOption {
      type = types.str;
    };

    vfioids = mkOption {
      type = types.listOf types.str;
      default = [
       # Get these using lspci -nn

       # TEMPLATE OPTIONS
       # "10de:1b81"
       # "10de:10f0"
      ];
    };
  };
 
  config = mkIf cfg.enable {
    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_zen; # We do this because Linux Zen has better IOMMU group support.

    virtualisation = {
      libvirtd = {
        enable = true;
        qemu = {
          package = pkgs.qemu_kvm; # only emulates host arch, smaller download
          runAsRoot = true;
          swtpm.enable = true; # allows for creating emulated TPM
          ovmf.packages = [(pkgs.OVMF.override {
            secureBoot = true;
            tpmSupport = true;
          }).fd]; # or use pkgs.OVMFFull.fd, which enables more stuff
        };
      };
      spiceUSBRedirection.enable = true;
    };
   
    programs.virt-manager.enable = true;
    programs.dconf.enable = true;

    environment.systemPackages = with pkgs; [
      looking-glass-client
    ];

    systemd.tmpfiles.rules =
    let
      myScript = pkgs.writeScript "qemu-hook.sh" ''
        #!/run/current-system/sw/bin/bash
        if [[ $2 == "start" || $2 == "stopped" ]]
        then
          if [[ $2 == "start" ]]
          then
            systemctl set-property --runtime -- user.slice AllowedCPUs=${cfg.virtcpus}
            systemctl set-property --runtime -- system.slice AllowedCPUs=${cfg.virtcpus}
            systemctl set-property --runtime -- init.scope AllowedCPUs=${cfg.virtcpus}
          else
            systemctl set-property --runtime -- user.slice AllowedCPUs=${cfg.hostcpus}
            systemctl set-property --runtime -- system.slice AllowedCPUs=${cfg.hostcpus}
            systemctl set-property --runtime -- init.scope AllowedCPUs=${cfg.hostcpus}
          fi
        fi
      '';
    in
    [ 
      "L+ /var/lib/libvirt/hooks/qemu - - - - ${myScript}" 
      "f /dev/shm/looking-glass 0660 root wheel"
    ];

    boot = {
      kernelParams = mkMerge [
        [
          "video=vesafb:off,efifb:off"
          "iommu=pt"
          (mkIf cfg.acspatch "pcie_acs_override=downstream,multifunction")
          "kvm.ignore_msrs=1"
          "vfio-pci.ids=${builtins.concatStringsSep "," cfg.vfioids}"
          "${cfg.cpuarch}_iommu=on"
        ]
      ];

      kernelModules = [ 
        "kvm-${cfg.cpuarch}"
      ];
      extraModprobeConfig = "options kvm_${cfg.cpuarch} nested=1";
      initrd.kernelModules = [
        "vfio"
        "vfio-pci"
      ];
    };
  };
}
