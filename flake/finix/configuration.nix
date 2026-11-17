# finix as a cloud image: BIOS boot, virtio disks, key-only SSH.
{
  pkgs,
  lib,
  ...
}:
let
  loginUser = "finix";

  # Keys baked in at build time. Empty in the repository; a build may fill the
  # file in before it runs. See README.md.
  builtKeys = lib.strings.trim (builtins.readFile ./authorized_keys);

  # Keys fetched at boot land here, outside /etc, because /etc is rebuilt by
  # activation.
  cloudKeyDir = "/var/lib/cloud-ssh-keys";

  # finix has no cloud-init, so nothing else consumes the SSH key chosen when
  # the machine was created. This asks the metadata service for it:
  # - DigitalOcean: https://docs.digitalocean.com/reference/api/metadata/
  # - OpenStack: https://docs.openstack.org/nova/latest/user/metadata.html
  # - plain GET only, so AWS instances that require IMDSv2 get no key
  # - every failure path exits 0 and leaves the previous file alone
  cloud-ssh-keys = pkgs.writeShellScript "cloud-ssh-keys" ''
    set -u

    dest=${cloudKeyDir}/${loginUser}
    base=http://169.254.169.254

    get() { curl --silent --fail --connect-timeout 2 --max-time 5 "$base/$1"; }

    fetch_keys() {
      # DigitalOcean
      get metadata/v1/public-keys && return
      # OpenStack
      get openstack/latest/meta_data.json | jq -er '.public_keys // {} | .[]' && return
      # EC2-compatible path, which OpenStack also serves
      get latest/meta-data/public-keys/0/openssh-key
    }

    mkdir -p ${cloudKeyDir}
    chmod 0755 ${cloudKeyDir}

    for attempt in $(seq 1 20); do
      keys=$(fetch_keys | grep -E '^(ssh-|ecdsa-|sk-)' || true)
      if [ -n "$keys" ]; then
        tmp=$(mktemp ${cloudKeyDir}/.keys.XXXXXX) || exit 0
        printf '%s\n' "$keys" > "$tmp"
        chmod 0444 "$tmp"
        mv -f "$tmp" "$dest"
        echo "cloud-ssh-keys: installed $(printf '%s\n' "$keys" | wc -l) key(s) for ${loginUser}"
        exit 0
      fi
      sleep 2
    done

    echo "cloud-ssh-keys: the metadata service returned no key, leaving $dest as it was"
    exit 0
  '';
in
{
  imports = [
    ./hardware-configuration.nix
    ./grow-root.nix
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  finit.runlevel = 3;

  finit.tmpfiles.rules = [ "d ${cloudKeyDir} 0755 root root" ];

  # net/route/default: https://finit-project.github.io/conditions/
  finit.tasks.cloud-ssh-keys = {
    description = "Install SSH keys from the cloud metadata service";
    command = "${cloud-ssh-keys}";
    conditions = [
      "service/syslogd/ready"
      "net/route/default"
    ];
    remain = true;
    log = true;
    path = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gnugrep
      pkgs.jq
    ];
  };

  services.nix-daemon = {
    enable = true;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [
        "root"
        "@wheel"
      ];
    };
  };

  programs = {
    limine = {
      enable = true;
      efiSupport = false;
      biosSupport = true;
      # "nodev" (the default, stated because the build depends on it): limine's
      # config and stage 2 file are managed, boot code is never written.
      # https://github.com/finix-community/finix/blob/e407a7e66f1d0d670e854c9d6a74ac5c94480190/modules/programs/limine/limine-install.py#L611
      # - the image build writes the boot code once (scripts/3-bootloader.sh)
      # - no device name is right everywhere: vda on virtio-blk, sda on SCSI,
      #   and on the build host it would be the builder's own disk
      biosDevice = "nodev";
      # The account has no password, so the boot menu editor is the only
      # console rescue path. Console access is therefore root access.
      settings.editor_enabled = true;
    };

    sudo.enable = true;

    bash.enable = true;
  };

  # Passwordless sudo for wheel. The account has no password, so without this
  # sudo would prompt for one that cannot exist. finix has no
  # security.sudo.wheelNeedsPassword; this renders
  # `%wheel ALL = (root) NOPASSWD: ALL` into sudoers.
  providers.privileges = {
    rules = [
      {
        groups = [ "wheel" ];
        command = "ALL";
        requirePassword = false;
      }
    ];
  };

  services = {
    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        # Replaces sshd's default list (sshd_config(5), AuthorizedKeysFile):
        # baked in, then fetched at boot.
        AuthorizedKeysFile = "/etc/ssh/authorized_keys.d/%u ${cloudKeyDir}/%u";
      };
    };

    polkit.enable = true;

    sysklogd.enable = true;

    mdevd.enable = true;

    dhcpcd.enable = true;
  };

  networking.hostName = "finixos";

  time.timeZone = "UTC";

  # No password field: the account is key-only. The uid is pinned because
  # finix allocates a free one at activation otherwise, and a stable 1000 keeps
  # file ownership meaningful across rebuilds.
  users.users.${loginUser} = {
    isNormalUser = true;
    description = loginUser;
    uid = 1000;
    extraGroups = [ "wheel" ];
  };

  environment.systemPackages = with pkgs; [
    vim
    micro
    wget
    git
    nixos-rebuild-ng
    iputils
    iproute2
  ];

  # `mode` is required. Without it this is a symlink into /nix/store, which is
  # group-writable, and StrictModes rejects the key (sshd_config(5)).
  environment.etc."ssh/authorized_keys.d/${loginUser}" = lib.mkIf (builtKeys != "") {
    mode = "0444";
    text = builtKeys + "\n";
  };
}
