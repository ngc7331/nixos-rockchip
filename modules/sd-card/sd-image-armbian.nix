{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}:
let
  cfg = config.sdImage.armbian;

  # Provide the same option as sd-image-rockchip.nix so that board configs
  # can pass the U-Boot derivation uniformly.
  rockchipModule = {
    options.rockchip.uBoot = lib.mkOption { };
    config = { };
  };

  toplevel = config.system.build.toplevel;
  initPath = "${toplevel}/init";

  kernel = config.boot.kernelPackages.kernel;
  kernelImage = "${kernel}/${config.boot.kernelPackages.kernelTarget or "Image"}";

  dtbName = config.hardware.deviceTree.name;
  dtbFileName = baseNameOf dtbName;
  dtbPath = "${kernel}/dtbs/${dtbName}";

  # Armbian's boot.cmd expects a gzip-compressed ramdisk wrapped with U-Boot's
  # mkimage tool.  NixOS produces a zstd-compressed initrd, so unpack it and
  # repack as gzip, then create the corresponding uInitrd.
  armbianInitrd = pkgs.runCommand "nixos-initrd-armbian"
    {
      nativeBuildInputs = with pkgs.buildPackages; [
        cpio
        gzip
        ubootTools
        zstd
        file
      ];
      initrdOriginal = "${config.system.build.initialRamdisk}/initrd";
    }
    ''
      mkdir -p "$out" initrd
      cd initrd

      # Decompress the original initrd (NixOS may use zstd or gzip).
      case $(file -b --mime-type "$initrdOriginal") in
        application/zstd)
          zstd -d -c "$initrdOriginal" | cpio -idm 2>/dev/null
          ;;
        application/gzip)
          gzip -d -c "$initrdOriginal" | cpio -idm 2>/dev/null
          ;;
        application/x-cpio)
          cpio -idm < "$initrdOriginal" 2>/dev/null
          ;;
        *)
          echo "Unknown initrd compression: $(file -b "$initrdOriginal")"
          exit 1
          ;;
      esac

      # Patch initrd's /etc/{passwd,group} to enable root login with no password
      passwdFile=$(find ./nix/store -maxdepth 1 -type f -name '*initrd-passwd' | head -n1)
      shadowFile=$(find ./nix/store -maxdepth 1 -type f -name '*initrd-shadow' | head -n1)
      rm -f ./etc/passwd ./etc/shadow
      sed 's|^root:.*|root:x:0:0:System administrator:/root:/bin/bash|' "$passwdFile" > ./etc/passwd
      echo "root::0:0:99999:7:::" > ./etc/shadow

      # Repack the initrd as gzip (Armbian's boot.cmd expects gzip).
      (find . -print0 | sort -z | cpio --null -o -H newc --owner=root:root | gzip -9) > "$out/initrd.img"

      cd ..

      # Wrap the gzip initrd as a U-Boot uInitrd image.
      mkimage -A arm64 -O linux -T ramdisk -C gzip -n "NixOS initrd" \
        -d "$out/initrd.img" "$out/uInitrd"
    '';

  # Root filesystem image containing the NixOS closure.
  rootfsImage = pkgs.callPackage (modulesPath + "/../lib/make-ext4-fs.nix") {
    storePaths = [ toplevel ];
    compressImage = false;
    volumeLabel = "NIXOS_SD";
    uuid = "ff00e244-490d-4d37-baa8-f1a517c74754";
    populateImageCommands = '''';
  };

  # Boot partition contents in Armbian layout.
  bootFiles = pkgs.runCommand "armbian-boot-files"
    {
      nativeBuildInputs = with pkgs.buildPackages; [ ubootTools ];
      initrd = "${armbianInitrd}/initrd.img";
      uInitrd = "${armbianInitrd}/uInitrd";
      inherit kernelImage dtbPath dtbName dtbFileName initPath;
    }
    ''
      mkdir -p "$out/dtb/rockchip"
      cp "$kernelImage" "$out/Image"
      cp "$initrd" "$out/initrd.img-6.1.115-vendor-rk35xx"
      cp "$uInitrd" "$out/uInitrd-6.1.115-vendor-rk35xx"
      cp "$dtbPath" "$out/dtb/rockchip/$dtbFileName"
      ln -s "uInitrd-6.1.115-vendor-rk35xx" "$out/uInitrd"
      ln -s "initrd.img-6.1.115-vendor-rk35xx" "$out/initrd.img"

      # Do not set rootdev/rootfstype here.  NixOS's initrd already knows
      # the root filesystem from its initrd-fstab, and passing root= on the
      # kernel command line makes systemd-fstab-generator create a duplicate
      # sysroot.mount.  Leave rootdev empty so Armbian's boot.cmd falls back
      # to the NixOS initrd's own mounting logic.
      cat > "$out/armbianEnv.txt" <<EOF
      verbosity=7
      bootlogo=false
      console=both
      overlay_prefix=rk35xx
      fdtfile=rockchip/$dtbFileName
      rootdev=
      rootfstype=
      extraargs=init=$initPath systemd.debug_shell=1 rd.shell=1
      EOF
    '';

  buildScript = pkgs.replaceVars ./build-armbian-nixos-image.sh {
    inherit bootFiles rootfsImage;
    defaultSourceImage = if cfg.sourceImage != null then cfg.sourceImage else "";
    sfdisk = "${pkgs.util-linux}/bin/sfdisk";
    e2fsck = "${pkgs.e2fsprogs}/bin/e2fsck";
    resize2fs = "${pkgs.e2fsprogs}/bin/resize2fs";
    e2label = "${pkgs.e2fsprogs}/bin/e2label";
  };
in
{
  imports = [ rockchipModule ];

  options.sdImage.armbian = {
    enable = lib.mkEnableOption "Armbian-style SD image generation (hybrid Armbian boot + NixOS rootfs)";

    sourceImage = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "\"./armbian-base.img\"";
      description = ''
        Optional path to the source Armbian image used as a base.
        When null (the default), the generated build script requires the
        <option>--source-image</option> argument at runtime.  When set, the
        build script will use it as the default source image.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Do not use the generic-extlinux-compatible loader; Armbian's boot.cmd
    # is responsible for loading the kernel/initrd/dtb.
    boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
    boot.loader.grub.enable = lib.mkForce false;

    # Root filesystem is mounted by label, matching armbianEnv.txt.
    fileSystems."/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
    };

    # The boot partition is only used by U-Boot at boot time; it does not need
    # to be mounted in the running NixOS system.
    fileSystems."/boot" = lib.mkForce {
      device = "/dev/disk/by-label/armbi_boot";
      fsType = "ext4";
      options = [ "noauto" "nofail" ];
    };

    # On first boot, resize the root partition and register store paths just
    # like the standard sd-image.nix module does.
    boot.postBootCommands = lib.mkBefore ''
      if [ -f /nix-path-registration ]; then
        set -euo pipefail
        set -x

        rootPart=$(${pkgs.util-linux}/bin/findmnt -n -o SOURCE /)
        bootDevice=$(${pkgs.util-linux}/bin/lsblk -npo PKNAME "$rootPart")
        partNum=$(${pkgs.util-linux}/bin/lsblk -npo MAJ:MIN "$rootPart" | ${pkgs.gawk}/bin/awk -F: '{print $2}')

        echo ",+," | ${pkgs.util-linux}/bin/sfdisk -N"$partNum" --no-reread "$bootDevice"
        ${pkgs.parted}/bin/partprobe
        ${pkgs.e2fsprogs}/bin/resize2fs "$rootPart"

        ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration
        touch /etc/NIXOS
        ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system
        rm -f /nix-path-registration
      fi
    '';

    system.build.sdImage = buildScript;
  };
}
